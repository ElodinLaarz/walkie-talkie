import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/voice_frame.dart';

void main() {
  group('VoiceFrame', () {
    const seq = 42;
    const senderTsMs = 1714060800000 & 0xFFFFFFFF; // low 32 bits
    final payload = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);

    test('encode produces an 8-byte header + payload', () {
      final frame = VoiceFrame(seq: seq, senderTsMs: senderTsMs, payload: payload);
      final encoded = frame.encode();

      expect(encoded.length, kVoiceHeaderSize + payload.length);

      // seq at offset 0, big-endian uint32
      final view = ByteData.sublistView(encoded);
      expect(view.getUint32(0, Endian.big), seq);

      // senderTsMs at offset 4, big-endian uint32
      expect(view.getUint32(4, Endian.big), senderTsMs);

      // payload at offset 8
      expect(encoded.sublist(kVoiceHeaderSize), payload);
    });

    test('decode round-trips through encode', () {
      final original = VoiceFrame(seq: seq, senderTsMs: senderTsMs, payload: payload);
      final decoded = VoiceFrame.decode(original.encode());

      expect(decoded.seq, original.seq);
      expect(decoded.senderTsMs, original.senderTsMs);
      expect(decoded.payload, original.payload);
    });

    test('decode round-trips for seq = 0 (uint32 boundary)', () {
      final frame = VoiceFrame(
        seq: 0,
        senderTsMs: 0,
        payload: Uint8List.fromList([0xFF]),
      );
      final decoded = VoiceFrame.decode(frame.encode());
      expect(decoded.seq, 0);
      expect(decoded.senderTsMs, 0);
    });

    test('decode round-trips for seq = 0xFFFFFFFF (uint32 max)', () {
      final frame = VoiceFrame(
        seq: 0xFFFFFFFF,
        senderTsMs: 0xFFFFFFFF,
        payload: Uint8List.fromList([0xAB, 0xCD]),
      );
      final decoded = VoiceFrame.decode(frame.encode());
      expect(decoded.seq, 0xFFFFFFFF);
      expect(decoded.senderTsMs, 0xFFFFFFFF);
    });

    test('decode throws FormatException when bytes shorter than header', () {
      final tooShort = Uint8List(kVoiceHeaderSize - 1);
      expect(
        () => VoiceFrame.decode(tooShort),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode throws FormatException for header-only packet (no payload)', () {
      final headerOnly = Uint8List(kVoiceHeaderSize);
      expect(
        () => VoiceFrame.decode(headerOnly),
        throwsA(isA<FormatException>()),
      );
    });

    test('equality: same fields → equal', () {
      final a = VoiceFrame(seq: 1, senderTsMs: 100, payload: Uint8List.fromList([0x01]));
      final b = VoiceFrame(seq: 1, senderTsMs: 100, payload: Uint8List.fromList([0x01]));
      expect(a, equals(b));
    });

    test('equality: different seq → not equal', () {
      final a = VoiceFrame(seq: 1, senderTsMs: 100, payload: Uint8List.fromList([0x01]));
      final b = VoiceFrame(seq: 2, senderTsMs: 100, payload: Uint8List.fromList([0x01]));
      expect(a, isNot(equals(b)));
    });

    test('equality: different payload → not equal', () {
      final a = VoiceFrame(seq: 1, senderTsMs: 100, payload: Uint8List.fromList([0x01]));
      final b = VoiceFrame(seq: 1, senderTsMs: 100, payload: Uint8List.fromList([0x02]));
      expect(a, isNot(equals(b)));
    });

    test('toString includes seq, senderTsMs, payload length', () {
      final frame = VoiceFrame(seq: 7, senderTsMs: 999, payload: Uint8List(20));
      final s = frame.toString();
      expect(s, contains('seq=7'));
      expect(s, contains('senderTsMs=999'));
      expect(s, contains('20B'));
    });

    test('kVoiceHeaderSize is 8', () {
      expect(kVoiceHeaderSize, 8);
    });

    test('kVoiceMtu is at least 128', () {
      expect(kVoiceMtu, greaterThanOrEqualTo(128));
    });

    test('constructor throws RangeError for seq > 0xFFFFFFFF', () {
      expect(
        () => VoiceFrame(
          seq: 0x100000000,
          senderTsMs: 0,
          payload: Uint8List.fromList([0x01]),
        ),
        throwsA(isA<RangeError>()),
      );
    });

    test('constructor throws RangeError for negative seq', () {
      expect(
        () => VoiceFrame(
          seq: -1,
          senderTsMs: 0,
          payload: Uint8List.fromList([0x01]),
        ),
        throwsA(isA<RangeError>()),
      );
    });

    test('decode returns a copy independent of the source buffer', () {
      final buf = Uint8List(kVoiceHeaderSize + 2);
      final view = ByteData.sublistView(buf);
      view.setUint32(0, 1, Endian.big);
      view.setUint32(4, 2, Endian.big);
      buf[kVoiceHeaderSize] = 0xAB;
      buf[kVoiceHeaderSize + 1] = 0xCD;

      final frame = VoiceFrame.decode(buf);
      // Mutate the source buffer after decode.
      buf[kVoiceHeaderSize] = 0xFF;
      // The frame's payload must not reflect the mutation.
      expect(frame.payload[0], 0xAB);
    });
  });
}
