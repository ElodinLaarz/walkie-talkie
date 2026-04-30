import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/services/audio_service.dart';
import 'package:walkie_talkie/services/link_quality_reporter.dart';

LinkTelemetrySnapshot _snap({
  int underrun = 0,
  int late = 0,
  int target = 3,
  int current = 3,
  int bps = 16000,
}) =>
    LinkTelemetrySnapshot(
      underrunCount: underrun,
      lateFrameCount: late,
      targetDepthFrames: target,
      currentDepthFrames: current,
      currentBitrateBps: bps,
    );

void main() {
  group('LinkQualityReporter defaults', () {
    test('default interval matches the protocol: 2 s', () {
      // Load-bearing constant — the BitrateAdapter's "sustained 4 s"
      // downstep rule needs exactly two ticks at 2 s. Bumping this
      // changes how quickly the adapter trips.
      expect(LinkQualityReporter.defaultInterval, const Duration(seconds: 2));
    });

    test('rejects a non-positive interval', () {
      expect(
        () => LinkQualityReporter(interval: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => LinkQualityReporter(interval: const Duration(seconds: -1)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('LinkQualityReporter.start / stop', () {
    test('start fires onTick periodically, stop cancels the timer',
        () async {
      final reporter =
          LinkQualityReporter(interval: const Duration(milliseconds: 10));
      var ticks = 0;
      reporter.start(onTick: () => ticks++);
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(ticks, greaterThanOrEqualTo(2));
      reporter.stop();
      final ticksAtStop = ticks;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ticks, ticksAtStop, reason: 'no further ticks after stop');
    });

    test('isRunning toggles on start / stop', () {
      final reporter =
          LinkQualityReporter(interval: const Duration(seconds: 1));
      expect(reporter.isRunning, isFalse);
      reporter.start(onTick: () {});
      expect(reporter.isRunning, isTrue);
      reporter.stop();
      expect(reporter.isRunning, isFalse);
    });

    test('start while running cancels the previous timer + callback',
        () async {
      final reporter =
          LinkQualityReporter(interval: const Duration(milliseconds: 10));
      var ticks1 = 0;
      reporter.start(onTick: () => ticks1++);
      var ticks2 = 0;
      reporter.start(onTick: () => ticks2++);
      await Future<void>.delayed(const Duration(milliseconds: 35));
      final ticks1AtSwap = ticks1;
      reporter.stop();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ticks1, ticks1AtSwap);
      expect(ticks2, greaterThan(0));
    });

    test('stop is safe when never started', () {
      final reporter = LinkQualityReporter();
      expect(reporter.stop, returnsNormally);
    });
  });

  group('computeLinkQuality', () {
    test('clean window: 0 % loss, 0 underruns/s, jitter from current depth',
        () {
      final prev = _snap(underrun: 5, late: 2, current: 3);
      final curr = _snap(underrun: 5, late: 2, current: 4);
      final out = computeLinkQuality(
        previous: prev,
        current: curr,
        elapsed: const Duration(seconds: 2),
      );
      expect(out.lossPct, 0.0);
      expect(out.underrunsPerSec, 0.0);
      // 4 frames * 20 ms.
      expect(out.jitterMs, 80);
    });

    test('lossPct: lateDelta / expected * 100', () {
      // 2 s window → 100 expected frames (one Opus frame per 20 ms).
      // 7 late frames in the delta → 7 % loss.
      final prev = _snap(late: 10);
      final curr = _snap(late: 17);
      final out = computeLinkQuality(
        previous: prev,
        current: curr,
        elapsed: const Duration(seconds: 2),
      );
      expect(out.lossPct, closeTo(7.0, 1e-9));
    });

    test('lossPct clamps to 100 when lateDelta exceeds expected', () {
      // 1 s window expects 50 frames; 200 late frames is impossible in
      // practice (counter rollover, OS hibernation) but the function
      // mustn't return a 400 % loss value into the adapter.
      final prev = _snap(late: 0);
      final curr = _snap(late: 200);
      final out = computeLinkQuality(
        previous: prev,
        current: curr,
        elapsed: const Duration(seconds: 1),
      );
      expect(out.lossPct, 100.0);
    });

    test('underrunsPerSec: delta / interval in seconds', () {
      final prev = _snap(underrun: 10);
      final curr = _snap(underrun: 16);
      final out = computeLinkQuality(
        previous: prev,
        current: curr,
        elapsed: const Duration(seconds: 2),
      );
      // 6 underruns over 2 s → 3.0 / s.
      expect(out.underrunsPerSec, closeTo(3.0, 1e-9));
    });

    test('counter reset (delta < 0) clamps to zero rather than throwing', () {
      // Native side cleared and reseeded between snapshots — current is
      // *less* than previous. Treat as zero delta, not a negative rate.
      final prev = _snap(underrun: 100, late: 100);
      final curr = _snap(underrun: 0, late: 0);
      final out = computeLinkQuality(
        previous: prev,
        current: curr,
        elapsed: const Duration(seconds: 2),
      );
      expect(out.lossPct, 0.0);
      expect(out.underrunsPerSec, 0.0);
    });

    test('non-positive elapsed throws ArgumentError', () {
      final prev = _snap();
      final curr = _snap();
      expect(
        () => computeLinkQuality(
          previous: prev,
          current: curr,
          elapsed: Duration.zero,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => computeLinkQuality(
          previous: prev,
          current: curr,
          elapsed: const Duration(seconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
