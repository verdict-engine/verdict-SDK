import {
  VerdictAuthError,
  VerdictConnectionError,
  VerdictError,
  VerdictNotFoundError,
  VerdictRateLimitError,
  VerdictValidationError,
} from "./errors";
import type {
  AsyncAck,
  BatchItem,
  ChargebackAck,
  Decision,
  DecisionMode,
  RateLimit,
  VerdictEvent,
} from "./types";

/** Configuration for a {@link VerdictClient}. Only `apiKey` is required. */
export interface VerdictClientOptions {
  /** A service API key (`vk_live_…`) created by an admin. Sent as the `X-API-Key` header. */
  apiKey: string;
  /** Engine base URL. Defaults to `http://localhost:4000`. A trailing slash is trimmed. */
  baseUrl?: string;
  /** Per-request timeout in milliseconds. Defaults to 10000. */
  timeoutMs?: number;
  /**
   * Retries for transient failures (429, 5xx, and network errors) with exponential backoff.
   * A 429 waits for its `Retry-After` when present. Only idempotent-safe calls are retried.
   * Defaults to 2.
   */
  maxRetries?: number;
  /**
   * Injectable `fetch` — supply a custom implementation (a proxy, a polyfill, or a test double).
   * Defaults to the global `fetch` (Node 18+, Deno, browsers, edge runtimes).
   */
  fetch?: typeof fetch;
}

/** Per-call options. */
export interface DecideOptions {
  /**
   * Makes a retry return the original decision instead of recomputing. Defaults, server-side, to the
   * event id. Set this when you retry a decision yourself and want exactly-once semantics.
   */
  idempotencyKey?: string;
  /** Threaded through the engine's logs and events for tracing. */
  correlationId?: string;
  /**
   * Enforcement mode. `shadow` scores the event without acting on it (logged for comparison, no
   * fan-out, no case) — the comparison the shadow report is built from. Defaults to `enforce`.
   */
  mode?: DecisionMode;
  /** Abort the request early (in addition to the client timeout). */
  signal?: AbortSignal;
}

/** The request header that selects shadow mode, set when `options.mode === "shadow"`. */
function modeHeaders(options: DecideOptions): Record<string, string> {
  return options.mode === "shadow" ? { "X-Verdict-Mode": "shadow" } : {};
}

const DEFAULT_BASE_URL = "http://localhost:4000";
const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_MAX_RETRIES = 2;

interface RequestSpec {
  method: "GET" | "POST";
  path: string;
  body?: unknown;
  headers?: Record<string, string>;
  /** Whether a 429/5xx/network failure may be retried. */
  retryable: boolean;
  signal?: AbortSignal;
}

/**
 * A thin, dependency-free client for the Verdict decisioning API. It wraps the API-key data plane:
 * scoring events (sync, batch, async), fetching an async result, and recording chargeback labels.
 *
 * ```ts
 * const verdict = new VerdictClient({ apiKey: process.env.VERDICT_API_KEY! });
 * const decision = await verdict.decide({
 *   type: "card.authorize",
 *   amount: 4900, currency: "ETB",
 *   subject: { userId: "usr_3f9a", ip: "196.188.120.4", fingerprint: "fp_9c1e" },
 * });
 * if (decision.verdict === "deny") throw new Error("blocked");
 * ```
 */
export class VerdictClient {
  private readonly apiKey: string;
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly maxRetries: number;
  private readonly fetchImpl: typeof fetch;
  private lastRateLimit: RateLimit = { limit: null, remaining: null };

