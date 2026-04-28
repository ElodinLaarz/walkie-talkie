import 'dart:async';

/// Drives the protocol's `signal_report` plane: emits an [onTick] every
/// [interval] so the caller can sample local RSSI and send a `SignalReport`
/// over the wire.
///
/// Mirrors [HeartbeatScheduler]'s shape — the reporter is a **timer only**.
/// The cubit owns the actual sample + send (so the seq counter, peerId
/// resolution, and transport gating live in one place).
///
/// Per [docs/protocol.md] §"signal_report": [defaultInterval] is 10 s.
///
/// **Lifecycle.** [start] is called on the guest side when the room is
/// entered (the host receives reports rather than sending them) and [stop]
/// is called on leave. [start] is idempotent: calling it twice cancels the
/// prior timer first, so callers don't need to guard against double-start.
class SignalReporter {
  /// Default cadence per the protocol: send a `SignalReport` every 10 s.
  static const Duration defaultInterval = Duration(seconds: 10);

  final Duration interval;

  Timer? _timer;
  void Function()? _onTick;

  SignalReporter({this.interval = defaultInterval}) {
    // Runtime check (not `assert`): the constraint must hold in release
    // builds too. A non-positive interval makes Timer.periodic busy-loop.
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
  /// caller can build + send a `SignalReport` over the transport.
  ///
  /// Calling [start] while already running cancels the previous timer
  /// before installing the new one — a fresh room entry shouldn't keep
  /// the old [onTick] callback alive.
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
