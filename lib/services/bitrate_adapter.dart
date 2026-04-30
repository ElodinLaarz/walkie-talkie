import '../protocol/messages.dart';

/// Three discrete encoder operating points the adapter selects between.
/// Mirrors `audio_config.h` `kBitrateLow / kBitrateMid / kBitrateHigh` —
/// the native side clamps a bitrate set to anything else into one of
/// these, so keeping the Dart-side schedule in lockstep avoids surprises.
enum BitrateLevel {
  /// 8 kbps narrowband — used when the link is degraded and we need to
  /// shed bytes to keep the jitter buffer fed.
  low(8000),

  /// 16 kbps wideband — the default operating point the encoder boots in.
  mid(16000),

  /// 24 kbps wideband — the best operating point the encoder will reach
  /// when the link has been clean for a sustained window.
  high(24000);

  const BitrateLevel(this.bps);

  /// Encoder bitrate in bits-per-second.
  final int bps;

  /// Map a native-reported bps back to the closest enum value. Used when
  /// seeding adapter state from a telemetry sample (e.g. on first feed).
  /// Returns the level whose `bps` is nearest to [bps]; ties favour the
  /// lower level (a cautious tie-break — "prefer fewer bytes" when in
  /// doubt about a fresh link).
  static BitrateLevel nearest(int bps) {
    BitrateLevel best = BitrateLevel.low;
    int bestDiff = (BitrateLevel.low.bps - bps).abs();
    for (final lvl in [BitrateLevel.mid, BitrateLevel.high]) {
      final d = (lvl.bps - bps).abs();
      if (d < bestDiff) {
        best = lvl;
        bestDiff = d;
      }
    }
    return best;
  }
}

/// Host-side stateful adapter that consumes per-peer `LinkQuality` samples
/// and decides when to step the encoder bitrate up or down. Pure logic —
/// the cubit owns the actual `BitrateHint` send and the local
/// `setPeerBitrate` call against the native `PeerAudioManager`.
///
/// **Threshold schedule** (per [docs/protocol.md] §"adaptive bitrate"):
///   * `lossPct > 12 %` sustained for [downHoldMid] → step to [BitrateLevel.low]
///     (8 kbps narrowband). Aggressive — we want to bail quickly when the
///     wire is genuinely failing.
///   * `lossPct > 5 %` sustained for [downHoldMid] → step to [BitrateLevel.mid]
///     (16 kbps wideband). Less aggressive; covers the "merely choppy"
///     case where high bitrate is overshooting capacity.
///   * `lossPct < 1 %` AND `underrunsPerSec < 0.1` sustained for [upHold]
///     → step **up one notch**. Slower than the down-step on purpose —
///     ramping back up should err on the side of caution so a brief lull
///     in loss doesn't immediately re-collide with whatever caused the
///     downstep.
///
/// **Hysteresis.** A single bad sample never trips a downstep; it must
/// hold for [downHoldMid] or [downHoldLow] in wall-clock time. Up-steps
/// require [upHold]. These aren't sample counts: a bigger reporter
/// [interval] doesn't change the dwell.
///
/// Dwell is measured against the **host-local** receipt clock, not
/// `LinkQuality.atMs` from the sender. The protocol's `atMs` is a
/// best-effort sender wall-clock with allowed peer-to-peer drift, and
/// trusting it for the 4 s / 30 s windows would let a guest with a
/// skewed clock — or a malicious one — accelerate or stall the bitrate
/// step. [feed] takes an explicit `nowMs` so callers pass
/// `DateTime.now().millisecondsSinceEpoch` (or an injected fake in
/// tests); `LinkQuality.atMs` is treated as informational only.
///
/// **Per-peer state.** Each peer has its own state machine — slow guests
/// shouldn't drag fast guests down, and a guest's state survives across
/// multiple ticks. Call [forgetPeer] on `Leave` / `RemovePeer` so a
/// re-join doesn't inherit the previous session's dwell.
///
/// **Output.** [feed] returns `null` when nothing changes (the common
/// case — most ticks land squarely inside the same level), and a
/// `BitrateLevel` when this sample triggered a step. Returning a level
/// rather than a `BitrateHint` lets the cubit construct the wire message
/// with its own `peerId` / `seq` / `atMs` envelope.
class BitrateAdapter {
  /// Loss threshold above which we drop straight to [BitrateLevel.low].
  /// Per the issue spec: 12 %.
  static const double dropToLowLossPct = 12.0;

