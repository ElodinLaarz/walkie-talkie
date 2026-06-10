import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/hex.dart';

void main() {
  group('hexEncode', () {
    test('encodes clean bytes as two lowercase digits each', () {
      expect(hexEncode([0x0a, 0xff]), '0aff');
      expect(hexEncode(Uint8List.fromList([0, 1, 16, 255])), '000110ff');
    });

    test('pads single-digit bytes to two chars', () {
      expect(hexEncode([0, 5, 15]), '00050f');
    });

    test('masks out-of-range values to the low 8 bits', () {
      // Without the mask, 0x100 would emit "100" (three chars), desyncing the
      // two-chars-per-byte invariant.
      expect(hexEncode([0x100]), '00');
      expect(hexEncode([0x1ff]), 'ff');
      expect(hexEncode([0xabcd]), 'cd');
    });

    test('masks negative values to the low 8 bits', () {
      // Without the mask, -1 would emit "-1", breaking round-trips.
      expect(hexEncode([-1]), 'ff');
      expect(hexEncode([-256]), '00');
    });

    test('every encoded byte is exactly two chars for any input', () {
      final out = hexEncode([0, 255, 0x100, -1, 0xabcd]);
      expect(out.length, 5 * 2);
      expect(out, matches(RegExp(r'^[0-9a-f]+$')));
    });
  });

  group('hexDecode', () {
    test('rejects leading sign in first chunk', () {
      expect(hexDecode('-1'), Uint8List(0));
      expect(hexDecode('+a'), Uint8List(0));
    });

    test('rejects sign in interior chunk', () {
      expect(hexDecode('0-'), Uint8List(0));
      expect(hexDecode('ff0+'), Uint8List(0));
    });

    test('rejects odd-length input', () {
      expect(hexDecode('a'), Uint8List(0));
      expect(hexDecode('abc'), Uint8List(0));
    });

    test('accepts valid hex strings', () {
      expect(hexDecode('0aff'), Uint8List.fromList([0x0a, 0xff]));
      expect(hexDecode('AABB'), Uint8List.fromList([0xaa, 0xbb]));
    });
  });

  group('hexEncode/hexDecode round-trip', () {
    test('clean bytes survive a round-trip', () {
      final bytes = Uint8List.fromList([0, 1, 127, 128, 255, 16, 240]);
      expect(hexDecode(hexEncode(bytes)), bytes);
    });

    test('masked encoding round-trips to the masked value', () {
      expect(hexDecode(hexEncode([0x1ff])), Uint8List.fromList([0xff]));
    });
  });
}
