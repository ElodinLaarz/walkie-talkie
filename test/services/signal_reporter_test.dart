import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/services/signal_reporter.dart';

void main() {
  group('SignalReporter defaults', () {
    test('default interval matches the protocol: 10 s', () {
      // Load-bearing constant — bumping it changes how quickly a host
      // notices a degraded peer. Pinning here so a casual edit triggers
      // a test failure and forces the protocol doc to be re-read.
      expect(SignalReporter.defaultInterval, const Duration(seconds: 10));
    });

    test('rejects a non-positive interval', () {
      // Runtime check (not assert) so the contract holds in release.
      expect(
        () => SignalReporter(interval: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => SignalReporter(interval: const Duration(seconds: -1)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('SignalReporter.start / stop', () {
    test('start fires onTick periodically, stop cancels the timer',
        () async {
      final reporter =
          SignalReporter(interval: const Duration(milliseconds: 10));

      var ticks = 0;
      reporter.start(onTick: () => ticks++);

      // Wait long enough to observe ≥ 2 ticks but bound the upper end
      // so the test isn't sensitive to millisecond-level timer accuracy.
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(ticks, greaterThanOrEqualTo(2));

      reporter.stop();
      final ticksAtStop = ticks;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ticks, ticksAtStop, reason: 'no further ticks after stop');
    });

    test('isRunning toggles on start / stop', () {
      final reporter = SignalReporter(
        interval: const Duration(seconds: 1),
      );
      expect(reporter.isRunning, isFalse);
      reporter.start(onTick: () {});
      expect(reporter.isRunning, isTrue);
      reporter.stop();
      expect(reporter.isRunning, isFalse);
    });

    test('start while running cancels the previous timer + callback',
        () async {
      final reporter =
          SignalReporter(interval: const Duration(milliseconds: 10));

      var ticks1 = 0;
      reporter.start(onTick: () => ticks1++);

      // Re-start with a fresh callback. The first counter must stop
      // incrementing after the swap.
      var ticks2 = 0;
      reporter.start(onTick: () => ticks2++);

      await Future<void>.delayed(const Duration(milliseconds: 35));
      final ticks1AtSwap = ticks1;
      reporter.stop();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // ticks1's timer was cancelled at swap — no further increments.
      expect(ticks1, ticks1AtSwap);
      expect(ticks2, greaterThan(0));
    });

    test('stop is safe when never started', () {
      final reporter = SignalReporter();
      expect(reporter.stop, returnsNormally);
    });

    test('stop is idempotent', () {
      final reporter = SignalReporter(
        interval: const Duration(seconds: 1),
      );
      reporter.start(onTick: () {});
      reporter.stop();
      expect(reporter.stop, returnsNormally);
    });
  });
}
