import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/sequence_filter.dart';

void main() {
  group('SequenceFilter', () {
    test('accepts the first message from a peer', () {
      final f = SequenceFilter();
      expect(f.isFirstFrom('a'), isTrue);
      expect(f.accept(peerId: 'a', seq: 1), isTrue);
      expect(f.isFirstFrom('a'), isFalse);
    });

    test('accepts strictly increasing seqs', () {
      final f = SequenceFilter();
      expect(f.accept(peerId: 'a', seq: 1), isTrue);
      expect(f.accept(peerId: 'a', seq: 2), isTrue);
      expect(f.accept(peerId: 'a', seq: 3), isTrue);
    });

    test('rejects a duplicate seq', () {
      final f = SequenceFilter();
      expect(f.accept(peerId: 'a', seq: 5), isTrue);
      expect(f.accept(peerId: 'a', seq: 5), isFalse);
    });

    test('rejects an out-of-order seq', () {
      final f = SequenceFilter();
      expect(f.accept(peerId: 'a', seq: 5), isTrue);
      expect(f.accept(peerId: 'a', seq: 3), isFalse);
      // The watermark didn't move backwards.
      expect(f.watermarks['a'], 5);
    });

    test('rejects non-positive seqs', () {
      final f = SequenceFilter();
      expect(f.accept(peerId: 'a', seq: 0), isFalse);
      expect(f.accept(peerId: 'a', seq: -1), isFalse);
      // No watermark established yet.
      expect(f.watermarks.containsKey('a'), isFalse);
    });

    test('rejects seqs above the uint32 range', () {
      // `seq` is a uint32 on the wire; a value past 0xFFFFFFFF is out of
      // contract and must not establish or advance a watermark.
      final f = SequenceFilter();
      expect(f.accept(peerId: 'a', seq: 0x100000000), isFalse);
      expect(f.watermarks.containsKey('a'), isFalse);
      // The boundary value itself is still accepted.
      expect(f.accept(peerId: 'a', seq: 0xFFFFFFFF), isTrue);
    });

    test('tolerates gaps from senders that skip seqs', () {
      // The protocol requires monotonic +1 increments at the sender, but the
      // receiver-side filter accepts any strictly-increasing seq so a
      // misbehaving sender doesn't poison the link.
      final f = SequenceFilter();
      expect(f.accept(peerId: 'a', seq: 1), isTrue);
      expect(f.accept(peerId: 'a', seq: 5), isTrue);
      expect(f.accept(peerId: 'a', seq: 6), isTrue);
      expect(f.accept(peerId: 'a', seq: 5), isFalse);
    });

    test('per-peer watermarks are independent', () {
      final f = SequenceFilter();
      expect(f.accept(peerId: 'a', seq: 7), isTrue);
      // 'b' has its own counter; seq=1 from b is fresh.
      expect(f.accept(peerId: 'b', seq: 1), isTrue);
      expect(f.watermarks, {'a': 7, 'b': 1});
    });

    test('forget() drops just the named peer', () {
      final f = SequenceFilter();
      f.accept(peerId: 'a', seq: 7);
      f.accept(peerId: 'b', seq: 3);
      f.forget('a');
      // a's counter is gone; b's is intact.
      expect(f.isFirstFrom('a'), isTrue);
      expect(f.isFirstFrom('b'), isFalse);
      // a can now accept seq=1 (the protocol's reconnect rule).
      expect(f.accept(peerId: 'a', seq: 1), isTrue);
    });

    test('clear() wipes all watermarks', () {
      final f = SequenceFilter();
      f.accept(peerId: 'a', seq: 7);
      f.accept(peerId: 'b', seq: 3);
      f.clear();
      expect(f.watermarks, isEmpty);
      expect(f.accept(peerId: 'a', seq: 1), isTrue);
      expect(f.accept(peerId: 'b', seq: 1), isTrue);
    });

    test('watermarks are an unmodifiable view', () {
      final f = SequenceFilter();
      f.accept(peerId: 'a', seq: 7);
      final view = f.watermarks;
      expect(() => view['a'] = 99, throwsUnsupportedError);
      expect(() => view.remove('a'), throwsUnsupportedError);
      // Internal state intact.
      expect(f.accept(peerId: 'a', seq: 7), isFalse);
      expect(f.accept(peerId: 'a', seq: 8), isTrue);
    });

    test('uint32 wrap from max back to 1 is accepted', () {
      final f = SequenceFilter();
      const uint32Max = 0xFFFFFFFF;
      expect(f.accept(peerId: 'a', seq: uint32Max), isTrue);
      // Without wrap handling this would read as seq <= last and be dropped,
      // muting the peer forever. The far-backwards jump is a wrap.
      expect(f.accept(peerId: 'a', seq: 1), isTrue);
      expect(f.watermarks, {'a': 1});
      // Post-wrap counter resumes normal monotonic behaviour.
      expect(f.accept(peerId: 'a', seq: 1), isFalse);
      expect(f.accept(peerId: 'a', seq: 2), isTrue);
    });

    test(
      'ordinary backwards jump (duplicate/out-of-order) is still dropped',
      () {
        final f = SequenceFilter();
        f.accept(peerId: 'a', seq: 1000);
        // Just below watermark — a stale retransmit, not a wrap.
        expect(f.accept(peerId: 'a', seq: 999), isFalse);
        expect(f.accept(peerId: 'a', seq: 1), isFalse);
        expect(f.watermarks, {'a': 1000});
      },
    );
  });
}
