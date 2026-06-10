import 'dart:math' as math;

import 'wire_fields.dart';

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
  String get mhzDisplay => mhzDisplayFromLow12(_low12Bits(sessionUuid));

  static const _mhzBaseTenths = 880;
  static const _mhzBuckets = 200;

  /// The single source of truth for the low-12-bits → display-frequency
  /// mapping: `tenths = 880 + (low12 % 200); mhz = tenths / 10`. The host
  /// self-view ([mhzDisplay]), the guest advertisement decode
  /// (`DiscoveredSession`), and the random preview ([randomMhzDisplay]) all
  /// route through here so the frequency a host shows agrees byte-for-byte
  /// with how guests derive it from the wire.
  static String mhzDisplayFromLow12(int low12) {
    final tenths = _mhzBaseTenths + (low12 % _mhzBuckets);
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

  /// Returns a random display frequency in [88.0, 107.9] MHz using the same
  /// 200-bucket arithmetic as [mhzDisplay], so preview UIs stay in sync with
  /// the real range without duplicating the formula.
  static String randomMhzDisplay(math.Random rnd) =>
      mhzDisplayFromLow12(rnd.nextInt(_mhzBuckets));

  static const _codeAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static int _low12Bits(String uuid) => _hexTail(uuid, 3);
  static int _low20Bits(String uuid) => _hexTail(uuid, 5);

  /// Returns the integer value of the last `nibbles` hex digits of `uuid`,
  /// or 0 if `uuid` is too short or the tail is not hex. Hyphens are ignored.
  ///
  /// The cosmetic getters ([mhzDisplay], [sessionCode]) must never throw on a
  /// wire-derived `sessionUuid` — `HostTransfer` decodes it with a bare
  /// `reqString` (no hex validation), so a peer can hand off a syntactically
  /// valid but non-hex string like `"zzzz"`. Throwing here would escape the
  /// protocol's 'drop the message, keep the link up' contract deep inside a UI
  /// getter. A 0 fallback mirrors the defensive low-12 decode in
  /// `discovery.dart` (`_deriveMhz` returns `'88.0'` on a short advert).
  static int _hexTail(String uuid, int nibbles) {
    final hex = uuid.replaceAll('-', '');
    if (hex.length < nibbles) return 0;
    return int.tryParse(hex.substring(hex.length - nibbles), radix: 16) ?? 0;
  }

  Map<String, dynamic> toJson() => {
    'sessionUuid': sessionUuid,
    'hostPeerId': hostPeerId,
  };

  factory FrequencySession.fromJson(Map<String, dynamic> json) =>
      FrequencySession(
        sessionUuid: reqString(json, 'sessionUuid'),
        hostPeerId: reqString(json, 'hostPeerId'),
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
