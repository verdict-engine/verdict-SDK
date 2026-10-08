import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:verdict_sdk/verdict_sdk.dart';

http.Response _json(Object body, {int status = 200, Map<String, String> headers = const {}}) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json', ...headers},
  );
}

final Map<String, dynamic> _decisionJson = <String, dynamic>{
  'id': 'vd_1',
  'eventId': 'evt_1',
  'verdict': 'review',
  'score': 55,
  'reasons': [
    {'tag': 'takeover', 'points': 33},
  ],
  'decidedAt': '2026-09-25T00:00:00.000Z',
};

VerdictClient _client(http.Client inner) =>
    VerdictClient(apiKey: 'vk_test_abc', baseUrl: 'https://engine.test', httpClient: inner);

void main() {
  test('requires a non-empty apiKey', () {
    expect(() => VerdictClient(apiKey: ''), throwsArgumentError);
  });

  test('scores an event and sends the API key', () async {
    final requests = <http.Request>[];
    final mock = MockClient((req) async {
      requests.add(req);
      return _json(_decisionJson);
    });

    final decision = await _client(mock).decide(
      const VerdictEvent(type: VerdictEventType.cardAuthorize, subject: Subject(userId: 'u1')),
    );

    expect(decision.verdict, Verdict.review);
    expect(decision.reasons.single.tag, 'takeover');
    expect(requests.single.url.toString(), 'https://engine.test/v1/decisions');
    expect(requests.single.headers['x-api-key'], 'vk_test_abc');
    expect(jsonDecode(requests.single.body), <String, dynamic>{
      'type': 'card.authorize',
      'subject': {'userId': 'u1'},
    });
  });

  test('forwards idempotency and correlation headers', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return _json(_decisionJson);
    });

    await _client(mock).decide(
      const VerdictEvent(type: VerdictEventType.accountLogin, subject: Subject(userId: 'u1')),
      idempotencyKey: 'idem-1',
      correlationId: 'cor-1',
    );

    expect(captured.headers['idempotency-key'], 'idem-1');
    expect(captured.headers['x-correlation-id'], 'cor-1');
  });

  test('sends X-Verdict-Mode only when shadow mode is requested', () async {
    final requests = <http.Request>[];
    final mock = MockClient((req) async {
      requests.add(req);
      return _json(_decisionJson);
    });
    final client = _client(mock);
    await client.decide(
      const VerdictEvent(type: VerdictEventType.paymentAuthorize, subject: Subject(userId: 'u1')),
    );
    await client.decide(
      const VerdictEvent(type: VerdictEventType.paymentAuthorize, subject: Subject(userId: 'u1')),
      mode: DecisionMode.shadow,
    );

    expect(requests[0].headers.containsKey('x-verdict-mode'), isFalse);
    expect(requests[1].headers['x-verdict-mode'], 'shadow');
  });

  test('parses reasonCodes, customerMessage and the shadow flag', () async {
    final mock = MockClient((req) async => _json(<String, dynamic>{
          ..._decisionJson,
          'reasonCodes': [
            {'code': 'ACCOUNT_TAKEOVER', 'category': 'takeover'},
          ],
          'customerMessage': "This payment couldn't be completed.",
          'shadow': true,
        }));

    final decision = await _client(mock).decide(
      const VerdictEvent(type: VerdictEventType.paymentAuthorize, subject: Subject(userId: 'u1')),
      mode: DecisionMode.shadow,
    );

    expect(decision.reasonCodes.single.code, 'ACCOUNT_TAKEOVER');
    expect(decision.reasonCodes.single.category, 'takeover');
    expect(decision.customerMessage, "This payment couldn't be completed.");
    expect(decision.shadow, isTrue);
  });

  test('maps 401 to VerdictAuthException', () async {
    final mock = MockClient((req) async => _json({'code': 'UNAUTHORIZED', 'message': 'bad key'}, status: 401));
    await expectLater(
      _client(mock).decide(const VerdictEvent(type: VerdictEventType.orderPlace, subject: Subject(userId: 'u1'))),
      throwsA(isA<VerdictAuthException>()),
    );
  });

  test('maps 400 to VerdictValidationException', () async {
    final mock = MockClient((req) async => _json({'code': 'INGEST_UNKNOWN_TYPE', 'message': 'bad type'}, status: 400));
    await expectLater(
      _client(mock).decide(const VerdictEvent(type: VerdictEventType.orderPlace, subject: Subject(userId: 'u1'))),
      throwsA(isA<VerdictValidationException>()),
    );
  });

  test('retries a 429 honoring Retry-After, then succeeds', () async {
    var calls = 0;
    final mock = MockClient((req) async {
      calls += 1;
      if (calls == 1) {
        return _json({'code': 'RATE_LIMITED', 'message': 'slow'}, status: 429, headers: {'retry-after': '0'});
      }
      return _json(_decisionJson);
    });

    final decision = await _client(mock).decide(
      const VerdictEvent(type: VerdictEventType.cardAuthorize, subject: Subject(userId: 'u1')),
    );
    expect(decision.eventId, 'evt_1');
    expect(calls, 2);
  });

  test('gives up after maxRetries with the rate-limit error', () async {
    var calls = 0;
    final mock = MockClient((req) async {
      calls += 1;
      return _json({'code': 'RATE_LIMITED', 'message': 'slow'}, status: 429, headers: {'retry-after': '0'});
    });

    final client = VerdictClient(apiKey: 'k', baseUrl: 'https://engine.test', httpClient: mock, maxRetries: 1);
    await expectLater(
      client.decide(const VerdictEvent(type: VerdictEventType.cardAuthorize, subject: Subject(userId: 'u1'))),
      throwsA(isA<VerdictRateLimitException>()),
    );
    expect(calls, 2);
  });

  test('exposes the rate-limit budget from response headers', () async {
    final mock = MockClient(
      (req) async => _json(_decisionJson, headers: {'x-ratelimit-limit': '600', 'x-ratelimit-remaining': '599'}),
    );
    final client = _client(mock);
    await client.decide(const VerdictEvent(type: VerdictEventType.cardAuthorize, subject: Subject(userId: 'u1')));
    expect(client.rateLimit.limit, 600);
    expect(client.rateLimit.remaining, 599);
  });

  test('rejects a batch over 100 events before calling the network', () async {
    var called = false;
    final mock = MockClient((req) async {
      called = true;
      return _json({'results': []});
    });
    final events = List<VerdictEvent>.generate(
      101,
      (_) => const VerdictEvent(type: VerdictEventType.orderPlace, subject: Subject(userId: 'u1')),
    );
    await expectLater(_client(mock).decideBatch(events), throwsArgumentError);
    expect(called, isFalse);
  });

  test('returns per-event batch results', () async {
    final mock = MockClient(
      (req) async => _json({
        'results': [
          {'ok': true, 'decision': _decisionJson},
          {
            'ok': false,
            'error': {'code': 'INGEST_UNKNOWN_TYPE', 'message': 'bad'},
          },
        ],
      }),
    );
    final results = await _client(mock).decideBatch(const [
      VerdictEvent(type: VerdictEventType.cardAuthorize, subject: Subject(userId: 'u1')),
      VerdictEvent(type: VerdictEventType.orderPlace, subject: Subject(userId: 'u2')),
    ]);
    expect(results[0], isA<BatchOk>());
    expect(results[1], isA<BatchError>());
    expect((results[1] as BatchError).code, 'INGEST_UNKNOWN_TYPE');
  });

  test('throws VerdictNotFoundException for a pending async decision', () async {
    final mock = MockClient((req) async => _json({'code': 'NOT_FOUND', 'message': 'pending'}, status: 404));
    await expectLater(_client(mock).getDecision('evt_9'), throwsA(isA<VerdictNotFoundException>()));
  });

  test('records a chargeback', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return _json({'recorded': true}, status: 202);
    });
    final ack = await _client(mock).recordChargeback('evt_1');
    expect(ack.recorded, isTrue);
    expect(captured.url.toString(), 'https://engine.test/v1/labels/chargeback');
  });
}
