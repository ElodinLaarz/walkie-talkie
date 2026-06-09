import 'wire_fields.dart';

// Sentinel used by [ProtocolPeer.copyWith] to distinguish "omitted" from
// explicit null so callers can clear nullable fields (e.g. btDevice: null).
const Object _noChange = Object();

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
    peerId: reqString(json, 'peerId'),
    displayName: reqString(json, 'displayName'),
    btDevice: optString(json, 'btDevice'),
    muted: optBool(json, 'muted', orElse: false),
    talking: optBool(json, 'talking', orElse: false),
  );

  ProtocolPeer copyWith({
    String? displayName,
    Object? btDevice = _noChange,
    bool? muted,
    bool? talking,
  }) {
    if (btDevice != _noChange && btDevice != null && btDevice is! String) {
      throw ArgumentError.value(btDevice, 'btDevice', 'must be a String or null');
    }
    return ProtocolPeer(
      peerId: peerId,
      displayName: displayName ?? this.displayName,
      btDevice: btDevice == _noChange ? this.btDevice : btDevice as String?,
      muted: muted ?? this.muted,
      talking: talking ?? this.talking,
    );
  }

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
