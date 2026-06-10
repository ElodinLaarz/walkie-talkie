import 'dart:math';

import 'hex.dart';

/// Generates a UUID v4 string in canonical `8-4-4-4-12` hex form using
/// `Random.secure()`. Avoids pulling in the `uuid` package for ~15 lines
/// of work; the format follows RFC 4122 §4.4 (random bits with the
/// version nibble pinned to 4 and the variant top bits to `10`).
///
/// Shared by [IdentityStore] (per-install peerId) and the host-side session
/// bootstrap in [FrequencySessionCubit] (per-session sessionUuid).
/// Canonical UUID regex: `8-4-4-4-12` lowercase hex groups.
final _kCanonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Returns true when [uuid] matches the canonical `8-4-4-4-12` hex form
/// produced by [generateUuidV4] (all lowercase, no surrounding whitespace).
bool isCanonicalUuid(String uuid) => _kCanonicalUuid.hasMatch(uuid);

String generateUuidV4() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  // Version 4 (random) marker.
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  // RFC 4122 variant marker (10xx).
  bytes[8] = (bytes[8] & 0x3F) | 0x80;

  String segment(int from, int to) => hexEncode(bytes.getRange(from, to));

  return '${segment(0, 4)}-${segment(4, 6)}-${segment(6, 8)}-'
      '${segment(8, 10)}-${segment(10, 16)}';
}
