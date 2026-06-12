import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/messages.dart';
import 'audio_service.dart';
import 'counter_delta.dart';

/// Compute a `LinkQuality` rate triple from two consecutive telemetry
/// snapshots. The native side reports lifetime counters; the protocol
/// wire format wants per-second rates and a percentage, so we delta and
/// scale here.
///
/// **Loss model.** `lossPct` is `lostFrameDelta / expectedFrames * 100`,
/// where `lostFrameDelta` is the change in the native jitter buffer's *true*
/// loss counter (frames the playhead passed because they never arrived —
/// RTP-style seq-gap loss) and `expectedFrames = elapsed_ms / 20` (one Opus
/// frame per `audio_config::kFrameDurationMs`). This conservatively assumes
/// the talker was speaking continuously across the window. When voice isn't
/// flowing, `lostFrameDelta` is 0, `lossPct` is 0, and the adapter sees a
/// clean sample — which is fine: no audio means link quality is moot.
///
/// We deliberately do **not** use `lateFrameCount` here. Late/overflow drops
/// are a jitter-buffer *capacity* signal, not packet loss — driving the
/// encoder bitrate down on them is both wrong (a smaller 50 fps payload does
/// nothing for clock drift or fixed-interval jitter) and self-perpetuating
/// (the buffer keeps overflowing, so the bitrate floors and never recovers).
/// The percentage is clamped to [0, 100] so a counter rollover or bad
/// snapshot can't push absurd values into the adapter.
///
/// **Jitter model.** `jitterMs` is the *current* jitter buffer fill
/// converted to ms (`currentDepthFrames * 20`). It's an observability
/// field — the adapter ignores it; only the host UI / debug logs care.
///
/// **Underruns.** Per-second rate of mixer underruns over the window.
///
/// [elapsed] must be positive — passing zero or negative would divide by
/// zero in the rate calculation. Throws `ArgumentError` instead of
/// silently returning bogus values; callers should never produce a
/// zero-length window.
({double lossPct, int jitterMs, double underrunsPerSec}) computeLinkQuality({
  required LinkTelemetrySnapshot previous,
  required LinkTelemetrySnapshot current,
  required Duration elapsed,
}) {
  if (elapsed <= Duration.zero) {
    throw ArgumentError.value(
      elapsed,
      'elapsed',
      'Must be positive — rate computation divides by elapsed.',
    );
  }
  // 20 ms is the canonical Opus / mixer frame duration (audio_config.h
  // kFrameDurationMs). Hard-coded here rather than re-imported from the
  // native side: this file ships in pure-Dart unit tests, and a drift
  // between Dart and C++ here would be a wire-protocol drift (LinkQuality
  // values would diverge between platforms) — that's a stronger signal
  // than the avoided import.
  const frameDurationMs = 20;
  // Use microseconds for the rate math: a sub-millisecond `elapsed`
  // (legal — `Duration.zero` is the only thing the guard rejects)
  // would truncate `inMilliseconds` to 0 and turn the division into
  // Infinity. Microseconds avoid the truncation and survive the same
  // `> 0` guarantee from the guard above.
  final elapsedMicros = elapsed.inMicroseconds;
  final elapsedMs = elapsedMicros / 1000.0;
  final elapsedSeconds = elapsedMicros / 1000000.0;
  final expectedFrames = elapsedMs / frameDurationMs;

  // Lifetime counters; deltas can't go negative under normal operation.
  // clampCounterDelta swallows a counter reset (native side cleared and
  // reseeded between snapshots) so it can't poison the adapter with a
  // negative rate.
  // True network loss (seq-gap), NOT lateFrameCount — see the loss-model note
  // above for why jitter-buffer late/overflow drops must never feed the
  // bitrate adapter.
  final lostDelta = clampCounterDelta(
    current.lostFrameCount,
    previous.lostFrameCount,
  );
  final underrunDelta = clampCounterDelta(
    current.underrunCount,
    previous.underrunCount,
  );

  final lossPctRaw = expectedFrames <= 0
      ? 0.0
      : (lostDelta / expectedFrames) * 100.0;
  // `num.clamp` returns `num`, not `double`; the record's `lossPct` field is
  // typed `double`, so spell the conversion explicitly to keep the analyzer
  // (and a strict-mode reader) happy.
  final lossPct = lossPctRaw.clamp(0.0, 100.0).toDouble();

  final jitterMs =
      (current.currentDepthFrames * frameDurationMs).clamp(
        0,
        LinkQuality.kMaxJitterMs,
      );
  final underrunsPerSec =
      (underrunDelta / elapsedSeconds)
          .clamp(0.0, LinkQuality.kMaxUnderrunsPerSec)
          .toDouble();

  return (
    lossPct: lossPct,
    jitterMs: jitterMs,
    underrunsPerSec: underrunsPerSec,
  );
}

/// Drives the protocol's `link_quality` plane: emits an [onTick] every
/// [interval] so the caller can sample local `PeerAudioManager` telemetry,
/// compute deltas against the previous window, and either send a
/// `LinkQuality` over the wire (guest side) or feed the host-local
/// [BitrateAdapter] directly (host side).
///
/// Mirrors the [SignalReporter] / [HeartbeatScheduler] shape — the reporter
/// is a **timer only**. Delta arithmetic and per-peer state live in the
/// caller, partly so unit tests can drive ticks without depending on real
/// time, and partly so the host vs guest plumbing can branch without the
/// reporter knowing the difference.
///
/// Per [docs/protocol.md] §"link_quality": [defaultInterval] is 2 s — fast
/// enough that a sustained-loss rule of "loss > 12% for 4 s" trips after
/// three consecutive bad samples (the dwell is armed on the first bad
/// sample at t=0, and [BitrateAdapter] requires elapsed ≥ 4 s, so it trips
/// at t=4 s — the third sample), slow enough that the JNI hop into the
/// native telemetry struct is amortised.
///
/// **Lifecycle.** [start] is called when the local peer enters a room and
/// [stop] is called on leave. [start] is idempotent: calling it twice
/// cancels the prior timer first, so callers don't need to guard against
/// double-start.
class LinkQualityReporter {
  /// Default cadence per the protocol: sample telemetry every 2 s.
  static const Duration defaultInterval = Duration(seconds: 2);

  final Duration interval;

  Timer? _timer;
  void Function()? _onTick;

  LinkQualityReporter({this.interval = defaultInterval}) {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(
        interval,
        'interval',
        'Must be positive — Timer.periodic(0) busy-loops.',
      );
    }
  }

  /// Whether the periodic timer is currently active.
  bool get isRunning => _timer != null;

  /// Starts the periodic tick. [onTick] fires every [interval] so the
  /// caller can poll telemetry and dispatch `LinkQuality` / `BitrateHint`
  /// downstream.
  ///
  /// Calling [start] while already running cancels the previous timer
  /// before installing the new one.
  void start({required void Function() onTick}) {
    stop();
    _onTick = onTick;
    _timer = Timer.periodic(interval, (_) => _onTick?.call());
  }

  /// Cancels the timer. Safe to call when not running.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _onTick = null;
  }

  /// Fires [onTick] immediately without waiting for the next timer interval.
  /// Mirrors [HeartbeatScheduler.debugTick] / [SignalReporter.debugTick].
  @visibleForTesting
  void debugTick() => _onTick?.call();
}
