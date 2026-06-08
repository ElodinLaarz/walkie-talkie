import 'dart:convert';

import 'audio_service.dart';

/// One derived telemetry data point for the voice debug dashboard, computed
/// from two consecutive [LinkTelemetrySnapshot]s for a peer.
///
/// The native counters are lifetime totals; this turns the per-snapshot deltas
/// into the rates a human watching a live link wants to see, plus the
/// instantaneous gauges (lag, depth, bitrate, head-of-stream seq).
class VoiceTelemetryPoint {
  /// Local wall-clock (ms since epoch) when this point was sampled.
  final int tMs;

  /// Frames accepted per second (`recvCount` delta / elapsed) — should sit
  /// near 50/s on a healthy 20 ms link.
  final double throughputPerSec;

  /// Frames dropped per second as too stale (`staleDropCount` delta / elapsed).
  /// A non-zero value means we're actively shedding backlog to stay current.
  final double staleDropsPerSec;

  /// Instantaneous end-to-end staleness estimate (ms) — the lag the listener
  /// feels (native `PlayoutLagEstimator` excess).
  final int lagMs;

  /// Jitter-buffer fill at sample time, in 20 ms frames.
  final int depthFrames;

  /// Encoder bitrate toward this peer at sample time (bps).
  final int bitrateBps;

  /// Most recently accepted sequence number (live head-of-stream).
  final int lastSeq;

  const VoiceTelemetryPoint({
    required this.tMs,
    required this.throughputPerSec,
    required this.staleDropsPerSec,
    required this.lagMs,
    required this.depthFrames,
    required this.bitrateBps,
    required this.lastSeq,
  });

  Map<String, dynamic> toJson() => {
    'tMs': tMs,
    'throughputPerSec': throughputPerSec,
    'staleDropsPerSec': staleDropsPerSec,
    'lagMs': lagMs,
    'depthFrames': depthFrames,
    'bitrateBps': bitrateBps,
    'lastSeq': lastSeq,
  };
}

/// Rolling per-peer telemetry buffer that backs the in-app voice debug
/// dashboard and its "export last minute" button.
///
/// Feed it raw [LinkTelemetrySnapshot]s (polled from [AudioService]) via [add];
/// it differences consecutive snapshots into [VoiceTelemetryPoint]s and retains
/// the last [window] of them per peer. The dashboard renders [points] (e.g. a
/// staleness sparkline) and the live aggregates; [exportJson] serialises the
/// whole retained window to a string the user can write to a file and re-upload
/// for offline debugging.
///
/// Pure logic — no timers, no platform calls — so it unit-tests deterministically
/// with injected `nowMs` values. The caller owns the polling cadence.
class VoiceTelemetryMonitor {
  VoiceTelemetryMonitor({this.window = const Duration(seconds: 60)});

  /// How far back [points] / [exportJson] retain history.
  final Duration window;

  final Map<String, List<VoiceTelemetryPoint>> _points = {};
  final Map<String, LinkTelemetrySnapshot> _prev = {};
  final Map<String, int> _prevAtMs = {};

  /// Difference [snap] against the previous snapshot for [peerId] and append a
  /// derived point. Returns the new point, or `null` on the first sample for a
  /// peer (nothing to delta against yet) or a non-positive elapsed interval.
  VoiceTelemetryPoint? add(
    String peerId,
    LinkTelemetrySnapshot snap,
    int nowMs,
  ) {
    final prev = _prev[peerId];
    final prevAt = _prevAtMs[peerId];
    _prev[peerId] = snap;
    _prevAtMs[peerId] = nowMs;
    if (prev == null || prevAt == null) return null;

    final elapsedMs = nowMs - prevAt;
    if (elapsedMs <= 0) return null;
    final elapsedSec = elapsedMs / 1000.0;

    // Lifetime counters: clamp deltas at 0 so a native-side reset (peer
    // re-register zeroes recvCount/staleDropCount) reads as "no traffic this
    // interval" rather than a negative spike.
    final recvDelta = (snap.recvCount - prev.recvCount).clamp(0, 1 << 31);
    final staleDelta = (snap.staleDropCount - prev.staleDropCount).clamp(
      0,
      1 << 31,
    );

    final point = VoiceTelemetryPoint(
      tMs: nowMs,
      throughputPerSec: recvDelta / elapsedSec,
      staleDropsPerSec: staleDelta / elapsedSec,
      lagMs: snap.currentLagMs,
      depthFrames: snap.currentDepthFrames,
      bitrateBps: snap.currentBitrateBps,
      lastSeq: snap.lastSeq,
    );

    final list = _points.putIfAbsent(peerId, () => <VoiceTelemetryPoint>[]);
    list.add(point);
    _evict(list, nowMs);
    return point;
  }

  void _evict(List<VoiceTelemetryPoint> list, int nowMs) {
    final cutoff = nowMs - window.inMilliseconds;
    // Points are appended in time order, so drop from the front.
    var drop = 0;
    while (drop < list.length && list[drop].tMs < cutoff) {
      drop++;
    }
    if (drop > 0) list.removeRange(0, drop);
  }

  /// The retained window of points for [peerId], oldest first. Empty if unseen.
  List<VoiceTelemetryPoint> points(String peerId) =>
      List.unmodifiable(_points[peerId] ?? const []);

  /// Peers with at least one retained point.
  Iterable<String> get peers => _points.keys;

  /// Mean lag (ms) over the retained window for [peerId], or null if empty.
  double? avgLagMs(String peerId) {
    final list = _points[peerId];
    if (list == null || list.isEmpty) return null;
    final sum = list.fold<int>(0, (a, p) => a + p.lagMs);
    return sum / list.length;
  }

  /// Most recent point for [peerId], or null if unseen.
  VoiceTelemetryPoint? latest(String peerId) {
    final list = _points[peerId];
    return (list == null || list.isEmpty) ? null : list.last;
  }

  /// Serialise the full retained window (all peers) to a JSON string suitable
  /// for writing to a file and re-uploading. Stable, self-describing shape:
  /// `{ "exportedAtMs", "windowMs", "peers": { "<id>": [ point, ... ] } }`.
  String exportJson({int? exportedAtMs}) {
    final peersJson = <String, dynamic>{};
    for (final entry in _points.entries) {
      peersJson[entry.key] = entry.value.map((p) => p.toJson()).toList();
    }
    return const JsonEncoder.withIndent('  ').convert({
      'exportedAtMs': exportedAtMs ?? DateTime.now().millisecondsSinceEpoch,
      'windowMs': window.inMilliseconds,
      'peers': peersJson,
    });
  }

  /// Forget a peer's history (e.g. on leave / re-register).
  void forgetPeer(String peerId) {
    _points.remove(peerId);
    _prev.remove(peerId);
    _prevAtMs.remove(peerId);
  }

  void clear() {
    _points.clear();
    _prev.clear();
    _prevAtMs.clear();
  }
}
