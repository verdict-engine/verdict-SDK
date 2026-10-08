# Changelog

## 0.2.0

- **Shadow mode.** `decide`, `decideBatch`, and `decideAsync` accept `options.mode`; pass `"shadow"`
  to score an event without acting on it (sends `X-Verdict-Mode: shadow`).
- **Reason codes.** `Decision` now includes `reasonCodes` (stable, merchant-facing `ReasonCode`s),
  `customerMessage` (a vague, customer-safe line), and `shadow` (whether the decision was
  non-enforcing). Fields are optional — older engines that omit them parse to `undefined`.

## 0.1.0

- Initial release.
- `VerdictClient` covering the API-key data plane: `decide`, `decideBatch`, `decideAsync`,
  `getDecision`, and `recordChargeback`.
- Typed event/decision/error models and a typed error hierarchy.
- Per-request timeout and automatic retry with backoff on 429 / 5xx / network errors.
