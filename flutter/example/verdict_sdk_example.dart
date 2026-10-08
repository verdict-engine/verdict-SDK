import 'package:verdict_sdk/verdict_sdk.dart';

/// Minimal end-to-end example: score a card authorization and act on the verdict.
Future<void> main() async {
  final verdict = VerdictClient(
    apiKey: const String.fromEnvironment('VERDICT_API_KEY'),
    baseUrl: const String.fromEnvironment('VERDICT_BASE_URL', defaultValue: 'http://localhost:4000'),
  );

  try {
    final decision = await verdict.decide(
      const VerdictEvent(
        type: VerdictEventType.cardAuthorize,
        amount: 4900,
        currency: 'ETB',
        subject: Subject(userId: 'usr_3f9a', ip: '196.188.120.4', fingerprint: 'fp_9c1e77a2b4'),
        instrument: Instrument(kind: 'card', bin: '411111', issuerCountry: 'ET'),
      ),
      idempotencyKey: 'order-1234',
    );

    print('verdict=${decision.verdict.name} score=${decision.score}');
    for (final reason in decision.reasons) {
      print('  • ${reason.tag} (+${reason.points})');
    }
  } on VerdictRateLimitException catch (e) {
    print('rate limited; retry after ${e.retryAfter}');
  } on VerdictException catch (e) {
    print('decision failed: $e');
  } finally {
    verdict.close();
  }
}
