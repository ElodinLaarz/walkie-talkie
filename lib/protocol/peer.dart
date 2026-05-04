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

  factory ProtocolPeer.fromJson(Map<String, dynamic> json) => ProtocolPeer(
    peerId: json['peerId'] as String,
    displayName: json['displayName'] as String,
    btDevice: json['btDevice'] as String?,
    muted: json['muted'] as bool? ?? false,
    talking: json['talking'] as bool? ?? false,
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
