import 'dart:async';

import 'package:flutter/foundation.dart';

/// Drives the protocol's `ping`/heartbeat plane: emits an [onTick] every
/// [pingInterval] so the caller can send a `Heartbeat` over the wire, and
/// declares a peer "lost" when no `notePingFrom` has arrived for that peer
/// within [missThreshold].
///
/// The scheduler is **role-agnostic**. The cubit owns the host-vs-guest
/// distinction: on the host side a lost peer means "drop from roster +
/// broadcast a `RosterUpdate`"; on the guest side it means "the host went
/// silent → start the reconnect loop". The scheduler just signals.
///
/// Per [docs/protocol.md] §"Health":
///   * `pingInterval` defaults to 5 s.
///   * `missThreshold` defaults to 15 s — three consecutive missed pings.
///
/// **Lifecycle.** [start] must be called when the room is entered and
/// [stop] when it's left. [start] is idempotent: calling it twice cancels
/// the prior timer first, so callers don't need to guard against double-start.
///
/// **`lastSeen` semantics.** A peer is only tracked once they've sent at
/// least one ping (or other inbound activity routed through
/// [notePingFrom]). A peer that never pings is never declared lost — that
/// failure mode belongs to a different layer (transport-level disconnect).
class HeartbeatScheduler {
  /// Default cadence: send a ping every 5 s.
  static const Duration defaultPingInterval = Duration(seconds: 5);

  /// Default miss threshold: declare a peer lost after 15 s of silence
  /// (three missed pings at the default cadence).
  static const Duration defaultMissThreshold = Duration(seconds: 15);

  final Duration pingInterval;
  final Duration missThreshold;

  /// Test seam: lets unit tests advance "now" without sleeping. Production
  /// callers omit and get [DateTime.now].
  final DateTime Function() _now;

  Timer? _timer;
  final Map<String, DateTime> _lastSeen = {};

  void Function()? _onTick;
  void Function(String peerId)? _onPeerLost;

  HeartbeatScheduler({
    this.pingInterval = defaultPingInterval,
    this.missThreshold = defaultMissThreshold,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now {
    // Runtime checks (not `assert`s): the constraints have to hold in
    // release builds too. A zero `pingInterval` makes `Timer.periodic`
    // busy-loop; a non-positive `missThreshold` declares every peer
    // "lost" on the first tick.
    if (pingInterval <= Duration.zero) {
      throw ArgumentError.value(
        pingInterval,
        'pingInterval',
        'Must be positive — Timer.periodic(0) busy-loops.',
      );
    }
    if (missThreshold <= Duration.zero) {
      throw ArgumentError.value(
        missThreshold,
        'missThreshold',
        'Must be positive — otherwise every peer is "lost" on first tick.',
      );
    }
  }

  /// Whether the periodic timer is currently active.
  bool get isRunning => _timer != null;

  /// Starts the periodic tick. [onTick] fires every [pingInterval] so the
  /// caller can serialise + send a `Heartbeat`. [onPeerLost] fires once
  /// per peer that has crossed [missThreshold] since their last
  /// [notePingFrom]; the peer is removed from the internal table before
  /// [onPeerLost] is called, so a flapping peer needs a fresh ping to
  /// be tracked again.
  ///
  /// Calling [start] while already running cancels the previous timer
  /// and clears the [lastSeen] table — a fresh room entry shouldn't
  /// inherit watermarks from a previous session.
  void start({
    required void Function() onTick,
    required void Function(String peerId) onPeerLost,
  }) {
    stop();
    _onTick = onTick;
    _onPeerLost = onPeerLost;
    _timer = Timer.periodic(pingInterval, (_) => _tick());
  }

  /// Records that a heartbeat (or other inbound activity routed through
  /// the cubit's dispatch) just arrived from [peerId]. Resets the silence
  /// clock for that peer.
  void notePingFrom(String peerId) {
    _lastSeen[peerId] = _now();
  }

  /// Drops the watermark for [peerId] without firing [onPeerLost]. Call
  /// on clean disconnects (`Leave` / `RemovePeer` flow) so the peer's
  /// next session starts fresh — and so a stale watermark from before
  /// the clean Leave can't cause a spurious "lost" event later.
  void forgetPeer(String peerId) {
    _lastSeen.remove(peerId);
  }

  /// Cancels the timer and clears all state. Safe to call when not
  /// running (e.g. during cubit `close()` after [stop] has already
  /// fired through [leaveRoom]).
  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastSeen.clear();
    _onTick = null;
    _onPeerLost = null;
  }

  /// Read-only view of the watermark table for assertions in tests.
  @visibleForTesting
  Map<String, DateTime> get lastSeen => Map.unmodifiable(_lastSeen);

  /// Drives one tick synchronously. Used by tests to verify the
  /// onTick / onPeerLost wiring without depending on real-time timers.
  @visibleForTesting
  void debugTick() => _tick();

  void _tick() {
    _onTick?.call();
    final now = _now();
    // Snapshot keys before iterating so the onPeerLost callback can
    // mutate the map (forgetPeer / notePingFrom) without breaking the loop.
    //
    // Use `>=` so a peer silent for exactly [missThreshold] is declared
    // lost on this tick rather than the next — matches the protocol's
    // "~15 s elapsed since last arrival" wording.
    final lost = <String>[];
    _lastSeen.forEach((peerId, last) {
      if (now.difference(last) >= missThreshold) {
        lost.add(peerId);
      }
    });
    for (final peerId in lost) {
      _lastSeen.remove(peerId);
      _onPeerLost?.call(peerId);
    }
  }
}
