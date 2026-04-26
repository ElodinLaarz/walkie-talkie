/// Identity of a single frequency room.
///
/// `sessionUuid` is canonical and used for all routing decisions. The
/// `mhzDisplay` and `sessionCode` are derived deterministically from it for
/// invite UX — they're cosmetic and not collision-free.
class FrequencySession {
  final String sessionUuid;
  final String hostPeerId;

  const FrequencySession({required this.sessionUuid, required this.hostPeerId});

  /// Mapped from the low 12 bits of the UUID into [88.0, 107.9] MHz at
  /// 0.1-MHz precision (200 evenly-distributed buckets). Cosmetic —
  /// collisions happen and are disambiguated in the UI by host name and
  /// signal strength.
  String get mhzDisplay {
    final tenths = 880 + (_low12Bits(sessionUuid) % 200);
    return (tenths / 10.0).toStringAsFixed(1);
  }

  /// 4-character Crockford base32 of the low 20 bits of the UUID. Suitable
  /// for an invite code that's quick to read aloud — the alphabet excludes
  /// `I`, `L`, `O`, `U` to avoid look-alike characters.
  String get sessionCode {
    var n = _low20Bits(sessionUuid);
    final out = StringBuffer();
    for (var i = 0; i < 4; i++) {
      out.write(_codeAlphabet[n & 0x1F]);
      n >>= 5;
    }
    return out.toString();
  }

  static const _codeAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static int _low12Bits(String uuid) => _hexTail(uuid, 3);
  static int _low20Bits(String uuid) => _hexTail(uuid, 5);

  /// Returns the integer value of the last `nibbles` hex digits of `uuid`.
  /// Hyphens are ignored.
  static int _hexTail(String uuid, int nibbles) {
    final hex = uuid.replaceAll('-', '');
    if (hex.length < nibbles) {
      throw FormatException('UUID too short: $uuid');
    }
    return int.parse(hex.substring(hex.length - nibbles), radix: 16);
  }

  Map<String, dynamic> toJson() => {
        'sessionUuid': sessionUuid,
        'hostPeerId': hostPeerId,
      };

  factory FrequencySession.fromJson(Map<String, dynamic> json) =>
      FrequencySession(
        sessionUuid: json['sessionUuid'] as String,
        hostPeerId: json['hostPeerId'] as String,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FrequencySession &&
          sessionUuid == other.sessionUuid &&
          hostPeerId == other.hostPeerId;

  @override
  int get hashCode => Object.hash(sessionUuid, hostPeerId);

  @override
  String toString() => 'FrequencySession($sessionUuid host=$hostPeerId)';
}
