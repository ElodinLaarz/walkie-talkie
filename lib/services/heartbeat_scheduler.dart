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

  /// When voice was last seen *arriving* on the link, or null if never. While
  /// this is within [pingInterval] of now, [_tick] suppresses the outbound GATT
  /// ping — see [noteVoiceActivity]. Used for the receive direction, which has
  /// no clean "stopped" edge: the caller refreshes it each inbound tick and it
  /// lapses naturally when frames stop.
  DateTime? _lastVoiceActivityAt;

  /// Whether we are *currently transmitting* voice. Unlike
  /// [_lastVoiceActivityAt] this is edge-driven and never goes stale, so it
  /// keeps the ping suppressed for the whole of a long utterance even on the
  /// host, which has no periodic tick to refresh a timestamp. See
  /// [setTransmitting].
  bool _transmittingVoice = false;

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

  /// Records that voice traffic is actively flowing on the link *right now*
  /// (a frame was just sent or received). While voice has been seen within
  /// [pingInterval], [_tick] skips the dedicated GATT heartbeat: the voice
  /// stream itself — plus, on the guest, the 2 s link-quality plane — already
  /// proves liveness to the peer, so the extra control-plane write is pure
  /// radio contention that periodically stalls the L2CAP voice CoC.
  ///
  /// **Suppression is one-directional and safe.** Only the *outbound* ping is
  /// skipped; inbound peer-loss detection ([missThreshold] scan) still runs
  /// every tick. The caller is responsible for also feeding inbound voice into
  /// [notePingFrom] so a peer that goes voice-silent-but-alive (and stops
  /// pinging because *it* sees our voice) isn't wrongly declared lost.
  void noteVoiceActivity() {
    _lastVoiceActivityAt = _now();
  }

  /// Sets whether local voice is *currently transmitting*. While true, [_tick]
  /// suppresses the outbound ping with no risk of the watermark going stale
  /// mid-utterance — important on the host, which (unlike the guest's 2 s
  /// link-quality tick) has no periodic refresh path. Drive it from the local
  /// talking edges: `setTransmitting(true)` on talk-start, `false` on talk-end.
  void setTransmitting(bool transmitting) {
    _transmittingVoice = transmitting;
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
    _lastVoiceActivityAt = null;
    _transmittingVoice = false;
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
    final now = _now();
    // Suppress the outbound GATT ping while voice is actively flowing: the
    // voice stream (and, guest-side, the 2 s link-quality plane) already prove
    // liveness, so the redundant control-plane write only adds radio
    // contention that stalls the L2CAP voice CoC. The miss-threshold scan
    // below is unaffected — we still detect a peer that goes truly silent.
    final lastVoice = _lastVoiceActivityAt;
    final voiceRecentlyReceived =
        lastVoice != null && now.difference(lastVoice) < pingInterval;
    final suppressPing = _transmittingVoice || voiceRecentlyReceived;
    if (!suppressPing) {
      _onTick?.call();
    }
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