  constructor(options: VerdictClientOptions) {
    if (!options || !options.apiKey) {
      throw new Error("VerdictClient requires an apiKey");
    }
    this.apiKey = options.apiKey;
    this.baseUrl = (options.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.maxRetries = options.maxRetries ?? DEFAULT_MAX_RETRIES;
    const f = options.fetch ?? globalThis.fetch;
    if (typeof f !== "function") {
      throw new Error(
        "global fetch is not available in this runtime — pass options.fetch (e.g. node-fetch or undici)",
      );
    }
    // Bind so the global fetch keeps its expected `this` when stored as a field.
    this.fetchImpl = f.bind(globalThis);
  }

  /** The rate-limit budget reported by the most recent call, from the `X-RateLimit-*` headers. */
  get rateLimit(): RateLimit {
    return this.lastRateLimit;
  }

  /** Score one event synchronously and return its verdict. */
  decide(event: VerdictEvent, options: DecideOptions = {}): Promise<Decision> {
    const headers: Record<string, string> = { ...modeHeaders(options) };
    if (options.idempotencyKey) headers["Idempotency-Key"] = options.idempotencyKey;
    if (options.correlationId) headers["X-Correlation-Id"] = options.correlationId;
    return this.request<Decision>({
      method: "POST",
      path: "/v1/decisions",
      body: event,
      headers,
      // Scoring is idempotent on the engine (keyed by Idempotency-Key / event id), so retry is safe.
      retryable: true,
      signal: options.signal,
    });
  }

  /**
   * Score up to 100 events in one call. Each is scored independently and the results preserve order;
   * a malformed event fails only its own entry (`ok: false`).
   */
  async decideBatch(events: VerdictEvent[], options: DecideOptions = {}): Promise<BatchItem[]> {
    if (events.length === 0) return [];
    if (events.length > 100) {
      throw new Error(`decideBatch accepts at most 100 events, got ${events.length}`);
    }
    const headers: Record<string, string> = { ...modeHeaders(options) };
    if (options.correlationId) headers["X-Correlation-Id"] = options.correlationId;
    const res = await this.request<{ results: BatchItem[] }>({
      method: "POST",
      path: "/v1/decisions/batch",
      body: { events },
      headers,
      retryable: true,
      signal: options.signal,
    });
    return res.results;
  }

  /**
   * Submit an event off the response path. Returns a 202 acknowledgement immediately; poll
   * {@link getDecision} with the returned id for the verdict.
   */
  decideAsync(event: VerdictEvent, options: DecideOptions = {}): Promise<AsyncAck> {
    const headers: Record<string, string> = { ...modeHeaders(options) };
    if (options.correlationId) headers["X-Correlation-Id"] = options.correlationId;
    return this.request<AsyncAck>({
      method: "POST",
      path: "/v1/decisions/async",
      body: event,
      headers,
      retryable: true,
      signal: options.signal,
    });
  }

  /**
   * Fetch a decision by its event id. Throws {@link VerdictNotFoundError} while an async decision is
   * still pending or if the id is unknown.
   */
  getDecision(eventId: string, options: { signal?: AbortSignal } = {}): Promise<Decision> {
    return this.request<Decision>({
      method: "GET",
      path: `/v1/decisions/${encodeURIComponent(eventId)}`,
      retryable: true,
      signal: options.signal,
    });
  }

  /** Record a chargeback for a previously-scored event as a fraud label (requires the `labels` scope). */
  recordChargeback(eventId: string, options: { signal?: AbortSignal } = {}): Promise<ChargebackAck> {
    return this.request<ChargebackAck>({
      method: "POST",
      path: "/v1/labels/chargeback",
      body: { eventId },
      retryable: true,
      signal: options.signal,
    });
  }

  private async request<T>(spec: RequestSpec): Promise<T> {
    let attempt = 0;
    // One initial try plus up to `maxRetries` retries.
    for (;;) {
      try {
        return await this.send<T>(spec);
      } catch (err) {
        const wait = this.retryDelayMs(err, spec.retryable, attempt);
        if (wait === null) throw err;
        await sleep(wait);
        attempt += 1;
      }
    }
  }

  private async send<T>(spec: RequestSpec): Promise<T> {
    const controller = new AbortController();
    const onAbort = (): void => controller.abort();
    if (spec.signal) {
      if (spec.signal.aborted) controller.abort();
      else spec.signal.addEventListener("abort", onAbort, { once: true });
    }
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);

    let res: Response;
    try {
      res = await this.fetchImpl(`${this.baseUrl}${spec.path}`, {
        method: spec.method,
        headers: {
          "X-API-Key": this.apiKey,
          Accept: "application/json",
          ...(spec.body === undefined ? {} : { "Content-Type": "application/json" }),
          ...spec.headers,
        },
        body: spec.body === undefined ? undefined : JSON.stringify(spec.body),
        signal: controller.signal,
      });
    } catch (err) {
      // A caller-driven abort is a cancellation, not a transient network fault — don't retry it.
      if (spec.signal?.aborted) {
        throw new VerdictConnectionError("request aborted", "NETWORK");
      }
      if (controller.signal.aborted) {
        throw new VerdictConnectionError(`request timed out after ${this.timeoutMs}ms`, "TIMEOUT");
      }
      throw new VerdictConnectionError(messageOf(err, "network request failed"), "NETWORK");
    } finally {
      clearTimeout(timer);
      spec.signal?.removeEventListener("abort", onAbort);
    }

    this.captureRateLimit(res);
    if (res.ok) return this.parseBody<T>(res);
    throw await this.toError(res);
  }

