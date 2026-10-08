import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'exceptions.dart';
import 'models.dart';

/// A thin, cross-platform client for the Verdict decisioning API. It wraps the API-key data plane:
/// scoring events (sync, batch, async), fetching an async result, and recording chargeback labels.
/// Works in Flutter (mobile, web, desktop) and server-side Dart.
///
/// ```dart
/// final verdict = VerdictClient(apiKey: 'vk_live_…', baseUrl: 'https://verdict.internal');
/// final decision = await verdict.decide(VerdictEvent(
///   type: VerdictEventType.cardAuthorize,
///   amount: 4900, currency: 'ETB',
///   subject: Subject(userId: 'usr_3f9a', ip: '196.188.120.4', fingerprint: 'fp_9c1e'),
/// ));
/// if (decision.verdict == Verdict.deny) { /* block */ }
/// verdict.close();
/// ```
class VerdictClient {
  VerdictClient({
    required String apiKey,
    String baseUrl = 'http://localhost:4000',
    Duration timeout = const Duration(seconds: 10),
    int maxRetries = 2,
    http.Client? httpClient,
  })  : _apiKey = apiKey,
        _baseUrl = _trimTrailingSlash(baseUrl),
        _timeout = timeout,
        _maxRetries = maxRetries,
        _ownsClient = httpClient == null,
        _http = httpClient ?? http.Client() {
    if (apiKey.isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'VerdictClient requires a non-empty apiKey');
    }
  }

  final String _apiKey;
  final String _baseUrl;
  final Duration _timeout;
  final int _maxRetries;
  final http.Client _http;
  final bool _ownsClient;
  final Random _random = Random();
  RateLimit _lastRateLimit = const RateLimit();

  /// The rate-limit budget reported by the most recent call, from the `X-RateLimit-*` headers.
  RateLimit get rateLimit => _lastRateLimit;

  /// Score one event synchronously and return its verdict.
  ///
  /// Pass [mode] `DecisionMode.shadow` to score without acting — the verdict is logged for
  /// comparison (no fan-out, no case), the comparison the shadow report is built from.
  Future<Decision> decide(
    VerdictEvent event, {
    String? idempotencyKey,
    String? correlationId,
    DecisionMode mode = DecisionMode.enforce,
  }) async {
    final headers = <String, String>{
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
      if (correlationId != null) 'X-Correlation-Id': correlationId,
      if (mode.header != null) 'X-Verdict-Mode': mode.header!,
    };
    final json = await _request('POST', '/v1/decisions', body: event.toJson(), headers: headers);
    return Decision.fromJson(json as Map<String, dynamic>);
  }

  /// Score up to 100 events in one call. Results preserve order; a malformed event fails only itself.
  Future<List<BatchItem>> decideBatch(
    List<VerdictEvent> events, {
    String? correlationId,
    DecisionMode mode = DecisionMode.enforce,
  }) async {
    if (events.isEmpty) return const <BatchItem>[];
    if (events.length > 100) {
      throw ArgumentError('decideBatch accepts at most 100 events, got ${events.length}');
    }
    final headers = <String, String>{
      if (correlationId != null) 'X-Correlation-Id': correlationId,
      if (mode.header != null) 'X-Verdict-Mode': mode.header!,
    };
    final body = <String, dynamic>{'events': events.map((e) => e.toJson()).toList()};
    final json = await _request('POST', '/v1/decisions/batch', body: body, headers: headers);
    final results = (json as Map<String, dynamic>)['results'] as List<dynamic>? ?? <dynamic>[];
    return results
        .map((dynamic r) => BatchItem.fromJson(r as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Submit an event off the response path. Returns a 202 acknowledgement; fetch the verdict later
  /// with [getDecision].
  Future<AsyncAck> decideAsync(
    VerdictEvent event, {
    String? correlationId,
    DecisionMode mode = DecisionMode.enforce,
  }) async {
    final headers = <String, String>{
      if (correlationId != null) 'X-Correlation-Id': correlationId,
      if (mode.header != null) 'X-Verdict-Mode': mode.header!,
    };
    final json = await _request('POST', '/v1/decisions/async', body: event.toJson(), headers: headers);
    return AsyncAck.fromJson(json as Map<String, dynamic>);
  }

  /// Fetch a decision by its event id. Throws [VerdictNotFoundException] while an async decision is
  /// still pending or if the id is unknown.
  Future<Decision> getDecision(String eventId) async {
    final json = await _request('GET', '/v1/decisions/${Uri.encodeComponent(eventId)}');
    return Decision.fromJson(json as Map<String, dynamic>);
  }

  /// Record a chargeback for a previously-scored event as a fraud label (requires the `labels` scope).
  Future<ChargebackAck> recordChargeback(String eventId) async {
    final json = await _request('POST', '/v1/labels/chargeback', body: <String, dynamic>{'eventId': eventId});
    return ChargebackAck.fromJson(json as Map<String, dynamic>);
  }

  /// Release the underlying HTTP client. Call when done, unless you supplied your own `httpClient`.
  void close() {
    if (_ownsClient) _http.close();
  }

  Future<Object?> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String> headers = const <String, String>{},
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await _send(method, path, body: body, headers: headers);
      } on VerdictException catch (err) {
        final wait = _retryDelay(err, attempt);
        if (wait == null) rethrow;
        await Future<void>.delayed(wait);
        attempt += 1;
      }
    }
  }

  Future<Object?> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final requestHeaders = <String, String>{
      'X-API-Key': _apiKey,
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      ...headers,
    };

    http.Response res;
    try {
      final Future<http.Response> pending = method == 'GET'
          ? _http.get(uri, headers: requestHeaders)
          : _http.post(uri, headers: requestHeaders, body: body == null ? null : jsonEncode(body));
      res = await pending.timeout(_timeout);
    } on TimeoutException {
      throw VerdictConnectionException('request timed out after ${_timeout.inMilliseconds}ms', ConnectionErrorKind.timeout);
    } on http.ClientException catch (e) {
      throw VerdictConnectionException(e.message, ConnectionErrorKind.network);
    } catch (_) {
      // dart:io SocketException and platform transport errors surface here on non-web targets.
      throw VerdictConnectionException('network request failed', ConnectionErrorKind.network);
    }

    _captureRateLimit(res);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) return null;
      return jsonDecode(res.body);
    }
    throw _toException(res);
  }

  VerdictException _toException(http.Response res) {
    final correlationId = res.headers['x-correlation-id'];
    var code = 'HTTP_${res.statusCode}';
    var message = 'request failed with status ${res.statusCode}';
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) {
        code = (decoded['code'] as String?) ?? code;
        message = (decoded['message'] as String?) ?? (decoded['error'] as String?) ?? message;
      }
    } catch (_) {
      // Non-JSON error body — keep the synthetic code/message.
    }

    switch (res.statusCode) {
      case 400:
        return VerdictValidationException(message, code, correlationId: correlationId);
      case 401:
      case 403:
        return VerdictAuthException(message, res.statusCode, code, correlationId: correlationId);
      case 404:
        return VerdictNotFoundException(message, code, correlationId: correlationId);
      case 429:
        return VerdictRateLimitException(message, code, retryAfter: _retryAfter(res), correlationId: correlationId);
      default:
        return VerdictException(message, res.statusCode, code, correlationId: correlationId);
    }
  }

  void _captureRateLimit(http.Response res) {
    _lastRateLimit = RateLimit(
      limit: _intHeader(res, 'x-ratelimit-limit'),
      remaining: _intHeader(res, 'x-ratelimit-remaining'),
    );
  }

  /// Delay before the next attempt, or null when the error must not be retried.
  Duration? _retryDelay(VerdictException err, int attempt) {
    if (attempt >= _maxRetries) return null;
    if (err is VerdictRateLimitException) return err.retryAfter ?? _backoff(attempt);
    if (err is VerdictConnectionException && err.kind == ConnectionErrorKind.network) return _backoff(attempt);
    // 5xx are transient; 4xx (other than 429) are the caller's to fix.
    if (err.status >= 500) return _backoff(attempt);
    return null;
  }

  /// Exponential backoff (250ms, 500ms, 1s, …) with jitter to avoid retry stampedes.
  Duration _backoff(int attempt) {
    final base = 250 * pow(2, attempt).toInt();
    return Duration(milliseconds: base + _random.nextInt(100));
  }

  static Duration? _retryAfter(http.Response res) {
    final raw = res.headers['retry-after'];
    if (raw == null) return null;
    final seconds = int.tryParse(raw);
    return seconds == null ? null : Duration(seconds: seconds);
  }

  static int? _intHeader(http.Response res, String name) {
    final raw = res.headers[name];
    return raw == null ? null : int.tryParse(raw);
  }

  static String _trimTrailingSlash(String url) => url.replaceAll(RegExp(r'/+$'), '');
}
