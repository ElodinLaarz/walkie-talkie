import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/framing.dart';

void main() {
  group('encodeFragments', () {
    test('a small message fits in one fragment', () {
      final fragments = encodeFragments('{"k":"v"}');
      expect(fragments, hasLength(1));
      final f = fragments.single;
      expect(f[0], 0x00);
      expect(f[1], 0); // total_len_hi
      expect(f[2], 9); // total_len_lo
      expect(f[3], 0); // fragment_idx
      expect(utf8.decode(f.sublist(kFragmentHeaderSize)), '{"k":"v"}');
    });

    test('a message exactly one payload long produces a single fragment', () {
      final json = 'a' * kMaxFragmentPayloadSize;
      final fragments = encodeFragments(json);
      expect(fragments, hasLength(1));
      expect(fragments.single.length, kMaxFragmentSize);
    });

    test('a message one byte over fragment payload spills to a second fragment',
        () {
      final json = 'a' * (kMaxFragmentPayloadSize + 1);
      // total_len is wire bytes (UTF-8), not Dart's UTF-16 code-unit count.
      // For the all-ASCII fixture they happen to coincide, but the assertion
      // should compare against bytes so it stays correct if the fixture
      // ever grows non-ASCII.
      final totalLen = utf8.encode(json).length;
      final fragments = encodeFragments(json);
      expect(fragments, hasLength(2));
      // First fragment full, second carries one byte of payload.
      expect(fragments[0].length, kMaxFragmentSize);
      expect(fragments[1].length, kFragmentHeaderSize + 1);
      // total_len header is identical across fragments and matches the input.
      expect((fragments[0][1] << 8) | fragments[0][2], totalLen);
      expect((fragments[1][1] << 8) | fragments[1][2], totalLen);
      // fragment_idx increments.
      expect(fragments[0][3], 0);
      expect(fragments[1][3], 1);
    });

    test('a 2 KiB message fragments and reassembles to bytes-identical JSON',
        () {
      final json = jsonEncode({
        'kind': 'roster_update',
        'roster': List.generate(
          12,
          (i) => {
            'peerId': 'p$i' * 8,
            'displayName': 'Person $i with a longish handle',
            'btDevice': 'AirPods Max #$i',
            'muted': false,
            'talking': false,
          },
        ),
      });
      final fragments = encodeFragments(json);
      // ~2 KiB at 243 bytes/fragment ≈ 9 fragments.
      expect(fragments.length, greaterThan(1));
      final r = FragmentReassembler();
      String? out;
      for (final f in fragments) {
        out = r.feed(f);
      }
      expect(out, json);
    });

    test('the empty string still emits one (header-only) fragment', () {
      final fragments = encodeFragments('');
      expect(fragments, hasLength(1));
      expect(fragments.single.length, kFragmentHeaderSize);
    });

    test('messages over the v1 cap are rejected', () {
      final tooBig = 'a' * (kMaxMessageSize + 1);
      expect(() => encodeFragments(tooBig), throwsFormatException);
    });

    test('multibyte UTF-8 sequences reassemble correctly across fragment boundaries',
        () {
      // Build a message that puts a 2-byte UTF-8 sequence ('é' = 0xC3 0xA9)
      // straddling a fragment boundary in JSON-byte space. Fragmentation
      // operates on bytes (it must — we can't peek at codepoint structure
      // through the GATT MTU) and the reassembler's utf8.decode at the
      // end stitches the codepoint back together. Regression guard
      // against anyone "fixing" the splitter to be character-aware.
      final junk = 'a' * (kMaxFragmentPayloadSize - 1);
      final json = '$junké$junk';
      final fragments = encodeFragments(json);
      expect(fragments.length, greaterThan(1));
      final r = FragmentReassembler();
      String? out;
      for (final f in fragments) {
        out = r.feed(f);
      }
      expect(out, json);
    });
  });

  group('FragmentReassembler', () {
    test('returns null on intermediate fragments and the message on the last',
        () {
      final json = 'x' * (kMaxFragmentPayloadSize * 2 + 5);
      final fragments = encodeFragments(json);
      expect(fragments, hasLength(3));
      final r = FragmentReassembler();
      expect(r.feed(fragments[0]), isNull);
      expect(r.feed(fragments[1]), isNull);
      expect(r.feed(fragments[2]), json);
    });

    test('reassembler is reusable across messages', () {
      final r = FragmentReassembler();
      final a = encodeFragments('{"k":"a"}');
      final b = encodeFragments('{"k":"b"}');
      expect(r.feed(a.single), '{"k":"a"}');
      expect(r.feed(b.single), '{"k":"b"}');
    });

    test('a fragment shorter than the header is rejected', () {
      final r = FragmentReassembler();
      expect(
        () => r.feed(Uint8List.fromList([0x00, 0x00])),
        throwsA(isA<MalformedFragment>()),
      );
    });

    test('an unknown flags byte is rejected', () {
      final r = FragmentReassembler();
      final bad = Uint8List.fromList([0x42, 0x00, 0x01, 0x00, 0x61]);
      expect(() => r.feed(bad), throwsA(isA<MalformedFragment>()));
    });

    test('a non-zero starting fragment_idx is rejected', () {
      final r = FragmentReassembler();
      // total_len=10, idx=1, payload='abc' — but the buffer is empty so
      // idx must be 0.
      final bad = Uint8List.fromList([0x00, 0x00, 0x0A, 0x01, 0x61, 0x62, 0x63]);
      expect(() => r.feed(bad), throwsA(isA<UnexpectedFragmentIndex>()));
    });

    test('an out-of-order continuation fragment is rejected', () {
      final json = 'x' * (kMaxFragmentPayloadSize + 5);
      final fragments = encodeFragments(json);
      final r = FragmentReassembler();
      expect(r.feed(fragments[0]), isNull);
      // Synthesize a fragment with idx=2 instead of idx=1.
      final tampered = Uint8List.fromList(fragments[1])..[3] = 0x02;
      expect(() => r.feed(tampered), throwsA(isA<UnexpectedFragmentIndex>()));
    });

    test('a continuation with a different total_len is rejected', () {
      final json = 'x' * (kMaxFragmentPayloadSize + 5);
      final fragments = encodeFragments(json);
      final r = FragmentReassembler();
      expect(r.feed(fragments[0]), isNull);
      // Bump total_len_lo from N to N+1 on the continuation.
      final tampered = Uint8List.fromList(fragments[1]);
      tampered[2] = (tampered[2] + 1) & 0xFF;
      expect(() => r.feed(tampered), throwsA(isA<InconsistentFragment>()));
    });

    test('a declared total_len above the v1 cap is rejected', () {
      // total_len = 0x1FFF (8191) > 4096 cap.
      final bad = Uint8List.fromList([0x00, 0x1F, 0xFF, 0x00, 0x61]);
      final r = FragmentReassembler();
      expect(() => r.feed(bad), throwsA(isA<InconsistentFragment>()));
    });

    test('fragment payload that overshoots the declared length is rejected',
        () {
      // total_len declared as 2, but payload is 3 bytes.
      final bad = Uint8List.fromList([0x00, 0x00, 0x02, 0x00, 0x61, 0x62, 0x63]);
      final r = FragmentReassembler();
      expect(() => r.feed(bad), throwsA(isA<InconsistentFragment>()));
    });

    test('after a violation, the reassembler is reset and accepts a new message',
        () {
      final r = FragmentReassembler();
      try {
        r.feed(Uint8List.fromList([0x00, 0x00]));
      } on MalformedFragment {
        // expected
      }
      // Fresh, well-formed message lands cleanly.
      final fragments = encodeFragments('{"k":"v"}');
      expect(r.feed(fragments.single), '{"k":"v"}');
    });

    test('reset() drops in-flight buffer without surfacing an error', () {
      final json = 'x' * (kMaxFragmentPayloadSize + 5);
      final fragments = encodeFragments(json);
      final r = FragmentReassembler();
      expect(r.feed(fragments[0]), isNull);
      r.reset();
      // Re-feeding the original message starts fresh and completes.
      expect(r.feed(fragments[0]), isNull);
      expect(r.feed(fragments[1]), json);
    });
  });
}
