import 'dart:async';

import 'audio_service.dart';

/// Compute a `LinkQuality` rate triple from two consecutive telemetry
/// snapshots. The native side reports lifetime counters; the protocol
/// wire format wants per-second rates and a percentage, so we delta and
/// scale here.
///
/// **Loss model.** `lossPct` is `lateFrameDelta / expectedFrames * 100`,
/// where `expectedFrames = elapsed_ms / 20` (one Opus frame per
/// `audio_config::kFrameDurationMs`). This conservatively assumes the
/// talker was speaking continuously across the window. When voice isn't
/// flowing, `lateFrameDelta` is 0, `lossPct` is 0, and the adapter sees
/// a clean sample — which is fine: no audio means link quality is moot.
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
  final elapsedMs = elapsed.inMilliseconds;
  final expectedFrames = elapsedMs / frameDurationMs;

  // Lifetime counters; deltas can't go negative under normal operation.
  // Clamp to zero to swallow a counter reset (e.g. native side cleared and
  // reseeded between snapshots) without poisoning the adapter with a
  // negative rate.
  final lateDelta =
      (current.lateFrameCount - previous.lateFrameCount).clamp(0, 1 << 31);
  final underrunDelta =
      (current.underrunCount - previous.underrunCount).clamp(0, 1 << 31);

  final lossPctRaw =
      expectedFrames <= 0 ? 0.0 : (lateDelta / expectedFrames) * 100.0;
  // `num.clamp` returns `num`, not `double`; the record's `lossPct` field is
  // typed `double`, so spell the conversion explicitly to keep the analyzer
  // (and a strict-mode reader) happy.
  final lossPct = lossPctRaw.clamp(0.0, 100.0).toDouble();

  final jitterMs = current.currentDepthFrames * frameDurationMs;
  final underrunsPerSec = underrunDelta / (elapsedMs / 1000.0);

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
/// two consecutive bad samples, slow enough that the JNI hop into the
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
}
