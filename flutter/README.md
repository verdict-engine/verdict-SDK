# verdict_sdk

Official **Dart / Flutter** client for the [Verdict](https://github.com/verdict-engine/verdict-engine) fraud & risk decisioning engine.

Submit one normalized event and receive an explainable `allow`, `challenge`, `review`, or `deny` verdict — with retries, timeouts, typed exceptions, and null-safe models. Works in Flutter (Android, iOS, web, desktop) and server-side Dart.

## Install

```yaml
dependencies:
  verdict_sdk: ^0.1.0
```

```dart
import 'package:verdict_sdk/verdict_sdk.dart';
```

## Quick start

```dart
final verdict = VerdictClient(
  apiKey: const String.fromEnvironment('VERDICT_API_KEY'),
  baseUrl: 'https://verdict.internal', // defaults to http://localhost:4000
);

final decision = await verdict.decide(const VerdictEvent(
  type: VerdictEventType.cardAuthorize,
  amount: 4900,
  currency: 'ETB',
  subject: Subject(
    userId: 'usr_3f9a',
    ip: '196.188.120.4',
    fingerprint: 'fp_9c1e77a2b4',
    channel: 'telebirr',
  ),
  instrument: Instrument(kind: 'card', bin: '411111', issuerCountry: 'ET', threeDS: false),
));

switch (decision.verdict) {
  case Verdict.allow:     proceed();
  case Verdict.challenge: stepUp();          // 3DS / OTP
  case Verdict.review:    holdForReview();   // a case is opened in the dashboard
  case Verdict.deny:      block(decision.reasons);
}

verdict.close(); // release the HTTP client when done
```

Every decision carries the `score` and the `reasons` that produced it — the full, attributable explanation.

> **Security:** never send a full PAN — pass only the issuer `bin` (first 6–8 digits). Do this scoring from a backend or a trusted context; a service API key embedded in a shipped mobile binary can be extracted. For untrusted clients, proxy through your server.

## Methods

| Method | Purpose |
|---|---|
| `decide(event, {idempotencyKey, correlationId, mode})` | Score one event synchronously → `Decision`. Pass `mode: DecisionMode.shadow` to score without acting. |
| `decideBatch(events, {mode})` | Score up to 100 events → `List<BatchItem>` (`BatchOk` / `BatchError`). |
| `decideAsync(event, {mode})` | Submit off the response path → `AsyncAck` (202). |
| `getDecision(eventId)` | Fetch an async verdict by event id (throws `VerdictNotFoundException` while pending). |
| `recordChargeback(eventId)` | Record a chargeback as a fraud label (needs the `labels` scope). |
| `rateLimit` | The `{ limit, remaining }` from the last call's `X-RateLimit-*` headers. |

`Decision` carries `reasonCodes` (stable, merchant-facing `ReasonCode`s), `customerMessage` (a vague, customer-safe line), and `shadow` (whether it was non-enforcing), alongside the analyst `reasons`.

`BatchItem` is a sealed type — switch exhaustively:

```dart
for (final item in await verdict.decideBatch(events)) {
  switch (item) {
    case BatchOk(:final decision): print(decision.verdict);
    case BatchError(:final code):  print('failed: $code');
  }
}
```

## Configuration

```dart
VerdictClient(
  apiKey: '…',
  baseUrl: 'https://verdict.internal',
  timeout: const Duration(seconds: 10),
  maxRetries: 2,          // retries 429 / 5xx / network with backoff, honoring Retry-After
  httpClient: myClient,   // optional: inject an http.Client (proxy, or for testing)
);
```

## Errors

Every failure throws a subtype of `VerdictException`:

| Type | When |
|---|---|
| `VerdictValidationException` | `400` — event rejected before scoring. |
| `VerdictAuthException` | `401` / `403` — key missing, invalid, revoked, or out of scope. |
| `VerdictNotFoundException` | `404` — no decision for that id yet (async still pending). |
| `VerdictRateLimitException` | `429` — budget exhausted; carries `retryAfter`. |
| `VerdictConnectionException` | Network failure or timeout (`kind`: `network` / `timeout`). |
| `VerdictException` | Any other non-2xx. |

```dart
try {
  await verdict.decide(event);
} on VerdictRateLimitException catch (e) {
  await Future<void>.delayed(e.retryAfter ?? const Duration(seconds: 1));
} on VerdictConnectionException {
  failOpenOrClosed(); // your availability-vs-safety choice on an engine outage
}
```

## License

Apache-2.0
