# Verdict SDKs

Official client libraries for the [Verdict](https://github.com/verdict-engine/verdict-engine) fraud & risk decisioning engine. One normalized event in, one explainable `allow` / `challenge` / `review` / `deny` verdict out.

Every SDK wraps the same **API-key data plane** and shares one design:

- **Score** events — synchronous (`decide`), **batched** (`decideBatch`, up to 100), or **async** (`decideAsync` + `getDecision`).
- **Shadow mode** — pass a `shadow` mode to any score call to evaluate an event **without acting on it** (sends `X-Verdict-Mode: shadow`); the verdict is logged for comparison, never enforced.
- **Reason codes** — every `Decision` carries `reasonCodes` (stable, merchant-facing codes) and a `customerMessage` (a vague, customer-safe line) alongside the analyst `reasons`, plus a `shadow` flag.
- **Label** outcomes — `recordChargeback` feeds the learning loop.
- **Resilient by default** — per-request timeout and automatic retry with exponential backoff on `429` / `5xx` / network errors, honoring `Retry-After`.
- **Typed** — event, decision, and error types mirror the engine's contract exactly; failures raise a typed error/exception hierarchy so you branch on the kind, not the status code.
- **Minimal footprint** — no heavy transitive dependencies; uses each platform's native HTTP.

| SDK | Package | Status | Directory |
|---|---|---|---|
| TypeScript / JavaScript | `@verdict/sdk` | ✅ Available | [`typescript/`](./typescript) |
| Dart / Flutter | `verdict_sdk` | ✅ Available | [`flutter/`](./flutter) |
| Python | `verdict-sdk` | 🔜 Planned | — |
| React Native | `@verdict/react-native` | 🔜 Planned | — |

## Which surface the SDKs cover

The SDKs target the **integrator-facing, API-key endpoints** — the ones a payment gateway or app backend calls on the request path. Operator/admin endpoints (auth, cases, rules, config) are driven by the dashboard and are intentionally out of scope.

| Endpoint | Method | SDK call |
|---|---|---|
| `/v1/decisions` | `POST` | `decide` |
| `/v1/decisions/batch` | `POST` | `decideBatch` |
| `/v1/decisions/async` | `POST` | `decideAsync` |
| `/v1/decisions/{id}` | `GET` | `getDecision` |
| `/v1/labels/chargeback` | `POST` | `recordChargeback` |

The three score calls accept a **mode** option — `shadow` runs the event non-enforcing (the comparison the engine's shadow report is built from). The shadow *report* itself (`GET /v1/shadow/report`) and tenant provisioning (`POST /v1/orgs`) are operator/admin surface, driven by the dashboard, and remain out of the SDKs' data-plane scope.

## Getting a key

Create a **service API key** in the dashboard (Configure → API keys), scoped to `decisions` and/or `labels`. Send it as the `X-API-Key` header — every SDK does this for you. Keep keys server-side; a key shipped in a mobile/browser binary can be extracted, so score from a trusted backend or proxy through your server.

## Versioning

Each SDK is versioned independently and targets the stable `/v1` API. Breaking changes to a client follow semver within that package.

## License

Apache-2.0
