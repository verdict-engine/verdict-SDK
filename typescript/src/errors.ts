/**
 * Error hierarchy the client throws. Callers can branch on the subclass (rate limit vs auth vs
 * not-found vs transport) without parsing status codes, while `status` and `code` remain available
 * for logging. The raw response body is never attached, so secrets in a request can't leak through
 * a thrown error.
 */

/** Base error for every failed Verdict API call. */
export class VerdictError extends Error {
  /** HTTP status, or 0 for a transport failure (network error / timeout) that never reached the engine. */
  readonly status: number;
  /** Machine-readable error code from the engine's envelope, or a synthetic one for transport failures. */
  readonly code: string;
  /** The engine's correlation id for this request, when it returned one — useful in support tickets. */
  readonly correlationId?: string;

  constructor(message: string, status: number, code: string, correlationId?: string) {
    super(message);
    this.name = new.target.name;
    this.status = status;
    this.code = code;
    this.correlationId = correlationId;
    // Restore the prototype chain when compiled down to ES5 targets, so `instanceof` works.
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

/** 401/403 — the API key is missing, invalid, revoked, or lacks the required scope. */
export class VerdictAuthError extends VerdictError {}

/** 404 — no decision exists for the id yet (an async decision may still be pending). */
export class VerdictNotFoundError extends VerdictError {}

/** 400 — the request was rejected by validation before scoring. */
export class VerdictValidationError extends VerdictError {}

/** 429 — the per-key decision budget is exhausted. `retryAfterMs` is honored by the built-in retry. */
export class VerdictRateLimitError extends VerdictError {
  /** How long to wait before retrying, from the Retry-After header (milliseconds), when provided. */
  readonly retryAfterMs?: number;

  constructor(message: string, code: string, retryAfterMs?: number, correlationId?: string) {
    super(message, 429, code, correlationId);
    this.retryAfterMs = retryAfterMs;
  }
}

/** The request never completed — DNS/connection failure, or it exceeded the client timeout. */
export class VerdictConnectionError extends VerdictError {
  constructor(message: string, code: "TIMEOUT" | "NETWORK") {
    super(message, 0, code);
  }
}
