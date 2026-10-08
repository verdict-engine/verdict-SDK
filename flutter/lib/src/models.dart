/// Wire models for the Verdict decisioning API. These mirror the engine's request and response
/// shapes exactly; the SDK adds no fields of its own.
library;

/// Well-known event types. `type` is a plain `String` so a new engine event type works without an
/// SDK upgrade; these constants cover the current set.
abstract final class VerdictEventType {
  static const String cardAuthorize = 'card.authorize';
  static const String cardCapture = 'card.capture';
  static const String cardRefund = 'card.refund';
  static const String paymentAuthorize = 'payment.authorize';
  static const String walletWithdraw = 'wallet.withdraw';
  static const String accountLogin = 'account.login';
  static const String orderPlace = 'order.place';
}

/// The acting entity and the identifiers the engine links in the graph and geo/velocity signals.
class Subject {
  const Subject({
    required this.userId,
    this.deviceId,
    this.fingerprint,
    this.ip,
    this.phone,
    this.channel,
  });

  /// The acting user's stable id — the primary graph entity and the anomaly-baseline key.
  final String userId;

  /// Stable device/client id. Powers velocity, first-seen and device-linking signals.
  final String? deviceId;

  /// Client-computed device fingerprint hash — drives cloning/spoofing signals independently of [deviceId].
  final String? fingerprint;

  /// Client IP, resolved to a coarse location for geo signals. Never placed in URLs or logs.
  final String? ip;

  /// MSISDN for mobile-money / telecom rails — a graph entity for SIM-box / account-farming signals.
  final String? phone;

  /// Origin rail, e.g. "visa", "telebirr", "web".
  final String? channel;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'userId': userId,
        if (deviceId != null) 'deviceId': deviceId,
        if (fingerprint != null) 'fingerprint': fingerprint,
        if (ip != null) 'ip': ip,
        if (phone != null) 'phone': phone,
        if (channel != null) 'channel': channel,
      };
}

/// Payment instrument, for value-bearing events. Only the issuer BIN is ever sent — never a full PAN.
class Instrument {
  const Instrument({this.kind, this.bin, this.issuerCountry, this.threeDS});

  /// One of "card", "wallet", "bank".
  final String? kind;

  /// Card issuer BIN — the first 6–8 digits only.
  final String? bin;

  /// ISO-3166 issuer country, e.g. "ET".
  final String? issuerCountry;

  final bool? threeDS;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (kind != null) 'kind': kind,
        if (bin != null) 'bin': bin,
        if (issuerCountry != null) 'issuerCountry': issuerCountry,
        if (threeDS != null) 'threeDS': threeDS,
      };
}

/// A single event to score. Same shape for sync, batch, and async submission.
class VerdictEvent {
  const VerdictEvent({
    required this.type,
    required this.subject,
    this.id,
    this.amount,
    this.currency,
    this.instrument,
    this.attributes,
  });

  /// Optional client-supplied event id. Used as the idempotency key for async submission.
  final String? id;

  /// Channel-agnostic event type — see [VerdictEventType].
  final String type;

  /// Transaction value, for money-bearing events. Non-negative.
  final num? amount;

  /// ISO-4217 code, e.g. "USD". Required by the engine when [amount] is present.
  final String? currency;

  final Subject subject;
  final Instrument? instrument;

  /// Additional validated scalar signals, readable in rules as `attr.<key>`.
  final Map<String, Object>? attributes;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (id != null) 'id': id,
        'type': type,
        if (amount != null) 'amount': amount,
        if (currency != null) 'currency': currency,
        'subject': subject.toJson(),
        if (instrument != null) 'instrument': instrument!.toJson(),
        if (attributes != null) 'attributes': attributes,
      };
}

/// The decision the policy reached.
enum Verdict {
  allow,
  challenge,
  review,
  deny;

  /// Parse the engine's lowercase wire value. Unknown values fall back to [Verdict.review] (fail-safe).
  static Verdict fromWire(String value) {
    for (final v in Verdict.values) {
      if (v.name == value) return v;
    }
    return Verdict.review;
  }
}

/// Enforcement mode for a decision. [enforce] (default) acts on the verdict; [shadow] scores the
/// event without acting — logged for comparison, with no fan-out and no case opened.
enum DecisionMode {
  enforce,
  shadow;

  /// The `X-Verdict-Mode` header value, or null when the default (`enforce`) applies.
  String? get header => this == DecisionMode.shadow ? 'shadow' : null;
}

/// One signal that fired and the points it contributed — the attributable, analyst-facing explanation.
class Reason {
  const Reason({required this.tag, required this.points});

