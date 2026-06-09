// Sentinel used by [ProtocolPeer.copyWith] to distinguish "omitted" from
// explicit null so callers can clear nullable fields (e.g. btDevice: null).
const Object _noChange = Object();

// Wire-field parsers that throw [FormatException] (not the `TypeError` a bare
// `as` cast raises) when a field is missing or mistyped, so the control-plane
// receiver drops the message instead of crashing. Mirrors the helpers in
// messages.dart; kept private to this file since they can't be shared across
// the library boundary.
String _reqString(Map<String, dynamic> j, String key) {
  final raw = j[key];
  if (raw is! String) {
    throw FormatException('`$key` must be a string, got ${raw.runtimeType}');
  }
  return raw;
}

String? _optString(Map<String, dynamic> j, String key) {
  final raw = j[key];
  if (raw == null) return null;
  if (raw is! String) {
    throw FormatException(
      '`$key` must be a string when present, got ${raw.runtimeType}',
    );
  }
  return raw;
}

bool _optBool(Map<String, dynamic> j, String key, {required bool orElse}) {
  final raw = j[key];
  if (raw == null) return orElse;
  if (raw is! bool) {
    throw FormatException(
      '`$key` must be a bool when present, got ${raw.runtimeType}',
    );
  }
  return raw;
}

/// Protocol-layer view of a peer in a frequency.
///
/// Distinct from the UI's `Person` (in `lib/data/frequency_models.dart`),
/// which carries presentation-only fields like `hue` and short `initials`.
class ProtocolPeer {
  final String peerId;
  final String displayName;
  final String? btDevice;
  final bool muted;
  final bool talking;

  const ProtocolPeer({
    required this.peerId,
    required this.displayName,
    this.btDevice,
    this.muted = false,
    this.talking = false,
  });

  Map<String, dynamic> toJson() => {
    'peerId': peerId,
    'displayName': displayName,
    if (btDevice != null) 'btDevice': btDevice,
    'muted': muted,
    'talking': talking,
  };

  /// Decodes a peer from wire JSON, throwing [FormatException] — not the
  /// `TypeError` a bare `as` cast would — on a missing or mistyped field. A
  /// `ProtocolPeer` arrives nested inside a `roster`/`JoinAccepted`, so a
  /// `TypeError` here would escape the control-plane receiver's
  /// `FormatException`-only catch and crash it on one malformed roster entry.
  factory ProtocolPeer.fromJson(Map<String, dynamic> json) => ProtocolPeer(
    peerId: _reqString(json, 'peerId'),
    displayName: _reqString(json, 'displayName'),
    btDevice: _optString(json, 'btDevice'),
    muted: _optBool(json, 'muted', orElse: false),
    talking: _optBool(json, 'talking', orElse: false),
  );

  ProtocolPeer copyWith({
    String? displayName,
    Object? btDevice = _noChange,
    bool? muted,
    bool? talking,
  }) => ProtocolPeer(
    peerId: peerId,
    displayName: displayName ?? this.displayName,
    btDevice: btDevice == _noChange ? this.btDevice : btDevice as String?,
    muted: muted ?? this.muted,
    talking: talking ?? this.talking,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProtocolPeer &&
          peerId == other.peerId &&
          displayName == other.displayName &&
          btDevice == other.btDevice &&
          muted == other.muted &&
          talking == other.talking;

  @override
  int get hashCode =>
      Object.hash(peerId, displayName, btDevice, muted, talking);

  @override
  String toString() =>
      'ProtocolPeer($peerId, $displayName, bt=$btDevice, muted=$muted, talking=$talking)';
}