  /// Loss threshold above which we drop to [BitrateLevel.mid] (and which
  /// holds the line if we were already at [BitrateLevel.low]).
  /// Per the issue spec: 5 %.
  static const double dropToMidLossPct = 5.0;

  /// Loss ceiling for considering a step up. Per the issue spec: 1 %.
  static const double cleanLossPct = 1.0;

  /// Underrun-rate ceiling for considering a step up. Per the issue spec:
  /// 0.1 / s.
  static const double cleanUnderrunsPerSec = 0.1;

  /// Sustained-bad dwell required before a downstep fires. Per the issue
  /// spec: 4 s. Same dwell is used for the >12 % and >5 % rules — both
  /// are "down" decisions and we want the same patience for either.
  static const Duration downHoldMid = Duration(seconds: 4);

  /// Alias preserved for documentation — the >12 % rule uses the same
  /// dwell as >5 %. Kept as a separate constant in case the protocol
  /// later wants to differentiate.
  static const Duration downHoldLow = downHoldMid;

  /// Sustained-clean dwell required before an upstep fires. Per the issue
  /// spec: 30 s. Long on purpose so a brief recovery lull doesn't drag
  /// the bitrate back up into whatever caused the downstep.
  static const Duration upHold = Duration(seconds: 30);

  final Duration _downHold;
  final Duration _upHold;

  BitrateAdapter({
    Duration? downHold,
    Duration? upHold,
  })  : _downHold = downHold ?? downHoldMid,
        _upHold = upHold ?? BitrateAdapter.upHold;

  /// Per-peer current level + the timestamp of the first contiguous sample
  /// satisfying a candidate transition. `pendingSinceMs` is null when no
  /// transition is being considered.
  final Map<String, _PeerAdapterState> _state = {};

  /// Read-only view of the current level for [peerId], or null if the
  /// adapter has never seen a sample for that peer. Useful for tests and
  /// for the cubit to seed its initial state from the native telemetry's
  /// `currentBitrateBps`.
  BitrateLevel? levelFor(String peerId) => _state[peerId]?.level;

  /// Seed the per-peer level (e.g. from the native telemetry's
  /// `currentBitrateBps` on first contact). Resets pending dwell. No-op
  /// if a state already exists — the adapter's history wins.
  void seed(String peerId, BitrateLevel level) {
    _state.putIfAbsent(peerId, () => _PeerAdapterState(level: level));
  }