  final String tag;
  final num points;

  factory Reason.fromJson(Map<String, dynamic> json) => Reason(
        tag: json['tag'] as String,
        points: (json['points'] as num?) ?? 0,
      );
}

/// A stable, documented reason code for a merchant's ops/dispute team — coarser than the analyst
/// [Reason]s and safe to persist and report on (e.g. `ACCOUNT_TAKEOVER`). [category] is a plain
/// `String` so new engine categories never break the SDK.
class ReasonCode {
  const ReasonCode({required this.code, required this.category});

  final String code;
  final String category;

  factory ReasonCode.fromJson(Map<String, dynamic> json) => ReasonCode(
        code: json['code'] as String,
        category: (json['category'] as String?) ?? 'other',
      );
}

/// A scored verdict. [score] is -1 for a list/degraded short-circuit that skipped scoring.
class Decision {
  const Decision({
    required this.id,
    required this.eventId,
    required this.verdict,
    required this.score,
    required this.reasons,
    required this.decidedAt,
    this.reasonCodes = const <ReasonCode>[],
    this.customerMessage,
    this.shadow = false,
    this.policyId,
    this.policyVersion,
  });

  final String id;
  final String eventId;
  final Verdict verdict;
  final num score;
  final List<Reason> reasons;

  /// Stable, merchant-facing reason codes for the dispute/ops team. Empty on older engines.
  final List<ReasonCode> reasonCodes;

  /// One vague, verdict-level line safe to show the end customer — never names a signal.
  final String? customerMessage;

  /// True when the decision was scored in shadow mode (not enforced).
  final bool shadow;

  final String? policyId;
  final String? policyVersion;
  final String decidedAt;

  factory Decision.fromJson(Map<String, dynamic> json) => Decision(
        id: json['id'] as String,
        eventId: json['eventId'] as String,
        verdict: Verdict.fromWire(json['verdict'] as String),
        score: (json['score'] as num?) ?? 0,
        reasons: ((json['reasons'] as List<dynamic>?) ?? <dynamic>[])
            .map((dynamic r) => Reason.fromJson(r as Map<String, dynamic>))
            .toList(growable: false),
        reasonCodes: ((json['reasonCodes'] as List<dynamic>?) ?? <dynamic>[])
            .map((dynamic r) => ReasonCode.fromJson(r as Map<String, dynamic>))
            .toList(growable: false),
        customerMessage: json['customerMessage'] as String?,
        shadow: (json['shadow'] as bool?) ?? false,
        policyId: json['policyId'] as String?,
        policyVersion: json['policyVersion'] as String?,
        decidedAt: (json['decidedAt'] as String?) ?? '',
      );
}

/// One entry in a batch response. A malformed event yields a [BatchError]; the rest still resolve.
sealed class BatchItem {
  const BatchItem();

  factory BatchItem.fromJson(Map<String, dynamic> json) {
    if (json['ok'] == true) {
      return BatchOk(Decision.fromJson(json['decision'] as Map<String, dynamic>));
    }
    final error = (json['error'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    return BatchError(
      code: (error['code'] as String?) ?? 'UNKNOWN',
      message: (error['message'] as String?) ?? 'event failed',
    );
  }
}

/// A successfully scored event within a batch.
class BatchOk extends BatchItem {
  const BatchOk(this.decision);
  final Decision decision;
}

/// A single event within a batch that failed to score.
class BatchError extends BatchItem {
  const BatchError({required this.code, required this.message});
  final String code;
  final String message;
}

/// The 202 acknowledgement returned by async submission. The verdict is fetched later by event id.
class AsyncAck {
  const AsyncAck({required this.accepted, required this.id, this.correlationId});

  final bool accepted;
  final String id;
  final String? correlationId;

  factory AsyncAck.fromJson(Map<String, dynamic> json) => AsyncAck(
        accepted: (json['accepted'] as bool?) ?? false,
        id: json['id'] as String,
        correlationId: json['correlationId'] as String?,
      );
}

/// Acknowledgement that a chargeback label was recorded.
class ChargebackAck {
  const ChargebackAck({required this.recorded});

  final bool recorded;

  factory ChargebackAck.fromJson(Map<String, dynamic> json) =>
      ChargebackAck(recorded: (json['recorded'] as bool?) ?? false);
}

/// Per-API-key rate-limit budget, parsed from the `X-RateLimit-*` response headers.
class RateLimit {
  const RateLimit({this.limit, this.remaining});

  final int? limit;
  final int? remaining;
}
