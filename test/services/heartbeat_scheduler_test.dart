import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/services/heartbeat_scheduler.dart';

void main() {
  group('HeartbeatScheduler defaults', () {
    test('defaults match the protocol: 5s interval, 15s miss threshold', () {
      // The constants are load-bearing — they're how three "missed pings"
      // gets resolved. If anyone retunes one without the other, the
      // check-on-tick logic stops mapping cleanly to the protocol's
      // "after 3 missed pings (~15s)" rule.
      expect(HeartbeatScheduler.defaultPingInterval,
          const Duration(seconds: 5));
      expect(HeartbeatScheduler.defaultMissThreshold,
          const Duration(seconds: 15));
    });

    test('rejects a non-positive pingInterval', () {
      expect(
        () => HeartbeatScheduler(pingInterval: Duration.zero),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects a non-positive missThreshold', () {
      expect(
        () => HeartbeatScheduler(missThreshold: Duration.zero),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('HeartbeatScheduler.start / stop', () {
    test('start fires onTick periodically and stop cancels the timer',
        () async {
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(milliseconds: 10),
        missThreshold: const Duration(seconds: 60),
      );

      var ticks = 0;
      scheduler.start(
        onTick: () => ticks++,
        onPeerLost: (_) => fail('no peers tracked, none should be lost'),
      );

      // Wait long enough to observe ≥ 2 ticks but bound the upper end so
      // the test doesn't depend on millisecond-level timer accuracy.
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(ticks, greaterThanOrEqualTo(2));

      scheduler.stop();
      final ticksAtStop = ticks;
      // After stop, no further ticks should arrive.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ticks, ticksAtStop);
    });

    test('isRunning toggles on start / stop', () {
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(seconds: 1),
      );
      expect(scheduler.isRunning, isFalse);
      scheduler.start(onTick: () {}, onPeerLost: (_) {});
      expect(scheduler.isRunning, isTrue);
      scheduler.stop();
      expect(scheduler.isRunning, isFalse);
    });

    test('start while running cancels the previous timer and clears state',
        () async {
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(milliseconds: 10),
        missThreshold: const Duration(seconds: 60),
      );

      var ticks1 = 0;
      scheduler.start(
        onTick: () => ticks1++,
        onPeerLost: (_) {},
      );
      scheduler.notePingFrom('peer-a');
      expect(scheduler.lastSeen, contains('peer-a'));

      // Re-start with a fresh callback. The first counter must stop
      // incrementing, and the watermarks must be wiped.
      var ticks2 = 0;
      scheduler.start(
        onTick: () => ticks2++,
        onPeerLost: (_) {},
      );
      expect(scheduler.lastSeen, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 35));
      // Only ticks2 should still be advancing — ticks1's timer was cancelled.
      // We can't pin exact counts, but ticks1 must not have been advanced
      // *after* the second start.
      final ticks1AtStart = ticks1;
      scheduler.stop();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ticks1, ticks1AtStart);
      expect(ticks2, greaterThan(0));
    });

    test('stop is safe when never started', () {
      final scheduler = HeartbeatScheduler();
      expect(scheduler.stop, returnsNormally);
    });

    test('stop is idempotent', () {
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(seconds: 1),
      );
      scheduler.start(onTick: () {}, onPeerLost: (_) {});
      scheduler.stop();
      expect(scheduler.stop, returnsNormally);
    });
  });

  group('HeartbeatScheduler peer-lost detection', () {
    test('does NOT fire onPeerLost for a peer who never pinged', () {
      // Spec: a peer is only tracked once the first ping arrives. A peer
      // that has never pinged shouldn't surface as "lost" — that failure
      // mode (silent join) belongs to a different layer.
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(seconds: 60),
        missThreshold: const Duration(milliseconds: 1),
      );
      final lost = <String>[];
      scheduler.start(
        onTick: () {},
        onPeerLost: lost.add,
      );

      scheduler.debugTick();
      expect(lost, isEmpty);
      scheduler.stop();
    });

    test('fires onPeerLost when missThreshold elapses since last ping', () {
      // Drive a fake clock so the test is deterministic under
      // millisecond-jitter.
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(seconds: 60),
        missThreshold: const Duration(seconds: 15),
        clock: () => fakeNow,
      );
      final lost = <String>[];
      scheduler.start(onTick: () {}, onPeerLost: lost.add);

      scheduler.notePingFrom('peer-a');
      scheduler.notePingFrom('peer-b');

      // Tick at +10s — within threshold for both.
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      scheduler.debugTick();
      expect(lost, isEmpty);

      // Tick at +16s — past threshold for both (last ping was at 0s).
      fakeNow = fakeNow.add(const Duration(seconds: 6));
      scheduler.debugTick();
      expect(lost, unorderedEquals(['peer-a', 'peer-b']));
      // Both watermarks were dropped; a re-tick shouldn't refire.
      lost.clear();
      scheduler.debugTick();
      expect(lost, isEmpty);

      scheduler.stop();
    });

    test('a fresh ping resets the silence clock', () {
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(seconds: 60),
        missThreshold: const Duration(seconds: 15),
        clock: () => fakeNow,
      );
      final lost = <String>[];
      scheduler.start(onTick: () {}, onPeerLost: lost.add);

      scheduler.notePingFrom('peer-a');

      fakeNow = fakeNow.add(const Duration(seconds: 14));
      scheduler.notePingFrom('peer-a'); // refresh watermark just in time

      fakeNow = fakeNow.add(const Duration(seconds: 14));
      scheduler.debugTick();
      // 14s since the *latest* ping → still within threshold.
      expect(lost, isEmpty);

      fakeNow = fakeNow.add(const Duration(seconds: 2));
      scheduler.debugTick();
      // Now 16s since the latest ping — declared lost.
      expect(lost, ['peer-a']);

      scheduler.stop();
    });

    test('forgetPeer drops a watermark without firing onPeerLost', () {
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(seconds: 60),
        missThreshold: const Duration(seconds: 15),
        clock: () => fakeNow,
      );
      final lost = <String>[];
      scheduler.start(onTick: () {}, onPeerLost: lost.add);

      scheduler.notePingFrom('peer-a');
      scheduler.forgetPeer('peer-a');

      fakeNow = fakeNow.add(const Duration(seconds: 30));
      scheduler.debugTick();

      // peer-a was forgotten cleanly — no spurious "lost" callback.
      expect(lost, isEmpty);
      scheduler.stop();
    });

    test('per-peer independence: one stale, one fresh', () {
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(seconds: 60),
        missThreshold: const Duration(seconds: 15),
        clock: () => fakeNow,
      );
      final lost = <String>[];
      scheduler.start(onTick: () {}, onPeerLost: lost.add);

      scheduler.notePingFrom('peer-stale');

      fakeNow = fakeNow.add(const Duration(seconds: 14));
      scheduler.notePingFrom('peer-fresh');

      fakeNow = fakeNow.add(const Duration(seconds: 5));
      scheduler.debugTick();
      // peer-stale: 19s since last ping → lost.
      // peer-fresh: 5s since last ping → still alive.
      expect(lost, ['peer-stale']);
      expect(scheduler.lastSeen.keys, ['peer-fresh']);

      scheduler.stop();
    });
  });

  group('HeartbeatScheduler.debugTick → onTick ordering', () {
    test('onTick fires once per tick before onPeerLost dispatch', () {
      // The cubit relies on this order: send our outbound ping first
      // (so guests/host hear from us before they declare us lost on
      // their side), then evaluate inbound silence on ours.
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final order = <String>[];
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(seconds: 60),
        missThreshold: const Duration(milliseconds: 1),
        clock: () => fakeNow,
      );

      scheduler.start(
        onTick: () => order.add('tick'),
        onPeerLost: (id) => order.add('lost:$id'),
      );

      scheduler.notePingFrom('peer-a');
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      scheduler.debugTick();

      expect(order, ['tick', 'lost:peer-a']);
      scheduler.stop();
    });
  });
}
