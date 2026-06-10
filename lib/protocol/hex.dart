import 'dart:typed_data';

/// Lowercase, fixed-width hex coding for the bytes that ride the BLE wire
/// (session-UUID fragments, generated UUIDs). Centralised here so the
/// "two lowercase digits per byte" convention lives in one place instead of
/// being copy-pasted per file — the same discipline `wire_fields.dart` applies
/// to typed JSON field access.

/// Encodes [bytes] as a lowercase hex string, two digits per byte and no
/// separators (e.g. `[0x0a, 0xff]` -> `"0aff"`).
///
/// Each value is masked to its low 8 bits (`b & 0xFF`) so the "two digits per
/// byte" invariant holds even if a caller passes an out-of-range or negative
/// value — without the mask, `b > 255` emits 3+ chars and a negative `b` emits
/// a `-`-prefixed string, both of which desync round-trips through [hexDecode]
/// (which assumes exactly two chars per byte).
String hexEncode(Iterable<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Decodes a hex string into bytes. Returns an empty list on any malformed
/// input (odd length, non-hex characters) so callers can fall back to a
/// default value rather than crashing on a bad payload from the wire.
Uint8List hexDecode(String hex) {
  if (hex.length.isOdd) return Uint8List(0);
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < hex.length; i += 2) {
    final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (byte == null) return Uint8List(0);
    result[i ~/ 2] = byte;
  }
  return result;
}
