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
  /// permanently silent until [forget] is called. A large backwards jump
  /// (more than half the uint32 space) is therefore treated as a wrap and
  /// accepted, advancing the watermark — consistent with the
  /// receiver-permissive posture documented above.
  bool accept({required String peerId, required int seq}) {
    if (seq < 1 || seq > 0xFFFFFFFF) return false;
    final last = _lastSeq[peerId];
    if (last != null && seq <= last && !_isWrap(last, seq)) return false;
    _lastSeq[peerId] = seq;
    return true;
  }

  /// True when going from [last] to [seq] looks like a uint32 counter wrap
  /// rather than a stale/duplicate frame: the backwards gap exceeds half the
  /// uint32 range (2^31). A duplicate or mildly out-of-order frame sits just
  /// below the watermark and is correctly rejected; a genuine wrap lands far
  /// below it (e.g. 0xFFFFFFFF -> 1).
  static bool _isWrap(int last, int seq) => last - seq > 0x80000000;

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
