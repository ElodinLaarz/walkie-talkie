/// Typed accessors for fields decoded from wire JSON.
///
/// Every one throws [FormatException] — not the `TypeError` a bare `as` cast
/// would — when a field is missing or mistyped. The whole point: the receiver
/// in `BleControlTransport` catches `FormatException` and drops the message
/// (the connection stays up), but a `TypeError` escapes that catch and tears
/// down the receive handler. So a peer could otherwise kill the control plane
/// with one wrong-typed-but-valid JSON field.
///
/// Shared by the protocol decoders ([FrequencyMessage] subclasses,
/// [ProtocolPeer], [FrequencySession]) so the discipline lives in one place
/// instead of being copy-pasted per file.
library;

/// Required String field.
String reqString(Map<String, dynamic> j, String key) {
  final raw = j[key];
  if (raw is! String) {
    throw FormatException('`$key` must be a string, got ${raw.runtimeType}');
  }
  return raw;
}

/// Required String field bounded to [maxLen] characters (inclusive).
///
/// Like [reqString], but also rejects an over-long value as a
/// [FormatException] so a hostile or corrupt peer can't push an
/// arbitrarily large string into UI state or any re-serialization. This is
/// the string analogue of the numeric range checks ([reqSeq], [reqAtMs]):
/// free-form wire strings that have a natural upper bound get one here.
String reqBoundedString(
  Map<String, dynamic> j,
  String key, {
  required int maxLen,
}) {
  final raw = reqString(j, key);
  if (raw.length > maxLen) {
    throw FormatException(
      '`$key` exceeds max length $maxLen, got ${raw.length}',
    );
  }
  return raw;
}

/// Required int field. Note JSON `1.0` decodes to a `double` and is rejected
/// here — the protocol sends integer `seq`/`atMs`.
int reqInt(Map<String, dynamic> j, String key) {
  final raw = j[key];
  if (raw is! int) {
    throw FormatException('`$key` must be an int, got ${raw.runtimeType}');
  }
  return raw;
}

/// Required control-plane sequence field.
///
/// `seq` is the dedup/ordering key feeding [SequenceFilter]'s per-peer
/// watermark. The wire counter is a uint32 and the protocol starts it at 1,
/// so a valid `seq` lives in `[1, 0xFFFFFFFF]`. A bare [reqInt] would accept a
/// negative or near-int64-max value — valid JSON that, fed into the watermark
/// comparison, corrupts dedup state (a remote can poison the control plane).
/// Bounding it here rejects those as [FormatException] before they reach the
/// filter.
int reqSeq(Map<String, dynamic> j, String key) {
  final raw = reqInt(j, key);
  if (raw < 1 || raw > 0xFFFFFFFF) {
    throw FormatException('`$key` must be in [1, 0xFFFFFFFF], got $raw');
  }
  return raw;
}

/// Required millisecond-timestamp field, rejecting negatives.
///
/// `atMs` is a wall-clock millisecond stamp and is never negative on the wire;
/// a bare [reqInt] would accept `atMs: -1`. Bounding it to `>= 0` keeps a
/// malformed peer from feeding a nonsense timestamp into ordering/telemetry.
int reqAtMs(Map<String, dynamic> j, String key) {
  final raw = reqInt(j, key);
  if (raw < 0) {
    throw FormatException('`$key` must be >= 0, got $raw');
  }
  return raw;
}

/// Required bool field.
bool reqBool(Map<String, dynamic> j, String key) {
  final raw = j[key];
  if (raw is! bool) {
    throw FormatException('`$key` must be a bool, got ${raw.runtimeType}');
  }
  return raw;
}

/// Optional int field: null when absent, but [FormatException] when present
/// and mistyped (rather than the `TypeError` of `j[key] as int?`).
int? optInt(Map<String, dynamic> j, String key) {
  final raw = j[key];
  if (raw == null) return null;
  if (raw is! int) {
    throw FormatException(
      '`$key` must be an int when present, got ${raw.runtimeType}',
    );
  }
  return raw;
}

/// Optional String field: null when absent, but [FormatException] when present
/// and mistyped (rather than the `TypeError` of `j[key] as String?`).
String? optString(Map<String, dynamic> j, String key) {
  final raw = j[key];
  if (raw == null) return null;
  if (raw is! String) {
    throw FormatException(
      '`$key` must be a string when present, got ${raw.runtimeType}',
    );
  }
  return raw;
}

/// Optional String field bounded to [maxLen] characters (inclusive).
///
/// Like [optString], but also rejects an over-long value as a
/// [FormatException] — the optional analogue of [reqBoundedString], for
/// free-form wire strings that are absent-or-bounded.
String? optBoundedString(
  Map<String, dynamic> j,
  String key, {
  required int maxLen,
}) {
  final raw = optString(j, key);
  if (raw != null && raw.length > maxLen) {
    throw FormatException(
      '`$key` exceeds max length $maxLen, got ${raw.length}',
    );
  }
  return raw;
}

/// Optional bool field: [orElse] when absent, but [FormatException] when
/// present and mistyped (rather than the `TypeError` of `j[key] as bool?`).
bool optBool(Map<String, dynamic> j, String key, {required bool orElse}) {
  final raw = j[key];
  if (raw == null) return orElse;
  if (raw is! bool) {
    throw FormatException(
      '`$key` must be a bool when present, got ${raw.runtimeType}',
    );
  }
  return raw;
}
