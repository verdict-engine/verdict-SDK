# @verdict/sdk

Official **TypeScript / JavaScript** client for the [Verdict](https://github.com/verdict-engine/verdict-engine) fraud & risk decisioning engine.

Submit one normalized event and receive an explainable `allow`, `challenge`, `review`, or `deny` verdict — with retries, timeouts, typed errors, and full type definitions, in a dependency-free package.

- **Zero runtime dependencies** — uses the platform `fetch` (Node 18+, Deno, Bun, browsers, edge runtimes).
- **Dual ESM + CommonJS** with bundled `.d.ts`.
- **Typed end to end** — the wire types mirror the engine's contract exactly.
- **Resilient** — per-request timeout and automatic backoff on `429`/`5xx`/network blips, honoring `Retry-After`.

## Install

```bash
npm install @verdict/sdk
```

## Quick start

```ts
import { VerdictClient } from "@verdict/sdk";

const verdict = new VerdictClient({
  apiKey: process.env.VERDICT_API_KEY!,   // a service key (vk_live_…) from the dashboard
  baseUrl: "https://verdict.internal",     // defaults to http://localhost:4000
});

const decision = await verdict.decide({
  type: "card.authorize",
  amount: 4900,
  currency: "ETB",
  subject: {
    userId: "usr_3f9a",
    ip: "196.188.120.4",
    fingerprint: "fp_9c1e77a2b4",
    channel: "telebirr",
  },
  instrument: { kind: "card", bin: "411111", issuerCountry: "ET", threeDS: false },
});

switch (decision.verdict) {
  case "allow":     return proceed();
  case "challenge": return stepUp();          // 3DS / OTP
  case "review":    return holdForReview();   // a case is opened in the dashboard
  case "deny":      return block(decision.reasons);
}
```

Every decision carries the `score` and the `reasons` that produced it — the full, attributable explanation you can log or show an analyst.

> **Never send a full PAN.** Pass only the issuer `bin` (first 6–8 digits). The `ip` is used for geolocation signals and is never placed in URLs or logs.

## API

### `new VerdictClient(options)`

| Option | Type | Default | |
|---|---|---|---|
| `apiKey` | `string` | — | **Required.** Sent as the `X-API-Key` header. |
| `baseUrl` | `string` | `http://localhost:4000` | Engine origin. |
| `timeoutMs` | `number` | `10000` | Per-request timeout. |
| `maxRetries` | `number` | `2` | Retries for `429`/`5xx`/network errors, with exponential backoff. |
| `fetch` | `typeof fetch` | global `fetch` | Inject a custom transport or polyfill. |

### `decide(event, options?) → Promise<Decision>`

Score one event synchronously.

```ts
const d = await verdict.decide(event, {
  idempotencyKey: "order-1234",   // a retry returns the original decision instead of recomputing
  correlationId: "req-abc",       // threaded through the engine's logs and events
  mode: "shadow",                 // score without acting — logged for comparison, never enforced
});
```

The `Decision` includes `reasonCodes` (stable, merchant-facing codes), `customerMessage` (a vague line safe to show a customer), and `shadow` (whether it was non-enforcing), alongside the analyst `reasons`.

### `decideBatch(events, options?) → Promise<BatchItem[]>`

Score up to **100** events in one call. Results preserve order; a malformed event fails only its own entry.

```ts
const results = await verdict.decideBatch([event1, event2]);
for (const r of results) {
  if (r.ok) console.log(r.decision.verdict);
  else console.warn(r.error.code);
}
```

### `decideAsync(event, options?) → Promise<AsyncAck>` and `getDecision(eventId) → Promise<Decision>`

Submit off the response path (returns `202` immediately), then fetch the verdict by event id. `getDecision` throws `VerdictNotFoundError` while the decision is still pending.

```ts
const { id } = await verdict.decideAsync({ id: "evt_9f2a", ...event });
// …later, or from a webhook on verdict.reached.v1…
const decision = await verdict.getDecision("evt_9f2a");
```

> For high throughput, prefer a **webhook** subscription to `verdict.reached.v1` over polling `getDecision`.

### `recordChargeback(eventId) → Promise<ChargebackAck>`

Record a chargeback for a previously-scored event as a fraud label (requires a key with the `labels` scope). This feeds the learning loop.

### `client.rateLimit → { limit, remaining }`

The per-key budget parsed from the `X-RateLimit-*` headers of the most recent call.

## Errors

Every failure throws a subclass of `VerdictError`, so you can branch without parsing status codes:

```ts
import { VerdictRateLimitError, VerdictAuthError, VerdictConnectionError } from "@verdict/sdk";

try {
  await verdict.decide(event);
} catch (err) {
  if (err instanceof VerdictRateLimitError) await backoff(err.retryAfterMs);
  else if (err instanceof VerdictAuthError) rotateKey();
  else if (err instanceof VerdictConnectionError) failOpenOrClosed();
  else throw err;
}
```

| Class | When |
|---|---|
| `VerdictValidationError` | `400` — the event was rejected before scoring. |
| `VerdictAuthError` | `401` / `403` — key missing, invalid, revoked, or out of scope. |
| `VerdictNotFoundError` | `404` — no decision for that id yet (async still pending). |
| `VerdictRateLimitError` | `429` — per-key budget exhausted; carries `retryAfterMs`. |
| `VerdictConnectionError` | Network failure or client timeout (`code: "NETWORK" | "TIMEOUT"`). |
| `VerdictError` | Any other non-2xx (e.g. `5xx`). |

The raw response body is never attached to a thrown error, so request data can't leak through your logs.

## Decisioning is on the request path — decide how to fail

A `deny` should block; a transport failure is a product decision. Wrap the call and choose **fail-open** (allow on engine outage, favoring availability) or **fail-closed** (challenge/deny on outage, favoring safety) per event type — the same choice the engine exposes as a policy's `onError`.

## Runtime support

Node 18+, Deno, Bun, modern browsers, and edge runtimes (Cloudflare Workers, Vercel Edge). On Node < 18, pass a `fetch` implementation (e.g. `undici`).

## License

Apache-2.0
