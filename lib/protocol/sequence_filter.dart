/// Idempotency filter for the control plane.
///
/// BLE writes are at-least-once: a guest can reconnect mid-flight, the
/// platform layer can retry a notification, or two retransmissions can race
/// up the stack. The protocol's contract (see `docs/protocol.md` §
/// "Sequence numbers and idempotency") is that **receivers** drop messages
/// whose `seq` is `<=` the highest `seq` already accepted from the same
/// peer. This class is the per-receiver state for that rule.
///
/// Lifetime: one [SequenceFilter] per logical receive endpoint. Hosts hold
/// one keyed by `peerId` covering all guests; a guest holds one for the
/// host. After a clean disconnect the receiver MUST [forget] the peer's
/// entry — both sides reset their own outgoing counter on reconnect, and a
/// stale `lastSeq[peerId]` from the previous session would silently swallow
/// the new session's `seq=1`.
class SequenceFilter {
  final Map<String, int> _lastSeq = {};

  /// Read-only view of the highest accepted seq per peer. Useful for
  /// diagnostics and tests; the filter doesn't expose mutation here on
  /// purpose so calling code can't accidentally raise the watermark and
  /// suppress a legitimate message.
  Map<String, int> get watermarks => Map.unmodifiable(_lastSeq);

  /// Whether this is the first message we've ever seen from [peerId].
  /// Mostly for tests; in production code prefer [accept], which both
  /// answers the question and updates the watermark in one call.
  bool isFirstFrom(String peerId) => !_lastSeq.containsKey(peerId);

  /// Returns true and advances the watermark when [seq] from [peerId] is
  /// strictly greater than every prior seq from that peer. Returns false
  /// (without mutating state) for duplicates, out-of-order arrivals, or
  /// non-positive or out-of-uint32-range seqs. Receivers route an
  /// `accept == true` to message
  /// dispatch and silently drop the rest.
  ///
  /// The protocol requires `seq >= 1` and strictly monotonic increments —
  /// this filter is more permissive: it accepts any `seq > lastSeq` to
  /// stay robust against benign producer gaps (a peer that increments its
  /// counter on send-attempt rather than wire-success can skip values
  /// without breaking the receiver's view of "later than what we've
  /// seen"). The protocol's stricter "no gaps" guarantee is enforced by
  /// senders, not receivers.
  ///
  /// `seq` is a uint32 on the wire. A long-lived peer's counter eventually
  /// wraps from 0xFFFFFFFF back to 1; without special handling every
  /// post-wrap frame would read as `seq <= last` and the peer would go
  /// permanently silent until [forget] is called. To keep wraps working
  /// without letting a stale frame poison the watermark, "later than" is
  /// decided by uint32 serial-number arithmetic (RFC 1982) rather than a raw
  /// `>` comparison — see [_isAfter].
  bool accept({required String peerId, required int seq}) {
    if (seq < 1 || seq > 0xFFFFFFFF) return false;
    final last = _lastSeq[peerId];
    if (last != null && !_isAfter(last, seq)) return false;
    _lastSeq[peerId] = seq;
    return true;
  }

  /// True when [seq] is strictly *after* [last] in uint32 serial-number
  /// arithmetic (RFC 1982): the forward modular distance `(seq - last) mod
  /// 2^32` lands in `(0, 2^31)`.
  ///
  /// This is symmetric, which is the whole point. A small forward step is
  /// accepted; a duplicate (distance 0) or small backward step (distance just
  /// under 2^32) is rejected; a genuine wrap such as `0xFFFFFFFF -> 1` is a
  /// small forward step and accepted.
  ///
  /// Crucially it also rejects a *large forward* jump (distance >= 2^31). After
  /// the counter wraps and the watermark sits low (say `seq=1`), a delayed
  /// pre-wrap straggler like `0xFFFFFFF0` would otherwise read as `seq > last`,
  /// get accepted, and ratchet the watermark back up to near 0xFFFFFFFF —
  /// silently muting every real post-wrap frame until another half-range wrap.
  /// Treating that as a backward straggler keeps one late frame from killing
  /// the peer.
  static bool _isAfter(int last, int seq) {
    final forward = (seq - last) & 0xFFFFFFFF;
    return forward > 0 && forward < 0x80000000;
  }

  /// Drop the watermark for [peerId]. Callers MUST invoke this on clean
  /// disconnect (the `Leave`/`RemovePeer` flow in `docs/protocol.md` §
  /// Lifecycle) and on dirty-disconnect detection (heartbeat timeout). A
  /// reconnecting peer resets its own counter to 0 and starts the fresh
  /// session at `seq=1`; a stale watermark of, say, 7 from the previous
  /// session would swallow seq 1–7 of the new one.
  void forget(String peerId) {
    _lastSeq.remove(peerId);
  }

  /// Wipe all watermarks. Useful when entering a fresh room, where the
  /// previous room's roster is gone and any held-over watermarks would be
  /// noise at best, silent message loss at worst.
  void clear() {
    _lastSeq.clear();
  }
}
