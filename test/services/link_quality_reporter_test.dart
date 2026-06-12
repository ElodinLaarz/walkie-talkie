import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/services/audio_service.dart';
import 'package:walkie_talkie/services/link_quality_reporter.dart';

LinkTelemetrySnapshot _snap({
  int underrun = 0,
  int late = 0,
  int lost = 0,
  int target = 3,
  int current = 3,
  int bps = 16000,
  int lagMs = 0,
  int staleDrops = 0,
  int recv = 0,
  int lastSeq = 0,
}) => LinkTelemetrySnapshot(
  underrunCount: underrun,
  lateFrameCount: late,
  lostFrameCount: lost,
  targetDepthFrames: target,
  currentDepthFrames: current,
  currentBitrateBps: bps,
  currentLagMs: lagMs,
  staleDropCount: staleDrops,
  recvCount: recv,
  lastSeq: lastSeq,
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
    test('start fires onTick periodically, stop cancels the timer', () async {
      final reporter = LinkQualityReporter(
        interval: const Duration(milliseconds: 10),
      );
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
      final reporter = LinkQualityReporter(
        interval: const Duration(seconds: 1),
      );
      expect(reporter.isRunning, isFalse);
      reporter.start(onTick: () {});
      expect(reporter.isRunning, isTrue);
      reporter.stop();
      expect(reporter.isRunning, isFalse);
    });

    test('start while running cancels the previous timer + callback', () async {
      final reporter = LinkQualityReporter(
        interval: const Duration(milliseconds: 10),
      );
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

    test('debugTick fires onTick synchronously without real timers', () {
      // Mirrors the sibling schedulers' seam (SignalReporter.debugTick /
      // HeartbeatScheduler.debugTick): drive the tick path without waiting
      // on a wall-clock Timer.periodic.
      final reporter = LinkQualityReporter(
        interval: const Duration(seconds: 1),
      );
      var ticks = 0;
      reporter.start(onTick: () => ticks++);
      reporter.debugTick();
      reporter.debugTick();
      expect(ticks, 2);
      reporter.stop();
    });

    test('debugTick is a no-op after stop', () {
      // stop() clears _onTick, so a stray debugTick must not fire a
      // dangling callback.
      final reporter = LinkQualityReporter(
        interval: const Duration(seconds: 1),
      );
      var ticks = 0;
      reporter.start(onTick: () => ticks++);
      reporter.stop();
      reporter.debugTick();
      expect(ticks, 0);
    });
  });

  group('computeLinkQuality', () {
    test(
      'clean window: 0 % loss, 0 underruns/s, jitter from current depth',
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
      },
    );

    test('lossPct: lostDelta / expected * 100', () {
      // 2 s window → 100 expected frames (one Opus frame per 20 ms).
      // 7 truly-lost frames in the delta → 7 % loss.
      final prev = _snap(lost: 10);
      final curr = _snap(lost: 17);
      final out = computeLinkQuality(
        previous: prev,
        current: curr,
        elapsed: const Duration(seconds: 2),
      );
      expect(out.lossPct, closeTo(7.0, 1e-9));
    });

    test('lossPct ignores lateFrameCount entirely (Defect A decoupling)', () {
      // Jitter-buffer late/overflow churn must NOT register as loss: a huge
      // lateFrameCount delta with zero true loss is a clean link as far as
      // the bitrate adapter is concerned. This is the exact failure that
      // floored the encoder to 16 kbps on a loss-free (rx==tx) 2-device call.
      final prev = _snap(late: 0, lost: 0);
      final curr = _snap(late: 500, lost: 0);
      final out = computeLinkQuality(
        previous: prev,
        current: curr,
        elapsed: const Duration(seconds: 2),
      );
      expect(out.lossPct, 0.0);
    });

    test('lossPct clamps to 100 when lostDelta exceeds expected', () {
      // 1 s window expects 50 frames; 200 lost frames is impossible in
      // practice (counter rollover, OS hibernation) but the function
      // mustn't return a 400 % loss value into the adapter.
      final prev = _snap(lost: 0);
      final curr = _snap(lost: 200);
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
      final prev = _snap(underrun: 100, late: 100, lost: 100);
      final curr = _snap(underrun: 0, late: 0, lost: 0);
      final out = computeLinkQuality(
        previous: prev,
        current: curr,
        elapsed: const Duration(seconds: 2),
      );
      expect(out.lossPct, 0.0);
      expect(out.underrunsPerSec, 0.0);
    });

    test('sub-millisecond elapsed does not divide by zero', () {
      // Regression guard: `Duration.inMilliseconds` truncates a 500 µs
      // window to 0, which would make the underruns/sec division blow
      // up to Infinity even though the guard above only rejects
      // `<= Duration.zero`. The math must use microseconds (or some
      // other higher-resolution conversion) so the rate stays finite.
      final prev = _snap(underrun: 0, late: 0, lost: 0);
      final curr = _snap(underrun: 1, late: 1, lost: 1);
      final out = computeLinkQuality(
        previous: prev,
        current: curr,
        elapsed: const Duration(microseconds: 500),
      );
      expect(
        out.underrunsPerSec.isFinite,
        isTrue,
        reason: 'must not divide by zero',
      );
      expect(out.lossPct.isFinite, isTrue, reason: 'must not divide by zero');
      expect(out.lossPct, lessThanOrEqualTo(100.0));
    });

    test('jitterMs clamps to kMaxJitterMs when currentDepthFrames is huge', () {
      // 501 frames × 20 ms = 10020 ms, exceeds kMaxJitterMs = 10000.
      final prev = _snap(current: 0);
      final curr = _snap(current: 501);
      final out = computeLinkQuality(
        previous: prev,
        current: curr,
        elapsed: const Duration(seconds: 2),
      );
      expect(out.jitterMs, LinkQuality.kMaxJitterMs);
    });

    test(
      'underrunsPerSec clamps to kMaxUnderrunsPerSec when rate is huge',
      () {
        // 20001 underruns over 1 s → 20001/s, exceeds kMaxUnderrunsPerSec = 10000.
        final prev = _snap(underrun: 0);
        final curr = _snap(underrun: 20001);
        final out = computeLinkQuality(
          previous: prev,
          current: curr,
          elapsed: const Duration(seconds: 1),
        );
        expect(out.underrunsPerSec, LinkQuality.kMaxUnderrunsPerSec);
      },
    );

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
