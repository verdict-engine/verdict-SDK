## 0.2.0

- **Shadow mode.** `decide`, `decideBatch`, and `decideAsync` take a `mode` parameter; pass
  `DecisionMode.shadow` to score an event without acting on it (sends `X-Verdict-Mode: shadow`).
- **Reason codes.** `Decision` now exposes `reasonCodes` (stable, merchant-facing `ReasonCode`s),
  `customerMessage` (a vague, customer-safe line), and `shadow` (whether the decision was
  non-enforcing). Older engines that omit these parse to empty / null / false.
- **Breaking:** the library entrypoint is now `package:verdict_sdk/verdict_sdk.dart` (was
  `verdict.dart`), matching the package name per pub.dev convention. Update your import.

## 0.1.0

- Initial release.
- `VerdictClient` covering the API-key data plane: `decide`, `decideBatch`, `decideAsync`,
  `getDecision`, and `recordChargeback`.
- Typed models (`VerdictEvent`, `Decision`, `Verdict`, `BatchItem`, …) and a typed exception
  hierarchy (`VerdictAuthException`, `VerdictRateLimitException`, `VerdictConnectionException`, …).
- Per-request timeout and automatic retry with backoff on 429 / 5xx / network errors.