  private async parseBody<T>(res: Response): Promise<T> {
    if (res.status === 204) return undefined as T;
    const text = await res.text();
    if (!text) return undefined as T;
    try {
      return JSON.parse(text) as T;
    } catch {
      throw new VerdictError("engine returned a non-JSON body", res.status, "BAD_RESPONSE");
    }
  }

  private async toError(res: Response): Promise<VerdictError> {
    const correlationId = res.headers.get("x-correlation-id") ?? undefined;
    const { code, message } = await this.errorEnvelope(res);
    switch (res.status) {
      case 400:
        return new VerdictValidationError(message, 400, code, correlationId);
      case 401:
      case 403:
        return new VerdictAuthError(message, res.status, code, correlationId);
      case 404:
        return new VerdictNotFoundError(message, 404, code, correlationId);
      case 429:
        return new VerdictRateLimitError(message, code, retryAfterMs(res), correlationId);
      default:
        return new VerdictError(message, res.status, code, correlationId);
    }
  }

  private async errorEnvelope(res: Response): Promise<{ code: string; message: string }> {
    try {
      const body = (await res.json()) as { code?: string; error?: string; message?: string };
      return {
        code: body.code ?? `HTTP_${res.status}`,
        message: body.message ?? body.error ?? `request failed with status ${res.status}`,
      };
    } catch {
      return { code: `HTTP_${res.status}`, message: `request failed with status ${res.status}` };
    }
  }

  private captureRateLimit(res: Response): void {
    this.lastRateLimit = {
      limit: intHeader(res, "x-ratelimit-limit"),
      remaining: intHeader(res, "x-ratelimit-remaining"),
    };
  }

  /** Milliseconds to wait before the next attempt, or null when the error must not be retried. */
  private retryDelayMs(err: unknown, retryable: boolean, attempt: number): number | null {
    if (!retryable || attempt >= this.maxRetries) return null;
    if (err instanceof VerdictRateLimitError) {
      return err.retryAfterMs ?? backoffMs(attempt);
    }
    if (err instanceof VerdictConnectionError && err.code === "NETWORK") {
      return backoffMs(attempt);
    }
    // 5xx are transient; 4xx (other than 429) are the caller's to fix.
    if (err instanceof VerdictError && err.status >= 500) {
      return backoffMs(attempt);
    }
    return null;
  }
}

function intHeader(res: Response, name: string): number | null {
  const raw = res.headers.get(name);
  if (raw === null) return null;
  const n = Number.parseInt(raw, 10);
  return Number.isNaN(n) ? null : n;
}

function retryAfterMs(res: Response): number | undefined {
  const raw = res.headers.get("retry-after");
  if (raw === null) return undefined;
  const seconds = Number.parseInt(raw, 10);
  return Number.isNaN(seconds) ? undefined : seconds * 1000;
}

/** Exponential backoff (250ms, 500ms, 1s, …) with jitter to avoid retry stampedes. */
function backoffMs(attempt: number): number {
  const base = 250 * 2 ** attempt;
  return base + Math.floor(Math.random() * 100);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function messageOf(err: unknown, fallback: string): string {
  return err instanceof Error && err.message ? err.message : fallback;
}
