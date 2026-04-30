import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/services/bitrate_adapter.dart';

LinkQuality _lq({
  required String peerId,
  required int atMs,
  required double lossPct,
  int jitterMs = 60,
  double underrunsPerSec = 0.0,
}) =>
    LinkQuality(
      peerId: peerId,
      seq: 1,
      atMs: atMs,
      lossPct: lossPct,
      jitterMs: jitterMs,
      underrunsPerSec: underrunsPerSec,
    );

/// Test shorthand — the adapter takes a separate `nowMs` (host-local
/// receipt clock); these tests were written before that split, and the
/// existing scenarios match the case where the host clock advances in
/// lockstep with the sender's `atMs`. Pinning `nowMs == sample.atMs`
/// preserves the original semantics; clock-drift scenarios get their
/// own `feedAt` calls below.
BitrateLevel? _feed(BitrateAdapter a, LinkQuality sample) =>
    a.feed(sample, nowMs: sample.atMs);

void main() {
  group('BitrateLevel', () {
    test('bps values match audio_config.h operating points', () {
      // These three are the only values native PeerAudioManager will
      // honour after clamping. The Dart adapter must agree with the
      // native enum so a `BitrateHint(bps: 16000)` lands as Mid and not
      // as a "snap to nearest" surprise.
      expect(BitrateLevel.low.bps, 8000);
      expect(BitrateLevel.mid.bps, 16000);
      expect(BitrateLevel.high.bps, 24000);
    });

    test('nearest snaps to the closest operating point, ties favour lower',
        () {
      expect(BitrateLevel.nearest(8000), BitrateLevel.low);
      expect(BitrateLevel.nearest(16000), BitrateLevel.mid);
      expect(BitrateLevel.nearest(24000), BitrateLevel.high);
      // 12000 is equidistant from low (8000) and mid (16000) — the
      // tie-break docstring says "favour the lower level."
      expect(BitrateLevel.nearest(12000), BitrateLevel.low);
      // 11000 is closer to low; 14000 closer to mid.
      expect(BitrateLevel.nearest(11000), BitrateLevel.low);
      expect(BitrateLevel.nearest(14000), BitrateLevel.mid);
    });
  });

  group('BitrateAdapter thresholds', () {
    test('protocol-pinned threshold constants', () {
      // These are wire-protocol load-bearing; bumping them changes how
      // quickly the encoder reacts to a degrading link.
      expect(BitrateAdapter.dropToLowLossPct, 12.0);
      expect(BitrateAdapter.dropToMidLossPct, 5.0);
      expect(BitrateAdapter.cleanLossPct, 1.0);
      expect(BitrateAdapter.cleanUnderrunsPerSec, 0.1);
      expect(BitrateAdapter.downHoldMid, const Duration(seconds: 4));
      expect(BitrateAdapter.upHold, const Duration(seconds: 30));
    });
  });

  group('BitrateAdapter downstep behaviour', () {
    test('one bad sample does not trip — dwell is required', () {
      final a = BitrateAdapter();
      final out = _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 20.0));
      expect(out, isNull);
      expect(a.levelFor('g1'), BitrateLevel.mid,
          reason: 'default seed is Mid');
    });

    test('>12 % sustained for 4 s steps from default Mid all the way to Low',
        () {
      final a = BitrateAdapter();
      // Two consecutive bad samples — the second must be ≥ 4 s after the
      // first to trip. Sample-count alone is not the criterion; wall-time
      // dwell is.
      final first = _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 20.0));
      expect(first, isNull, reason: 'first bad sample seeds dwell');
      final second = _feed(a, _lq(peerId: 'g1', atMs: 4000, lossPct: 20.0));
      expect(second, BitrateLevel.low);
      expect(a.levelFor('g1'), BitrateLevel.low);
    });

    test(
        '>12 % at exactly 3.999 s does not trip; one more ms over the boundary does',
        () {
      final a = BitrateAdapter();
      _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 20.0));
      expect(_feed(a, _lq(peerId: 'g1', atMs: 3999, lossPct: 20.0)), isNull);
      expect(
        _feed(a, _lq(peerId: 'g1', atMs: 4000, lossPct: 20.0)),
        BitrateLevel.low,
      );
    });

    test('>5 % (but ≤12 %) sustained 4 s drops only one notch from High', () {
      final a = BitrateAdapter();
      a.seed('g1', BitrateLevel.high);
      // 7 % is in the >5 % but ≤12 % band.
      _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 7.0));
      final out = _feed(a, _lq(peerId: 'g1', atMs: 4000, lossPct: 7.0));
      expect(out, BitrateLevel.mid);
      expect(a.levelFor('g1'), BitrateLevel.mid);
    });

    test('>5 % from Mid does not push deeper to Low', () {
      // The 5 % rule covers "merely choppy" — only the >12 % rule should
      // be allowed to push past Mid down to Low.
      final a = BitrateAdapter();
      a.seed('g1', BitrateLevel.mid);
      _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 7.0));
      final out = _feed(a, _lq(peerId: 'g1', atMs: 4000, lossPct: 7.0));
      expect(out, isNull);
      expect(a.levelFor('g1'), BitrateLevel.mid);
    });

    test('a clean sample interrupting bad dwell resets the timer', () {
      final a = BitrateAdapter();
      _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 20.0));
      // 2 s in, the link briefly clears — pending dwell resets.
      _feed(a, _lq(peerId: 'g1', atMs: 2000, lossPct: 0.5));
      // Another bad sample at 4 s wall-time — but only 2 s of *contiguous*
      // bad dwell, so no trip yet.
      final stillNo = _feed(a, _lq(peerId: 'g1', atMs: 4000, lossPct: 20.0));
      expect(stillNo, isNull);
      // The full 4 s must elapse from the *last* bad sample.
      final trip = _feed(a, _lq(peerId: 'g1', atMs: 8000, lossPct: 20.0));
      expect(trip, BitrateLevel.low);
    });

    test('contiguous bad samples in different bands restart dwell', () {
      // Switching from "wants down to mid" to "wants down to low" is a
      // direction change — pending dwell resets to the new direction.
      final a = BitrateAdapter();
      a.seed('g1', BitrateLevel.high);
      _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 7.0));   // wantsDownMid
      _feed(a, _lq(peerId: 'g1', atMs: 1000, lossPct: 20.0)); // wantsDownLow
      // Only 3 s of "down to low" dwell so far — no trip yet.
      expect(
        _feed(a, _lq(peerId: 'g1', atMs: 4000, lossPct: 20.0)),
        isNull,
      );
      // 4 s + 1 ms of contiguous "down to low" dwell from atMs=1000 → trips.
      final trip = _feed(a, _lq(peerId: 'g1', atMs: 5001, lossPct: 20.0));
      expect(trip, BitrateLevel.low);
    });
  });

  group('BitrateAdapter upstep behaviour', () {
    test('clean link from Low climbs Low → Mid after 30 s, then Mid → High',
        () {
      final a = BitrateAdapter();
      a.seed('g1', BitrateLevel.low);
      // First clean sample seeds the dwell.
      expect(_feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 0.0)), isNull);
      // 29 s in — not yet 30 s.
      expect(
        _feed(a, _lq(peerId: 'g1', atMs: 29000, lossPct: 0.0)),
        isNull,
      );
      // 30 s — first upstep.
      expect(
        _feed(a, _lq(peerId: 'g1', atMs: 30000, lossPct: 0.0)),
        BitrateLevel.mid,
      );
      // After a step, dwell resets — another 30 s of clean to step again.
      expect(
        _feed(a, _lq(peerId: 'g1', atMs: 59000, lossPct: 0.0)),
        isNull,
      );
      expect(
        _feed(a, _lq(peerId: 'g1', atMs: 60001, lossPct: 0.0)),
        BitrateLevel.high,
      );
    });

    test('upstep blocked when underruns/sec exceeds the clean ceiling', () {
      // lossPct = 0, but underruns > 0.1 / s — not clean enough.
      final a = BitrateAdapter();
      a.seed('g1', BitrateLevel.mid);
      _feed(a, _lq(
        peerId: 'g1',
        atMs: 0,
        lossPct: 0.0,
        underrunsPerSec: 0.5,
      ));
      final out = _feed(a, _lq(
        peerId: 'g1',
        atMs: 60000,
        lossPct: 0.0,
        underrunsPerSec: 0.5,
      ));
      expect(out, isNull);
      expect(a.levelFor('g1'), BitrateLevel.mid);
    });

    test('upstep blocked when lossPct is in the dead zone (≥1 % but ≤5 %)',
        () {
      // 3 % is neither bad enough to trigger a downstep nor clean enough
      // to count toward the 30 s upstep dwell.
      final a = BitrateAdapter();
      a.seed('g1', BitrateLevel.mid);
      _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 3.0));
      final out = _feed(a, _lq(peerId: 'g1', atMs: 60000, lossPct: 3.0));
      expect(out, isNull);
      expect(a.levelFor('g1'), BitrateLevel.mid);
    });

    test('Already at High — upstep is a no-op even after a long clean run',
        () {
      final a = BitrateAdapter();
      a.seed('g1', BitrateLevel.high);
      _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 0.0));
      final out = _feed(a, _lq(peerId: 'g1', atMs: 30000, lossPct: 0.0));
      expect(out, isNull);
      expect(a.levelFor('g1'), BitrateLevel.high);
    });
  });

  group('Issue acceptance: thresholds → BitrateHint schedule', () {
    test(
        '24 → 16 → 24: bad uplink trips down to Mid, recovery climbs back to High',
        () {
      // Mirrors the two-device acceptance scenario in the issue:
      //  * Inject ~10 % loss → within 4 s the encoder shifts to 16 kbps.
      //  * Lift the drop → returns to 24 kbps within 30 s of clean samples.
      final a = BitrateAdapter();
      a.seed('g1', BitrateLevel.high);
      // 10 % is in the >5 % band — should drop one notch (not all the
      // way to low).
      _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 10.0));
      final downstep = _feed(a, _lq(peerId: 'g1', atMs: 4000, lossPct: 10.0));
      expect(downstep, BitrateLevel.mid);

      // Drop is lifted at atMs = 5000. 30 s of clean later, we step back
      // up. Need a sample to seed the upstep dwell (5000) and one to
      // confirm at 35001.
      _feed(a, _lq(peerId: 'g1', atMs: 5000, lossPct: 0.0));
      expect(_feed(a, _lq(peerId: 'g1', atMs: 35001, lossPct: 0.0)),
          BitrateLevel.high);
    });

    test('24 → 8 → 16 → 24: catastrophic loss bypasses Mid, then climbs back',
        () {
      // Heavy loss (>12 %) goes straight to Low. From Low, a 30 s clean
      // run climbs to Mid; another 30 s climbs to High.
      final a = BitrateAdapter();
      a.seed('g1', BitrateLevel.high);
      _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 25.0));
      expect(_feed(a, _lq(peerId: 'g1', atMs: 4000, lossPct: 25.0)),
          BitrateLevel.low);

      _feed(a, _lq(peerId: 'g1', atMs: 5000, lossPct: 0.0));
      expect(_feed(a, _lq(peerId: 'g1', atMs: 35000, lossPct: 0.0)),
          BitrateLevel.mid);
      expect(_feed(a, _lq(peerId: 'g1', atMs: 65000, lossPct: 0.0)),
          BitrateLevel.high);
    });
  });

  group('BitrateAdapter dwell vs. sender clock', () {
    // Regression guard: dwell must use the host-local `nowMs`, not the
    // sender's `sample.atMs`. A guest with a skewed (or hostile) clock
    // could otherwise jump the dwell window by stamping `atMs` 4 s into
    // the future on its very first bad sample — which is not how the
    // 4 s sustained-loss rule is supposed to work.
    test(
        'sender atMs jumping ahead does NOT short-circuit the 4 s downstep dwell',
        () {
      final a = BitrateAdapter();
      // Sample 1 at host-local nowMs=0; sample's atMs is 0 too.
      a.feed(
        _lq(peerId: 'g1', atMs: 0, lossPct: 20.0),
        nowMs: 0,
      );
      // Sample 2: sender claims atMs=10_000 (10 s in the future) but
      // host clock has only advanced 1 s. Dwell should follow the host
      // clock — no trip yet.
      final out = a.feed(
        _lq(peerId: 'g1', atMs: 10000, lossPct: 20.0),
        nowMs: 1000,
      );
      expect(out, isNull,
          reason: 'sender clock skew must not satisfy the 4 s dwell');
      // After the host clock has actually advanced 4 s, the trip fires.
      final trip = a.feed(
        _lq(peerId: 'g1', atMs: 11000, lossPct: 20.0),
        nowMs: 4000,
      );
      expect(trip, BitrateLevel.low);
    });

    test(
        'sender atMs lagging behind does NOT block a downstep that the host clock has earned',
        () {
      final a = BitrateAdapter();
      a.feed(
        _lq(peerId: 'g1', atMs: 100000, lossPct: 20.0),
        nowMs: 0,
      );
      // Sender claims atMs=100_000 (the past, vs. itself) — irrelevant.
      // Host has advanced 4 s since the seed; the trip should fire.
      final trip = a.feed(
        _lq(peerId: 'g1', atMs: 100100, lossPct: 20.0),
        nowMs: 4000,
      );
      expect(trip, BitrateLevel.low);
    });
  });

  group('BitrateAdapter per-peer isolation', () {
    test('two peers with independent state machines', () {
      final a = BitrateAdapter();
      // g1 is going down; g2 is going up.
      a.seed('g1', BitrateLevel.high);
      a.seed('g2', BitrateLevel.low);
      _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 25.0));
      _feed(a, _lq(peerId: 'g2', atMs: 0, lossPct: 0.0));
      // 4 s later — g1 trips down, g2 not yet.
      expect(_feed(a, _lq(peerId: 'g1', atMs: 4000, lossPct: 25.0)),
          BitrateLevel.low);
      expect(_feed(a, _lq(peerId: 'g2', atMs: 4000, lossPct: 0.0)), isNull);
      // 30 s — g2 finally trips up.
      expect(_feed(a, _lq(peerId: 'g2', atMs: 30000, lossPct: 0.0)),
          BitrateLevel.mid);
      // g1 stayed at low through this — g2's clean samples didn't help it.
      expect(a.levelFor('g1'), BitrateLevel.low);
    });

    test('forgetPeer drops state for that peer only', () {
      final a = BitrateAdapter();
      a.seed('g1', BitrateLevel.high);
      a.seed('g2', BitrateLevel.low);
      a.forgetPeer('g1');
      expect(a.levelFor('g1'), isNull);
      expect(a.levelFor('g2'), BitrateLevel.low);
    });

    test('clear drops state for every peer', () {
      final a = BitrateAdapter();
      a.seed('g1', BitrateLevel.high);
      a.seed('g2', BitrateLevel.mid);
      a.clear();
      expect(a.levelFor('g1'), isNull);
      expect(a.levelFor('g2'), isNull);
    });

    test(
        'unseen peer auto-seeds at Mid on first feed, retains state across feeds',
        () {
      final a = BitrateAdapter();
      _feed(a, _lq(peerId: 'g1', atMs: 0, lossPct: 0.0));
      expect(a.levelFor('g1'), BitrateLevel.mid);
    });
  });
}
