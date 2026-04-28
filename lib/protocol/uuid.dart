import 'dart:math';

/// Generates a UUID v4 string in canonical `8-4-4-4-12` hex form using
/// `Random.secure()`. Avoids pulling in the `uuid` package for ~15 lines
/// of work; the format follows RFC 4122 §4.4 (random bits with the
/// version nibble pinned to 4 and the variant top bits to `10`).
///
/// Shared by [IdentityStore] (per-install peerId) and the host-side session
/// bootstrap in [FrequencySessionCubit] (per-session sessionUuid).
String generateUuidV4() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  // Version 4 (random) marker.
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  // RFC 4122 variant marker (10xx).
  bytes[8] = (bytes[8] & 0x3F) | 0x80;

  String segment(int from, int to) {
    final sb = StringBuffer();
    for (var i = from; i < to; i++) {
      sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  return '${segment(0, 4)}-${segment(4, 6)}-${segment(6, 8)}-'
      '${segment(8, 10)}-${segment(10, 16)}';
}
