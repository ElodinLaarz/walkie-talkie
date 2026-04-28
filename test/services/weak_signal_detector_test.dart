import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/services/weak_signal_detector.dart';

SignalReport _report({
  required String reporter,
  required int seq,
  int atMs = 0,
  required List<NeighborSignal> neighbors,
}) =>
    SignalReport(
      peerId: reporter,
      seq: seq,
      atMs: atMs,
      neighbors: neighbors,
    );

NeighborSignal _n(String peerId, int rssi) =>
    NeighborSignal(peerId: peerId, rssi: rssi);

void main() {
  group('WeakSignalDetector constants', () {
    test('match the protocol: -80 dBm, 2 reports, 60 s rate-limit', () {
      // These constants are load-bearing. They're the only thing that
      // maps the spec's "weak signal" to a number; bumping any of them
      // changes the user-visible cadence of weak-signal toasts.
      expect(WeakSignalDetector.weakThresholdDbm, -80);
      expect(WeakSignalDetector.consecutiveReportsToTrip, 2);
      expect(WeakSignalDetector.toastRateLimit, const Duration(seconds: 60));
    });
  });

  group('WeakSignalDetector.onReport — threshold gate', () {
    test('one weak report does not trip', () {
      final d = WeakSignalDetector();
      final fired = d.onReport(_report(
        reporter: 'g1',
        seq: 1,
        neighbors: [_n('peer-a', -85)],
      ));
      expect(fired, isEmpty);
    });

    test('two consecutive weak reports trip', () {
      final d = WeakSignalDetector();
      d.onReport(_report(reporter: 'g1', seq: 1, neighbors: [_n('a', -85)]));
      final fired = d.onReport(_report(
        reporter: 'g1',
        seq: 2,
        neighbors: [_n('a', -90)],
      ));
      expect(fired, ['a']);
    });

    test('boundary: -80 is NOT weak (strict less-than)', () {
      // The spec says "RSSI < -80 dBm" — the boundary value -80 itself
      // is treated as adequate, not weak. Pinning the test against this
      // guards against a "≤" off-by-one slipping in.
      final d = WeakSignalDetector();
      d.onReport(_report(reporter: 'g1', seq: 1, neighbors: [_n('a', -80)]));
      final fired = d.onReport(_report(
        reporter: 'g1',
        seq: 2,
        neighbors: [_n('a', -80)],
      ));
      expect(fired, isEmpty);
    });

    test('boundary: -81 IS weak', () {
      final d = WeakSignalDetector();
      d.onReport(_report(reporter: 'g1', seq: 1, neighbors: [_n('a', -81)]));
      final fired = d.onReport(_report(
        reporter: 'g1',
        seq: 2,
        neighbors: [_n('a', -81)],
      ));
      expect(fired, ['a']);
    });

    test('a strong report between two weak reports resets the counter', () {
      final d = WeakSignalDetector();
      d.onReport(_report(reporter: 'g1', seq: 1, neighbors: [_n('a', -85)]));
      d.onReport(_report(reporter: 'g1', seq: 2, neighbors: [_n('a', -50)]));
      final fired = d.onReport(_report(
        reporter: 'g1',
        seq: 3,
        neighbors: [_n('a', -85)],
      ));
      // Counter reset on the strong reading; only one weak in a row again.
      expect(fired, isEmpty);
    });

    test('absent neighbor does NOT reset the counter', () {
      // A reporter that didn't see neighbor X this round is silence,
      // not a positive "X is fine now" signal. The next weak report
      // for X should still trip if the prior one was weak.
      final d = WeakSignalDetector();
      d.onReport(_report(reporter: 'g1', seq: 1, neighbors: [_n('a', -85)]));
      d.onReport(_report(reporter: 'g1', seq: 2, neighbors: const []));
      final fired = d.onReport(_report(
        reporter: 'g1',
        seq: 3,
        neighbors: [_n('a', -85)],
      ));
      expect(fired, ['a']);
    });

    test('per-neighbor independence on the same report', () {
      final d = WeakSignalDetector();
      d.onReport(_report(
        reporter: 'g1',
        seq: 1,
        neighbors: [_n('a', -85), _n('b', -85)],
      ));
      final fired = d.onReport(_report(
        reporter: 'g1',
        seq: 2,
        neighbors: [_n('a', -85), _n('b', -85)],
      ));
      expect(fired, unorderedEquals(['a', 'b']));
    });

    test('per-neighbor independence: one trips, one stays strong', () {
      final d = WeakSignalDetector();
      d.onReport(_report(
        reporter: 'g1',
        seq: 1,
        neighbors: [_n('a', -85), _n('b', -50)],
      ));
      final fired = d.onReport(_report(
        reporter: 'g1',
        seq: 2,
        neighbors: [_n('a', -85), _n('b', -50)],
      ));
      expect(fired, ['a']);
    });
  });

  group('WeakSignalDetector.onReport — rate-limit gate', () {
    test('second trip within 60 s is suppressed', () {
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final d = WeakSignalDetector(clock: () => fakeNow);

      d.onReport(_report(reporter: 'g1', seq: 1, neighbors: [_n('a', -85)]));
      var fired = d.onReport(_report(
        reporter: 'g1',
        seq: 2,
        neighbors: [_n('a', -85)],
      ));
      expect(fired, ['a']);

      fakeNow = fakeNow.add(const Duration(seconds: 30));
      // Two more weak reports — would trip again if not for the rate-limit.
      d.onReport(_report(reporter: 'g1', seq: 3, neighbors: [_n('a', -85)]));
      fired = d.onReport(_report(
        reporter: 'g1',
        seq: 4,
        neighbors: [_n('a', -85)],
      ));
      expect(fired, isEmpty,
          reason: '30 s < 60 s rate-limit window');
    });

    test('trip again after 60 s elapses', () {
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final d = WeakSignalDetector(clock: () => fakeNow);

      // First trip at T0.
      d.onReport(_report(reporter: 'g1', seq: 1, neighbors: [_n('a', -85)]));
      d.onReport(_report(reporter: 'g1', seq: 2, neighbors: [_n('a', -85)]));

      // Counter is now ≥ 2, so any further weak report would trip *if*
      // the rate-limit allows it. Advance to exactly the rate-limit
      // boundary: a single report at T0 + 60s should fire because the
      // gate is `<` (strict), so 60s ≥ 60s passes.
      fakeNow = fakeNow.add(const Duration(seconds: 60));
      final fired = d.onReport(_report(
        reporter: 'g1',
        seq: 3,
        neighbors: [_n('a', -85)],
      ));
      expect(fired, ['a'],
          reason: '60 s ≥ 60 s rate-limit window (inclusive)');
    });

    test('within 30 s after a trip, further weak reports are suppressed', () {
      // Companion to the boundary test: explicitly verifies the strict-`<`
      // path on the inside of the window. Two consecutive trips spanning
      // the cooldown should produce one fire, not three.
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final d = WeakSignalDetector(clock: () => fakeNow);

      d.onReport(_report(reporter: 'g1', seq: 1, neighbors: [_n('a', -85)]));
      var fired =
          d.onReport(_report(reporter: 'g1', seq: 2, neighbors: [_n('a', -85)]));
      expect(fired, ['a']);

      fakeNow = fakeNow.add(const Duration(seconds: 30));
      fired =
          d.onReport(_report(reporter: 'g1', seq: 3, neighbors: [_n('a', -85)]));
      expect(fired, isEmpty);

      fakeNow = fakeNow.add(const Duration(seconds: 29));
      fired =
          d.onReport(_report(reporter: 'g1', seq: 4, neighbors: [_n('a', -85)]));
      expect(fired, isEmpty,
          reason: 'still inside the 60 s window (59 s elapsed)');
    });

    test('rate-limit is per-neighbor', () {
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final d = WeakSignalDetector(clock: () => fakeNow);

      // Trip 'a' first.
      d.onReport(_report(reporter: 'g1', seq: 1, neighbors: [_n('a', -85)]));
      d.onReport(_report(reporter: 'g1', seq: 2, neighbors: [_n('a', -85)]));

      // 'b' starts weak shortly after — its rate-limit watermark is
      // independent and should trip on its own two consecutive reports
      // even though 'a' is still inside its 60 s window.
      fakeNow = fakeNow.add(const Duration(seconds: 5));
      d.onReport(_report(reporter: 'g1', seq: 3, neighbors: [_n('b', -85)]));
      final fired = d.onReport(_report(
        reporter: 'g1',
        seq: 4,
        neighbors: [_n('b', -85)],
      ));
      expect(fired, ['b']);
    });
  });

  group('WeakSignalDetector.forgetPeer / clear', () {
    test('forgetPeer wipes the consecutive counter', () {
      final d = WeakSignalDetector();
      d.onReport(_report(reporter: 'g1', seq: 1, neighbors: [_n('a', -85)]));
      d.forgetPeer('a');
      // Without forget, the next weak would trip. After forget, we need
      // two more consecutive weak reports.
      var fired =
          d.onReport(_report(reporter: 'g1', seq: 2, neighbors: [_n('a', -85)]));
      expect(fired, isEmpty);
      fired =
          d.onReport(_report(reporter: 'g1', seq: 3, neighbors: [_n('a', -85)]));
      expect(fired, ['a']);
    });

    test('forgetPeer clears the rate-limit watermark', () {
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final d = WeakSignalDetector(clock: () => fakeNow);
      d.onReport(_report(reporter: 'g1', seq: 1, neighbors: [_n('a', -85)]));
      d.onReport(_report(reporter: 'g1', seq: 2, neighbors: [_n('a', -85)]));
      // 'a' is now under its 60s rate-limit. Forget + re-trip should
      // succeed immediately rather than waiting out the cooldown.
      d.forgetPeer('a');
      d.onReport(_report(reporter: 'g1', seq: 3, neighbors: [_n('a', -85)]));
      final fired = d.onReport(_report(
        reporter: 'g1',
        seq: 4,
        neighbors: [_n('a', -85)],
      ));
      expect(fired, ['a']);
    });

    test('clear wipes every neighbor', () {
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final d = WeakSignalDetector(clock: () => fakeNow);
      d.onReport(_report(
        reporter: 'g1',
        seq: 1,
        neighbors: [_n('a', -85), _n('b', -85)],
      ));
      d.onReport(_report(
        reporter: 'g1',
        seq: 2,
        neighbors: [_n('a', -85), _n('b', -85)],
      ));
      d.clear();
      var fired = d.onReport(_report(
        reporter: 'g1',
        seq: 3,
        neighbors: [_n('a', -85), _n('b', -85)],
      ));
      expect(fired, isEmpty, reason: 'counters reset by clear');
      fired = d.onReport(_report(
        reporter: 'g1',
        seq: 4,
        neighbors: [_n('a', -85), _n('b', -85)],
      ));
      expect(fired, unorderedEquals(['a', 'b']));
    });
  });
}
