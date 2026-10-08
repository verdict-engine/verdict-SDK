import { describe, expect, it } from "vitest";
import {
  VerdictAuthError,
  VerdictClient,
  VerdictNotFoundError,
  VerdictRateLimitError,
  VerdictValidationError,
  type Decision,
} from "../src/index";

interface Call {
  url: string;
  init: RequestInit | undefined;
}

/** A hand-rolled, fully-typed `fetch` stub — records calls and returns the response the handler picks. */
function stubFetch(handler: (index: number) => Response): { fn: typeof fetch; calls: Call[] } {
  const calls: Call[] = [];
  const fn: typeof fetch = async (input, init) => {
    calls.push({ url: typeof input === "string" ? input : input.toString(), init });
    return handler(calls.length - 1);
  };
  return { fn, calls };
}

function jsonResponse(body: unknown, init: { status?: number; headers?: Record<string, string> } = {}): Response {
  return new Response(JSON.stringify(body), {
    status: init.status ?? 200,
    headers: { "content-type": "application/json", ...init.headers },
  });
}

const DECISION: Decision = {
  id: "vd_1",
  eventId: "evt_1",
  verdict: "review",
  score: 55,
  reasons: [{ tag: "takeover", points: 33 }],
  decidedAt: "2026-09-25T00:00:00.000Z",
};

function client(fn: typeof fetch, maxRetries?: number): VerdictClient {
  return new VerdictClient({ apiKey: "vk_test_abc", baseUrl: "https://engine.test", fetch: fn, maxRetries });
}

function headersOf(call: Call): Record<string, string> {
  return (call.init?.headers ?? {}) as Record<string, string>;
}

