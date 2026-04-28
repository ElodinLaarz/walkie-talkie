import '../protocol/messages.dart';

/// Host-side detector that consumes incoming `SignalReport`s and decides
/// when to surface a "weak signal" toast for a specific neighbor.
///
/// Per the protocol: a neighbor whose RSSI stays below
/// [weakThresholdDbm] for [consecutiveReportsToTrip] reports trips a
/// toast. Subsequent toasts for the same neighbor are rate-limited to
/// one per [toastRateLimit] window so a peer hovering at the edge of
/// range doesn't spam the host's UI.
///
/// **Per-neighbor counting.** Counters key on the `peerId` of the
/// neighbor inside the report (the *subject* of the RSSI), not the
/// reporter's `peerId`. The protocol doesn't require the same reporter
/// to confirm a weak peer twice in a row; any two consecutive reports
/// where neighbor X is weak trip the toast.
///
/// **Reset on a strong report.** A neighbor whose RSSI rises back above
/// the threshold in any report immediately clears the consecutive-weak
/// counter for that neighbor. The rate-limit timer is independent — it
/// only resets after the cooldown elapses, so a flapping peer can't
/// surface a toast every two reports.
///
/// **Per-report independence.** A neighbor that's missing from a report
/// (e.g. the reporter couldn't sample its RSSI this round) does *not*
/// reset its counter. Two reports with neighbor X weak then a third
/// report omitting X then a fourth with X weak still trips, because the
/// gap was silence rather than a positive "X is now strong" signal.
class WeakSignalDetector {
  /// dBm threshold below which a neighbor is considered weak. Per the
  /// issue spec: -80 dBm.
  static const int weakThresholdDbm = -80;

  /// Number of consecutive weak observations needed to trip a toast.
  /// Per the issue spec: 2.
  static const int consecutiveReportsToTrip = 2;

  /// Minimum time between toasts for the same neighbor. Per the issue
  /// spec: 60 s.
  static const Duration toastRateLimit = Duration(seconds: 60);

  /// Test seam: lets unit tests advance "now" without sleeping.
  /// Production callers omit and get [DateTime.now].
  final DateTime Function() _now;

  final Map<String, int> _consecutiveWeak = {};
  final Map<String, DateTime> _lastToastAt = {};

  WeakSignalDetector({DateTime Function()? clock})
      : _now = clock ?? DateTime.now;

  /// Process [report] from a guest. Returns the neighbor `peerId`s that
  /// should fire a toast on this report (after threshold + rate-limit
  /// gates). The list is empty when nothing trips.
  ///
  /// State is mutated atomically per report: counters are advanced for
  /// every weak neighbor before the rate-limit gate runs, so two weak
  /// neighbors on the same report can both trip on the same call.
  List<String> onReport(SignalReport report) {
    final fired = <String>[];
    for (final n in report.neighbors) {
      if (n.rssi < weakThresholdDbm) {
        final next = (_consecutiveWeak[n.peerId] ?? 0) + 1;
        _consecutiveWeak[n.peerId] = next;
        if (next < consecutiveReportsToTrip) continue;
        final now = _now();
        final last = _lastToastAt[n.peerId];
        if (last != null && now.difference(last) < toastRateLimit) continue;
        _lastToastAt[n.peerId] = now;
        fired.add(n.peerId);
      } else {
        // Strong reading clears the consecutive counter immediately so a
        // future dip needs another two reports to trip again. We
        // intentionally leave the rate-limit watermark intact: a peer
        // that just tripped 30 s ago shouldn't be eligible to retrip
        // simply because its signal briefly recovered.
        _consecutiveWeak.remove(n.peerId);
      }
    }
    return fired;
  }

  /// Drop all detector state for [peerId]. Call when a peer leaves the
  /// room or is removed by the host so a re-join with the same `peerId`
  /// starts fresh — neither inheriting a stale weak-counter nor blocked
  /// by a leftover rate-limit watermark.
  void forgetPeer(String peerId) {
    _consecutiveWeak.remove(peerId);
    _lastToastAt.remove(peerId);
  }

  /// Drop all detector state for every neighbor. Call on `leaveRoom` so
  /// the next session starts with a clean slate.
  void clear() {
    _consecutiveWeak.clear();
    _lastToastAt.clear();
  }
}