  /// Feed a `LinkQuality` sample reported by [peerId] (the recipient of
  /// the host's stream — i.e. the guest whose uplink quality we're
  /// implicitly inferring from its receive-side view, *or* the peer whose
  /// local telemetry the host polled directly).
  ///
  /// [nowMs] is the **host-local** receipt timestamp in ms (typically
  /// `DateTime.now().millisecondsSinceEpoch`). All dwell accounting
  /// uses this clock, not `sample.atMs`, so a guest with a skewed or
  /// hostile clock can't manipulate the 4 s / 30 s thresholds.
  ///
  /// Returns the new [BitrateLevel] when this sample triggered a step,
  /// `null` otherwise. The caller should treat null as "leave the
  /// encoder where it is" — a no-op on the wire.
  BitrateLevel? feed(LinkQuality sample, {required int nowMs}) {
    final peerId = sample.peerId;
    final state = _state.putIfAbsent(
      peerId,
      () => _PeerAdapterState(level: BitrateLevel.mid),
    );

    final wantsDownLow = sample.lossPct > dropToLowLossPct;
    final wantsDownMid = !wantsDownLow && sample.lossPct > dropToMidLossPct;
    final wantsUp = sample.lossPct < cleanLossPct &&
        sample.underrunsPerSec < cleanUnderrunsPerSec;

    // Categorise the sample's preferred direction. A sample that's
    // neither "wants up" nor "wants down" lives in the dead zone — it
    // resets any in-flight pending transition (the link is neither
    // clearly bad nor clearly good).
    final _Direction direction;
    if (wantsDownLow) {
      direction = _Direction.downToLow;
    } else if (wantsDownMid) {
      direction = _Direction.downToMid;
    } else if (wantsUp) {
      direction = _Direction.up;
    } else {
      direction = _Direction.none;
    }

    // The pending direction tracks what we're currently building dwell
    // for. A sample that disagrees with the pending direction resets it.
    if (direction == _Direction.none ||
        state.pendingDirection != direction) {
      state.pendingDirection = direction;
      state.pendingSinceMs = direction == _Direction.none ? null : nowMs;
      return null;
    }

    // Same direction as pending — check dwell against the host-local
    // clock, not the sender's `atMs`.
    final since = state.pendingSinceMs;
    if (since == null) {
      state.pendingSinceMs = nowMs;
      return null;
    }
    final elapsedMs = nowMs - since;

    switch (direction) {
      case _Direction.downToLow:
        if (elapsedMs < _downHold.inMilliseconds) return null;
        if (state.level == BitrateLevel.low) {
          // Already at floor — clear pending so a future change can be detected.
          state.pendingDirection = _Direction.none;
          state.pendingSinceMs = null;
          return null;
        }
        state.level = BitrateLevel.low;
        state.pendingDirection = _Direction.none;
        state.pendingSinceMs = null;
        return BitrateLevel.low;

      case _Direction.downToMid:
        if (elapsedMs < _downHold.inMilliseconds) return null;
        if (state.level == BitrateLevel.high) {
          state.level = BitrateLevel.mid;
          state.pendingDirection = _Direction.none;
          state.pendingSinceMs = null;
          return BitrateLevel.mid;
        }
        // Already at mid or low — the >5 % rule shouldn't push us deeper.
        // Clear pending and wait for either a >12 % sample or a clean run.
        state.pendingDirection = _Direction.none;
        state.pendingSinceMs = null;
        return null;

      case _Direction.up:
        if (elapsedMs < _upHold.inMilliseconds) return null;
        switch (state.level) {
          case BitrateLevel.low:
            state.level = BitrateLevel.mid;
          case BitrateLevel.mid:
            state.level = BitrateLevel.high;
          case BitrateLevel.high:
            // Already at ceiling.
            state.pendingDirection = _Direction.none;
            state.pendingSinceMs = null;
            return null;
        }
        // After a step up, reset dwell so the *next* upstep starts a fresh
        // 30 s window from the host-local clock rather than carrying over
        // old dwell credit. This satisfies the "step back up one notch"
        // wording — only one level per 30 s of clean samples.
        state.pendingDirection = _Direction.up;
        state.pendingSinceMs = nowMs;
        return state.level;

      case _Direction.none:
        // Unreachable — handled above.
        return null;
    }
  }

  /// Drop adapter state for [peerId]. Call on `Leave` / `RemovePeer` so a
  /// re-join with the same `peerId` starts a fresh state machine.
  void forgetPeer(String peerId) {
    _state.remove(peerId);
  }

  /// Drop all adapter state. Call on `leaveRoom`.
  void clear() {
    _state.clear();
  }
}

class _PeerAdapterState {
  BitrateLevel level;
  _Direction pendingDirection;
  int? pendingSinceMs;

  _PeerAdapterState({required this.level})
      : pendingDirection = _Direction.none,
        pendingSinceMs = null;
}

enum _Direction { none, downToLow, downToMid, up }
