import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/services/audio_service.dart';
import 'package:walkie_talkie/services/voice_telemetry_monitor.dart';

LinkTelemetrySnapshot _snap({
  int recv = 0,
  int staleDrops = 0,
  int lagMs = 0,
  int depth = 3,
  int bps = 32000,
  int lastSeq = 0,
}) => LinkTelemetrySnapshot(
  underrunCount: 0,
  lateFrameCount: 0,
  lostFrameCount: 0,
  targetDepthFrames: 3,
  currentDepthFrames: depth,
  currentBitrateBps: bps,
  currentLagMs: lagMs,
  staleDropCount: staleDrops,
  recvCount: recv,
  lastSeq: lastSeq,
);

void main() {
  group('VoiceTelemetryMonitor', () {
    test('first sample seeds and returns null (nothing to delta)', () {
      final m = VoiceTelemetryMonitor();
      expect(m.add('g1', _snap(recv: 100), 1000), isNull);
      expect(m.points('g1'), isEmpty);
      expect(m.latest('g1'), isNull);
    });

    test('differences consecutive snapshots into rates', () {
      final m = VoiceTelemetryMonitor();
      m.add('g1', _snap(recv: 100, staleDrops: 0), 1000);
      // 1 s later: +50 frames, +10 stale drops.
      final p = m.add(
        'g1',
        _snap(recv: 150, staleDrops: 10, lagMs: 80, lastSeq: 4242),
        2000,
      );
      expect(p, isNotNull);
      expect(p!.throughputPerSec, 50.0); // 50 frames / 1 s
      expect(p.staleDropsPerSec, 10.0);
      expect(p.lagMs, 80);
      expect(p.lastSeq, 4242);
      expect(p.tMs, 2000);
    });

    test('non-positive elapsed is ignored', () {
      final m = VoiceTelemetryMonitor();
      m.add('g1', _snap(recv: 100), 2000);
      expect(m.add('g1', _snap(recv: 150), 2000), isNull); // same timestamp
      expect(m.add('g1', _snap(recv: 150), 1500), isNull); // clock went back
    });

    test('counter reset clamps deltas to zero (no negative spike)', () {
      final m = VoiceTelemetryMonitor();
      m.add('g1', _snap(recv: 1000, staleDrops: 50), 1000);
      // Native reset: counters drop back toward zero.
      final p = m.add('g1', _snap(recv: 5, staleDrops: 0), 2000);
      expect(p!.throughputPerSec, 0.0);
      expect(p.staleDropsPerSec, 0.0);
    });

    test('evicts points older than the window', () {
      final m = VoiceTelemetryMonitor(window: const Duration(seconds: 10));
      m.add('g1', _snap(recv: 0), 0);
      m.add('g1', _snap(recv: 50), 1000); // point at t=1000
      m.add('g1', _snap(recv: 100), 2000); // point at t=2000
      expect(m.points('g1').length, 2);
      // Jump well past the window: the t=1000/2000 points fall outside.
      m.add('g1', _snap(recv: 150), 13000); // point at t=13000
      final pts = m.points('g1');
      expect(pts.length, 1);
      expect(pts.single.tMs, 13000);
    });

    test('avgLagMs averages the retained window', () {
      final m = VoiceTelemetryMonitor();
      m.add('g1', _snap(recv: 0), 0);
      m.add('g1', _snap(recv: 50, lagMs: 100), 1000);
      m.add('g1', _snap(recv: 100, lagMs: 200), 2000);
      expect(m.avgLagMs('g1'), 150.0);
      expect(m.avgLagMs('unseen'), isNull);
    });

    test('exportJson is valid, self-describing, and round-trips', () {
      final m = VoiceTelemetryMonitor();
      m.add('g1', _snap(recv: 0), 0);
      m.add('g1', _snap(recv: 50, lagMs: 80, staleDrops: 2), 1000);
      final json = m.exportJson(exportedAtMs: 9999);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['exportedAtMs'], 9999);
      expect(decoded['windowMs'], 60000);
      final peers = decoded['peers'] as Map<String, dynamic>;
      final g1 = peers['g1'] as List<dynamic>;
      expect(g1.length, 1);
      expect((g1.single as Map<String, dynamic>)['lagMs'], 80);
      expect((g1.single)['throughputPerSec'], 50.0);
    });

    test('forgetPeer and clear drop history', () {
      final m = VoiceTelemetryMonitor();
      m.add('g1', _snap(recv: 0), 0);
      m.add('g1', _snap(recv: 50), 1000);
      m.add('g2', _snap(recv: 0), 0);
      m.add('g2', _snap(recv: 50), 1000);
      m.forgetPeer('g1');
      expect(m.points('g1'), isEmpty);
      expect(m.points('g2'), isNotEmpty);
      // A re-fed g1 seeds fresh (first sample null again).
      expect(m.add('g1', _snap(recv: 0), 2000), isNull);
      m.clear();
      expect(m.peers, isEmpty);
    });
  });
}
