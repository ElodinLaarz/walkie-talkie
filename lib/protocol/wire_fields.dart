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

/// Required int field. Note JSON `1.0` decodes to a `double` and is rejected
/// here — the protocol sends integer `seq`/`atMs`.
int reqInt(Map<String, dynamic> j, String key) {
  final raw = j[key];
  if (raw is! int) {
    throw FormatException('`$key` must be an int, got ${raw.runtimeType}');
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
