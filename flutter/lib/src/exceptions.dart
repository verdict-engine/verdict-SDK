/// Exception hierarchy the client throws. Callers can branch on the subtype (rate limit vs auth vs
/// not-found vs transport) without inspecting status codes. The raw response body is never attached,
/// so secrets in a request can't leak through a thrown exception.
library;

/// Base exception for every failed Verdict API call.
class VerdictException implements Exception {
  const VerdictException(this.message, this.status, this.code, {this.correlationId});

  final String message;

  /// HTTP status, or 0 for a transport failure (network error / timeout) that never reached the engine.
  final int status;

  /// Machine-readable error code from the engine's envelope, or a synthetic one for transport failures.
  final String code;

  /// The engine's correlation id for this request, when it returned one.
  final String? correlationId;

  @override
  String toString() => 'VerdictException($status $code): $message';
}

/// 401/403 — the API key is missing, invalid, revoked, or lacks the required scope.
class VerdictAuthException extends VerdictException {
  const VerdictAuthException(String message, int status, String code, {String? correlationId})
      : super(message, status, code, correlationId: correlationId);
}

/// 404 — no decision exists for the id yet (an async decision may still be pending).
class VerdictNotFoundException extends VerdictException {
  const VerdictNotFoundException(String message, String code, {String? correlationId})
      : super(message, 404, code, correlationId: correlationId);
}

/// 400 — the request was rejected by validation before scoring.
class VerdictValidationException extends VerdictException {
  const VerdictValidationException(String message, String code, {String? correlationId})
      : super(message, 400, code, correlationId: correlationId);
}

/// 429 — the per-key decision budget is exhausted. [retryAfter] is honored by the built-in retry.
class VerdictRateLimitException extends VerdictException {
  const VerdictRateLimitException(String message, String code, {this.retryAfter, String? correlationId})
      : super(message, 429, code, correlationId: correlationId);

  /// How long to wait before retrying, from the `Retry-After` header, when provided.
  final Duration? retryAfter;
}

/// How a [VerdictConnectionException] failed.
enum ConnectionErrorKind { network, timeout }

/// The request never completed — connection failure, or it exceeded the client timeout.
class VerdictConnectionException extends VerdictException {
  VerdictConnectionException(String message, this.kind)
      : super(message, 0, kind == ConnectionErrorKind.timeout ? 'TIMEOUT' : 'NETWORK');

  final ConnectionErrorKind kind;
}
