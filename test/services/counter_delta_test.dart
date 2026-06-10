import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/services/counter_delta.dart';

void main() {
  group('clampCounterDelta', () {
    test('normal monotonic increase passes through unchanged', () {
      expect(clampCounterDelta(100, 40), 60);
    });

    test('equal readings yield a zero delta', () {
      expect(clampCounterDelta(50, 50), 0);
    });

    test('native-side reset (current < previous) floors to 0', () {
      // Peer re-register zeroes recvCount/staleDropCount, so the next
      // snapshot reads lower than the previous one. The raw subtraction is
      // negative; clamping reads the reset as "no traffic this interval"
      // instead of poisoning a downstream rate with a negative spike.
      expect(clampCounterDelta(5, 1000), 0);
      expect(clampCounterDelta(0, 1 << 30), 0);
    });

    test('delta just below the 2^31 cap passes through', () {
      expect(clampCounterDelta((1 << 31) - 1, 0), (1 << 31) - 1);
    });

    test('delta at the 2^31 cap is preserved', () {
      expect(clampCounterDelta(1 << 31, 0), 1 << 31);
    });

    test('absurdly large delta is capped at 2^31', () {
      // One bogus snapshot can't blow up a per-second rate: a single
      // interval's contribution is bounded above by 2^31.
      expect(clampCounterDelta((1 << 31) + 5000, 0), 1 << 31);
    });
  });
}