describe("VerdictClient", () => {
  it("requires an apiKey", () => {
    // @ts-expect-error — exercising the runtime guard with a missing key.
    expect(() => new VerdictClient({})).toThrow(/apiKey/);
  });

  it("scores an event and sends the API key", async () => {
    const s = stubFetch(() => jsonResponse(DECISION));
    const decision = await client(s.fn).decide({ type: "card.authorize", subject: { userId: "u1" } });

    expect(decision.verdict).toBe("review");
    expect(s.calls[0]!.url).toBe("https://engine.test/v1/decisions");
    expect(headersOf(s.calls[0]!)["X-API-Key"]).toBe("vk_test_abc");
    expect(JSON.parse(s.calls[0]!.init?.body as string)).toEqual({
      type: "card.authorize",
      subject: { userId: "u1" },
    });
  });

  it("forwards idempotency and correlation headers", async () => {
    const s = stubFetch(() => jsonResponse(DECISION));
    await client(s.fn).decide(
      { type: "account.login", subject: { userId: "u1" } },
      { idempotencyKey: "idem-1", correlationId: "cor-1" },
    );
    expect(headersOf(s.calls[0]!)["Idempotency-Key"]).toBe("idem-1");
    expect(headersOf(s.calls[0]!)["X-Correlation-Id"]).toBe("cor-1");
  });

  it("sends X-Verdict-Mode only when shadow mode is requested", async () => {
    const s = stubFetch(() => jsonResponse(DECISION));
    const c = client(s.fn);
    await c.decide({ type: "payment.authorize", subject: { userId: "u1" } });
    await c.decide({ type: "payment.authorize", subject: { userId: "u1" } }, { mode: "shadow" });
    expect(headersOf(s.calls[0]!)["X-Verdict-Mode"]).toBeUndefined();
    expect(headersOf(s.calls[1]!)["X-Verdict-Mode"]).toBe("shadow");
  });

  it("parses reasonCodes, customerMessage and the shadow flag from the response", async () => {
    const s = stubFetch(() =>
      jsonResponse({
        ...DECISION,
        reasonCodes: [{ code: "ACCOUNT_TAKEOVER", category: "takeover" }],
        customerMessage: "This payment couldn't be completed.",
        shadow: true,
      }),
    );
    const decision = await client(s.fn).decide({ type: "payment.authorize", subject: { userId: "u1" } }, { mode: "shadow" });
    expect(decision.reasonCodes).toEqual([{ code: "ACCOUNT_TAKEOVER", category: "takeover" }]);
    expect(decision.customerMessage).toBe("This payment couldn't be completed.");
    expect(decision.shadow).toBe(true);
  });

  it("maps 401 to VerdictAuthError without retrying", async () => {
    const s = stubFetch(() => jsonResponse({ code: "UNAUTHORIZED", message: "bad key" }, { status: 401 }));
    await expect(
      client(s.fn).decide({ type: "order.place", subject: { userId: "u1" } }),
    ).rejects.toBeInstanceOf(VerdictAuthError);
    expect(s.calls).toHaveLength(1);
  });

  it("maps 400 to VerdictValidationError", async () => {
    const s = stubFetch(() =>
      jsonResponse({ code: "INGEST_UNKNOWN_TYPE", message: "unknown event type" }, { status: 400 }),
    );
    await expect(
      client(s.fn).decide({ type: "order.place", subject: { userId: "u1" } }),
    ).rejects.toBeInstanceOf(VerdictValidationError);
  });

  it("retries a 429 honoring Retry-After, then succeeds", async () => {
    const s = stubFetch((i) =>
      i === 0
        ? jsonResponse({ code: "RATE_LIMITED", message: "slow down" }, { status: 429, headers: { "retry-after": "0" } })
        : jsonResponse(DECISION),
    );
    const decision = await client(s.fn).decide({ type: "card.authorize", subject: { userId: "u1" } });
    expect(decision.eventId).toBe("evt_1");
    expect(s.calls).toHaveLength(2);
  });

  it("gives up after maxRetries and throws the rate-limit error", async () => {
    const s = stubFetch(() =>
      jsonResponse({ code: "RATE_LIMITED", message: "slow down" }, { status: 429, headers: { "retry-after": "0" } }),
    );
    await expect(
      client(s.fn, 1).decide({ type: "card.authorize", subject: { userId: "u1" } }),
    ).rejects.toBeInstanceOf(VerdictRateLimitError);
    expect(s.calls).toHaveLength(2);
  });

  it("exposes the rate-limit budget from response headers", async () => {
    const s = stubFetch(() =>
      jsonResponse(DECISION, { headers: { "x-ratelimit-limit": "600", "x-ratelimit-remaining": "599" } }),
    );
    const c = client(s.fn);
    await c.decide({ type: "card.authorize", subject: { userId: "u1" } });
    expect(c.rateLimit).toEqual({ limit: 600, remaining: 599 });
  });

  it("rejects a batch over 100 events before calling the network", async () => {
    const s = stubFetch(() => jsonResponse({ results: [] }));
    const events = Array.from({ length: 101 }, () => ({ type: "order.place" as const, subject: { userId: "u1" } }));
    await expect(client(s.fn).decideBatch(events)).rejects.toThrow(/at most 100/);
    expect(s.calls).toHaveLength(0);
  });

  it("returns per-event batch results", async () => {
    const s = stubFetch(() =>
      jsonResponse({
        results: [
          { ok: true, decision: DECISION },
          { ok: false, error: { code: "INGEST_UNKNOWN_TYPE", message: "bad" } },
        ],
      }),
    );
    const results = await client(s.fn).decideBatch([
      { type: "card.authorize", subject: { userId: "u1" } },
      { type: "order.place", subject: { userId: "u2" } },
    ]);
    expect(results[0]!.ok).toBe(true);
    expect(results[1]!.ok).toBe(false);
  });

  it("throws VerdictNotFoundError for a pending async decision", async () => {
    const s = stubFetch(() => jsonResponse({ code: "NOT_FOUND", message: "pending" }, { status: 404 }));
    await expect(client(s.fn).getDecision("evt_9")).rejects.toBeInstanceOf(VerdictNotFoundError);
  });

  it("records a chargeback", async () => {
    const s = stubFetch(() => jsonResponse({ recorded: true }, { status: 202 }));
    const ack = await client(s.fn).recordChargeback("evt_1");
    expect(ack.recorded).toBe(true);
    expect(s.calls[0]!.url).toBe("https://engine.test/v1/labels/chargeback");
  });
});
