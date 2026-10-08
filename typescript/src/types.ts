/**
 * Wire types for the Verdict decisioning API. These mirror the engine's request and response
 * shapes exactly (see the engine's OpenAPI at /docs); the SDK adds no fields of its own.
 */

/** Channel-agnostic event type. Selects which ruleset and policy the engine applies. */
export type EventType =
  | "card.authorize"
  | "card.capture"
  | "card.refund"
  | "payment.authorize"
  | "wallet.withdraw"
  | "account.login"
  | "order.place";

/** The acting entity and the identifiers the engine links in the graph and geo/velocity signals. */
export interface Subject {
  /** The acting user's stable id. The primary graph entity and the anomaly-baseline key. */
  userId: string;
  /** Stable device/client id. Powers velocity, first-seen and device-linking signals. */
  deviceId?: string;
  /** Client-computed device fingerprint hash — drives cloning/spoofing signals independently of deviceId. */
  fingerprint?: string;
  /** Client IP, resolved to a coarse location for geo signals. Never placed in URLs or logs. */
  ip?: string;
  /** MSISDN for mobile-money / telecom rails — a graph entity for SIM-box / account-farming signals. */
  phone?: string;
  /** Origin rail, e.g. "visa", "telebirr", "web". */
  channel?: string;
}

/** Payment instrument, for value-bearing events. Only the issuer BIN is ever sent — never a full PAN. */
export interface Instrument {
  kind?: "card" | "wallet" | "bank";
  /** Card issuer BIN — the first 6–8 digits only. */
  bin?: string;
  /** ISO-3166 issuer country, e.g. "US". */
  issuerCountry?: string;
  threeDS?: boolean;
}

/** A single event to score. Same shape for sync, batch, and async submission. */
export interface VerdictEvent {
  /** Optional client-supplied event id. Used as the idempotency key for async submission. */
  id?: string;
  type: EventType;
  /** Transaction value, for money-bearing events. Non-negative. */
  amount?: number;
  /** ISO-4217 code, e.g. "USD". Required by the engine when `amount` is present. */
  currency?: string;
  subject: Subject;
  instrument?: Instrument;
  /** Additional validated scalar signals, readable in rules as `attr.<key>`. */
  attributes?: Record<string, string | number | boolean>;
}

/** The decision the policy reached. */
export type Verdict = "allow" | "challenge" | "review" | "deny";

/**
 * Enforcement mode for a decision. `enforce` (default) acts on the verdict; `shadow` scores the
 * event without acting — the verdict is logged for comparison, with no fan-out and no case opened.
 */
export type DecisionMode = "enforce" | "shadow";

/** One signal that fired and the points it contributed — the attributable, analyst-facing explanation. */
export interface Reason {
  tag: string;
  points: number;
}

/**
 * A stable, documented reason code for a merchant's ops/dispute team — coarser than the analyst
 * `reasons` and safe to persist and report on (e.g. `ACCOUNT_TAKEOVER`, `VELOCITY_HIGH`). `category`
 * is left as a string so new engine categories never break the SDK.
 */
export interface ReasonCode {
  code: string;
  category: string;
}

/** A scored verdict. `score` is -1 for a list/degraded short-circuit that skipped scoring. */
export interface Decision {
  id: string;
  eventId: string;
  verdict: Verdict;
  score: number;
  reasons: Reason[];
  /** Stable, merchant-facing reason codes for the dispute/ops team. Present on recent engines. */
  reasonCodes?: ReasonCode[];
  /** One vague, verdict-level line safe to show the end customer — never names a signal. */
  customerMessage?: string;
  /** True when the decision was scored in shadow mode (not enforced). Absent/false means enforced. */
  shadow?: boolean;
  policyId?: string;
  policyVersion?: string;
  decidedAt: string;
}

/** One entry in a batch response — order matches the submitted events. A bad event fails only itself. */
export type BatchItem =
  | { ok: true; decision: Decision }
  | { ok: false; error: { code: string; message: string } };

/** The 202 acknowledgement returned by async submission. The verdict is fetched later by event id. */
export interface AsyncAck {
  accepted: boolean;
  id: string;
  correlationId?: string;
}

/** Acknowledgement that a chargeback label was recorded. */
export interface ChargebackAck {
  recorded: boolean;
}

/** Per-API-key rate-limit budget, parsed from the X-RateLimit-* response headers. */
export interface RateLimit {
  limit: number | null;
  remaining: number | null;
}
