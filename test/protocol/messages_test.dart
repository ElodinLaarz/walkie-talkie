import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/protocol/peer.dart';

T _roundTrip<T extends FrequencyMessage>(T msg) {
  final wire = msg.encode();
  // Sanity: the wire form parses as JSON.
  final decoded = FrequencyMessage.decode(wire);
  expect(decoded.runtimeType, msg.runtimeType);
  return decoded as T;
}

void main() {
  group('FrequencyMessage envelope', () {
    test('every message exposes peerId, seq, atMs, kind, v on the wire', () {
      const msg = Heartbeat(peerId: 'p1', seq: 42, atMs: 1714060800000);
      final json = jsonDecode(msg.encode()) as Map<String, dynamic>;
      expect(json['kind'], 'ping');
      expect(json['peerId'], 'p1');
      expect(json['seq'], 42);
      expect(json['atMs'], 1714060800000);
      expect(json['v'], 1);
    });

    test('decode rejects messages with a different protocol version', () {
      final wire = '{"kind":"ping","peerId":"p1","seq":1,"atMs":0,"v":99}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('decode rejects unknown kinds', () {
      final wire = '{"kind":"frobnicate","peerId":"p1","seq":1,"atMs":0,"v":1}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('decode rejects malformed JSON', () {
      expect(() => FrequencyMessage.decode('not json'), throwsFormatException);
    });

    test('decode rejects valid JSON that is not an object', () {
      // Arrays, primitives, and nulls are valid JSON but not valid messages.
      // The contract is FormatException, not TypeError.
      expect(() => FrequencyMessage.decode('[]'), throwsFormatException);
      expect(() => FrequencyMessage.decode('"hello"'), throwsFormatException);
      expect(() => FrequencyMessage.decode('42'), throwsFormatException);
      expect(() => FrequencyMessage.decode('null'), throwsFormatException);
    });

    test('decode rejects messages with missing or non-int v', () {
      final missingV = '{"kind":"ping","peerId":"p1","seq":1,"atMs":0}';
      final stringV = '{"kind":"ping","peerId":"p1","seq":1,"atMs":0,"v":"1"}';
      expect(() => FrequencyMessage.decode(missingV), throwsFormatException);
      expect(() => FrequencyMessage.decode(stringV), throwsFormatException);
    });

    test('decode rejects messages with missing or non-string kind', () {
      final missingKind = '{"peerId":"p1","seq":1,"atMs":0,"v":1}';
      final intKind = '{"kind":42,"peerId":"p1","seq":1,"atMs":0,"v":1}';
      expect(() => FrequencyMessage.decode(missingKind), throwsFormatException);
      expect(() => FrequencyMessage.decode(intKind), throwsFormatException);
    });

    test('decode rejects roster_update with malformed roster', () {
      final notList =
          '{"kind":"roster_update","peerId":"p","seq":1,"atMs":0,"v":1,"roster":"oops"}';
      final badElement =
          '{"kind":"roster_update","peerId":"p","seq":1,"atMs":0,"v":1,"roster":["string-not-object"]}';
      expect(() => FrequencyMessage.decode(notList), throwsFormatException);
      expect(() => FrequencyMessage.decode(badElement), throwsFormatException);
    });

    // Regression: the envelope fields (peerId/seq/atMs) and kind-specific
    // fields used to be parsed with bare `as` casts, which throw `TypeError`
    // — a subclass of `Error`, NOT `Exception` and NOT `FormatException`. The
    // control-plane receiver (`BleControlTransport`) catches only
    // `FormatException`, so a wrong-typed-but-valid-JSON field would escape
    // the catch and crash the receive handler — a remote peer could drop the
    // control plane with one malformed message. The decode contract is
    // FormatException; assert it for present-but-mistyped fields.
    test('decode rejects non-string peerId as FormatException', () {
      final wire = '{"kind":"ping","peerId":42,"seq":1,"atMs":0,"v":1}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('decode rejects non-int seq as FormatException', () {
      final stringSeq = '{"kind":"ping","peerId":"p","seq":"1","atMs":0,"v":1}';
      final floatSeq = '{"kind":"ping","peerId":"p","seq":1.5,"atMs":0,"v":1}';
      expect(() => FrequencyMessage.decode(stringSeq), throwsFormatException);
      expect(() => FrequencyMessage.decode(floatSeq), throwsFormatException);
    });

    test('decode rejects non-int atMs as FormatException', () {
      final wire = '{"kind":"ping","peerId":"p","seq":1,"atMs":"0","v":1}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    // A negative or near-int64-max `seq` is valid JSON and passes a bare int
    // check, but `seq` is the control-plane dedup/ordering key feeding
    // SequenceFilter's per-peer watermark. An out-of-uint32-range value would
    // poison that watermark (a remote DoS on the control plane). The wire
    // counter is a uint32 starting at 1, so the decoder pins it to
    // [1, 0xFFFFFFFF] and rejects the rest as FormatException.
    test('decode rejects out-of-range seq as FormatException', () {
      final negative = '{"kind":"ping","peerId":"p","seq":-1,"atMs":0,"v":1}';
      final zero = '{"kind":"ping","peerId":"p","seq":0,"atMs":0,"v":1}';
      final tooBig =
          '{"kind":"ping","peerId":"p","seq":4294967296,"atMs":0,"v":1}';
      expect(() => FrequencyMessage.decode(negative), throwsFormatException);
      expect(() => FrequencyMessage.decode(zero), throwsFormatException);
      expect(() => FrequencyMessage.decode(tooBig), throwsFormatException);
    });

    test('decode accepts seq at the uint32 boundary', () {
      final maxSeq =
          '{"kind":"ping","peerId":"p","seq":4294967295,"atMs":0,"v":1}';
      final decoded = FrequencyMessage.decode(maxSeq);
      expect(decoded.seq, 0xFFFFFFFF);
    });

    test('decode rejects negative atMs as FormatException', () {
      final wire = '{"kind":"ping","peerId":"p","seq":1,"atMs":-1,"v":1}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('decode rejects non-string displayName as FormatException', () {
      final wire =
          '{"kind":"join_request","peerId":"p","seq":1,"atMs":0,"v":1,"displayName":42}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('decode rejects non-bool talking as FormatException', () {
      final wire =
          '{"kind":"talking","peerId":"p","seq":1,"atMs":0,"v":1,"talking":"yes"}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('decode rejects non-bool muted as FormatException', () {
      final wire =
          '{"kind":"mute","peerId":"p","seq":1,"atMs":0,"v":1,"muted":1}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('decode rejects non-string remove_peer target as FormatException', () {
      final wire =
          '{"kind":"remove_peer","peerId":"p","seq":1,"atMs":0,"v":1,"target":99}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('decode rejects mistyped media fields as FormatException', () {
      final stringTrackIdx =
          '{"kind":"media","peerId":"p","seq":1,"atMs":0,"v":1,"op":"queue_play","source":"lib","trackIdx":"2"}';
      final nonStringSource =
          '{"kind":"media","peerId":"p","seq":1,"atMs":0,"v":1,"op":"play","source":7}';
      expect(
        () => FrequencyMessage.decode(stringTrackIdx),
        throwsFormatException,
      );
      expect(
        () => FrequencyMessage.decode(nonStringSource),
        throwsFormatException,
      );
    });

    test('decode rejects non-object mediaState in join_accepted', () {
      final wire =
          '{"kind":"join_accepted","peerId":"p","seq":1,"atMs":0,"v":1,"hostPeerId":"h","roster":[],"mediaState":"oops"}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('decode rejects non-string btDevice as FormatException', () {
      final wire =
          '{"kind":"join_request","peerId":"p","seq":1,"atMs":0,"v":1,"displayName":"X","btDevice":42}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('decode rejects non-string recipientPeerId as FormatException', () {
      final wire =
          '{"kind":"join_accepted","peerId":"h","seq":1,"atMs":0,"v":1,"hostPeerId":"h","roster":[],"recipientPeerId":42}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('decode rejects mistyped roster-element fields as FormatException', () {
      // peerId mistyped inside a roster entry — the TypeError would previously
      // bubble out of ProtocolPeer.fromJson, past _parseRoster, past decode.
      final wire =
          '{"kind":"roster_update","peerId":"p","seq":1,"atMs":0,"v":1,'
          '"roster":[{"peerId":1,"displayName":"A"}]}';
      final badMuted =
          '{"kind":"roster_update","peerId":"p","seq":1,"atMs":0,"v":1,'
          '"roster":[{"peerId":"x","displayName":"A","muted":"no"}]}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
      expect(() => FrequencyMessage.decode(badMuted), throwsFormatException);
    });
  });

  group('lifecycle messages round-trip', () {
    test('JoinRequest', () {
      const msg = JoinRequest(
        peerId: 'p-guest',
        seq: 1,
        atMs: 1000,
        displayName: 'Maya',
        btDevice: 'AirPods Pro',
      );
      final round = _roundTrip(msg);
      expect(round.displayName, 'Maya');
      expect(round.btDevice, 'AirPods Pro');
    });

    test('JoinRequest without btDevice omits the field on the wire', () {
      const msg = JoinRequest(
        peerId: 'p',
        seq: 1,
        atMs: 0,
        displayName: 'NoHeadphones',
      );
      final json = jsonDecode(msg.encode()) as Map<String, dynamic>;
      expect(json.containsKey('btDevice'), isFalse);
      final round = _roundTrip(msg);
      expect(round.btDevice, isNull);
    });

    test('JoinAccepted with roster + mediaState', () {
      final msg = JoinAccepted(
        peerId: 'p-host',
        seq: 7,
        atMs: 1234,
        hostPeerId: 'p-host',
        roster: const [
          ProtocolPeer(peerId: 'p-host', displayName: 'You', muted: false),
          ProtocolPeer(
            peerId: 'p-guest',
            displayName: 'Maya',
            btDevice: 'AirPods Pro',
          ),
        ],
        mediaState: const MediaState(
          source: 'YouTube Music',
          trackIdx: 2,
          playing: true,
          positionMs: 37000,
        ),
      );
      final round = _roundTrip(msg);
      expect(round.roster.length, 2);
      expect(round.roster.last.btDevice, 'AirPods Pro');
      expect(round.mediaState?.trackIdx, 2);
    });

    test(
      'JoinAccepted carries voicePsm when set, omits it on the wire when null',
      () {
        // Set: 129 = 0x81, the lowest valid odd dynamic LE-CoC PSM.
        final withPsm = JoinAccepted(
          peerId: 'p-host',
          seq: 7,
          atMs: 1234,
          hostPeerId: 'p-host',
          roster: const [],
          voicePsm: 129,
        );
        final round = _roundTrip(withPsm);
        expect(round.voicePsm, 129);

        // Null: field is absent on the wire, parses back to null.
        final withoutPsm = JoinAccepted(
          peerId: 'p-host',
          seq: 7,
          atMs: 1234,
          hostPeerId: 'p-host',
          roster: const [],
        );
        final json = jsonDecode(withoutPsm.encode()) as Map<String, dynamic>;
        expect(json.containsKey('voicePsm'), isFalse);
        expect(_roundTrip(withoutPsm).voicePsm, isNull);
      },
    );

    test('JoinAccepted rejects invalid voicePsm values', () {
      const base =
          '{"kind":"join_accepted","peerId":"p-host","seq":7,"atMs":1234,"v":1,"hostPeerId":"p-host","roster":[]}';

      // Even PSMs are valid for BLE LE CoC — 128 (0x80) should parse fine.
      final evenPsm = base.replaceFirst('}', ',"voicePsm":128}');
      final parsed = FrequencyMessage.decode(evenPsm) as JoinAccepted;
      expect(parsed.voicePsm, 128);

      final outOfRangeLow = base.replaceFirst('}', ',"voicePsm":127}');
      final outOfRangeHigh = base.replaceFirst('}', ',"voicePsm":256}');
      final stringPsm = base.replaceFirst('}', ',"voicePsm":"129"}');
      final floatPsm = base.replaceFirst('}', ',"voicePsm":129.0}');

      expect(
        () => FrequencyMessage.decode(outOfRangeLow),
        throwsFormatException,
      );
      expect(
        () => FrequencyMessage.decode(outOfRangeHigh),
        throwsFormatException,
      );
      expect(() => FrequencyMessage.decode(stringPsm), throwsFormatException);
      expect(() => FrequencyMessage.decode(floatPsm), throwsFormatException);
    });

    test('JoinDenied carries reason as wire string', () {
      const msg = JoinDenied(
        peerId: 'p-host',
        seq: 7,
        atMs: 1234,
        reason: JoinDenyReason.versionMismatch,
      );
      final json = jsonDecode(msg.encode()) as Map<String, dynamic>;
      expect(json['reason'], 'version_mismatch');
      final round = _roundTrip(msg);
      expect(round.reason, JoinDenyReason.versionMismatch);
    });

    test('Leave round-trips with only the envelope', () {
      const msg = Leave(peerId: 'p', seq: 9, atMs: 1);
      final round = _roundTrip(msg);
      expect(round.peerId, 'p');
      expect(round.seq, 9);
    });

    test('RemovePeer carries target', () {
      const msg = RemovePeer(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        target: 'p-rude-guest',
      );
      final round = _roundTrip(msg);
      expect(round.target, 'p-rude-guest');
    });

    test('RosterUpdate', () {
      final msg = RosterUpdate(
        peerId: 'p-host',
        seq: 11,
        atMs: 0,
        roster: const [
          ProtocolPeer(peerId: 'a', displayName: 'A'),
          ProtocolPeer(
            peerId: 'b',
            displayName: 'B',
            muted: true,
            talking: true,
          ),
        ],
      );
      final round = _roundTrip(msg);
      expect(round.roster.length, 2);
      expect(round.roster[1].muted, isTrue);
      expect(round.roster[1].talking, isTrue);
    });
  });

  group('voice control round-trip', () {
    test('TalkingState', () {
      const msg = TalkingState(peerId: 'p', seq: 1, atMs: 0, talking: true);
      final round = _roundTrip(msg);
      expect(round.talking, isTrue);
    });

    test('MuteState', () {
      const msg = MuteState(peerId: 'p', seq: 1, atMs: 0, muted: true);
      final round = _roundTrip(msg);
      expect(round.muted, isTrue);
    });
  });

  group('media commands', () {
    test('every op round-trips through wire string', () {
      for (final op in MediaOp.values) {
        final msg = MediaCommand(
          peerId: 'p',
          seq: 1,
          atMs: 0,
          op: op,
          source: 'YouTube Music',
          trackIdx: op == MediaOp.queuePlay ? 3 : null,
          positionMs: op == MediaOp.seek ? 91500 : null,
        );
        final round = _roundTrip(msg);
        expect(round.op, op, reason: 'op $op should survive round-trip');
      }
    });

    test('seek carries positionMs', () {
      const msg = MediaCommand(
        peerId: 'p',
        seq: 1,
        atMs: 0,
        op: MediaOp.seek,
        source: 'YouTube Music',
        positionMs: 91500,
      );
      final round = _roundTrip(msg);
      expect(round.positionMs, 91500);
    });

    test(
      'queue_play decoded without trackIdx is rejected as FormatException',
      () {
        final wire =
            '{"kind":"media","peerId":"p","seq":1,"atMs":0,"v":1,"op":"queue_play","source":"YouTube Music"}';
        expect(() => FrequencyMessage.decode(wire), throwsFormatException);
      },
    );

    test('seek decoded without positionMs is rejected as FormatException', () {
      final wire =
          '{"kind":"media","peerId":"p","seq":1,"atMs":0,"v":1,"op":"seek","source":"YouTube Music"}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('queue_play with negative trackIdx is rejected as FormatException',
        () {
      final wire =
          '{"kind":"media","peerId":"p","seq":1,"atMs":0,"v":1,"op":"queue_play","source":"lib","trackIdx":-1}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('seek with negative positionMs is rejected as FormatException', () {
      final wire =
          '{"kind":"media","peerId":"p","seq":1,"atMs":0,"v":1,"op":"seek","source":"lib","positionMs":-1}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('queue_play carries trackIdx; play omits both optional fields', () {
      const queuePlay = MediaCommand(
        peerId: 'p',
        seq: 1,
        atMs: 0,
        op: MediaOp.queuePlay,
        source: 'Podcasts',
        trackIdx: 3,
      );
      final qpJson = jsonDecode(queuePlay.encode()) as Map<String, dynamic>;
      expect(qpJson['trackIdx'], 3);
      expect(qpJson.containsKey('positionMs'), isFalse);

      const play = MediaCommand(
        peerId: 'p',
        seq: 1,
        atMs: 0,
        op: MediaOp.play,
        source: 'Podcasts',
      );
      final playJson = jsonDecode(play.encode()) as Map<String, dynamic>;
      expect(playJson.containsKey('trackIdx'), isFalse);
      expect(playJson.containsKey('positionMs'), isFalse);
    });
  });

  group('health messages', () {
    test('SignalReport carries neighbors', () {
      final msg = SignalReport(
        peerId: 'p',
        seq: 1,
        atMs: 0,
        neighbors: const [
          NeighborSignal(peerId: 'a', rssi: -56),
          NeighborSignal(peerId: 'b', rssi: -71),
        ],
      );
      final round = _roundTrip(msg);
      expect(round.neighbors.length, 2);
      expect(round.neighbors.first.rssi, -56);
    });

    test('NeighborSignal.fromJson accepts an in-range dBm rssi', () {
      expect(NeighborSignal.fromJson({'peerId': 'a', 'rssi': -90}).rssi, -90);
      expect(NeighborSignal.fromJson({'peerId': 'b', 'rssi': 0}).rssi, 0);
      expect(NeighborSignal.fromJson({'peerId': 'c', 'rssi': -127}).rssi, -127);
    });

    test('NeighborSignal.fromJson rejects an out-of-range rssi', () {
      expect(
        () => NeighborSignal.fromJson({'peerId': 'a', 'rssi': 1000000}),
        throwsFormatException,
      );
      expect(
        () => NeighborSignal.fromJson({'peerId': 'a', 'rssi': 1}),
        throwsFormatException,
      );
      expect(
        () => NeighborSignal.fromJson({'peerId': 'a', 'rssi': -128}),
        throwsFormatException,
      );
    });

    test('Heartbeat round-trips', () {
      const msg = Heartbeat(peerId: 'p', seq: 99, atMs: 1234);
      final round = _roundTrip(msg);
      expect(round.peerId, 'p');
      expect(round.seq, 99);
    });
  });

  group('adaptive bitrate messages', () {
    test('LinkQuality round-trips with all fields', () {
      const msg = LinkQuality(
        peerId: 'p-guest',
        seq: 4,
        atMs: 1234,
        lossPct: 6.5,
        jitterMs: 80,
        underrunsPerSec: 0.4,
      );
      final json = jsonDecode(msg.encode()) as Map<String, dynamic>;
      expect(json['kind'], 'link_quality');
      expect(json['lossPct'], 6.5);
      expect(json['jitterMs'], 80);
      expect(json['underrunsPerSec'], 0.4);
      final round = _roundTrip(msg);
      expect(round.lossPct, 6.5);
      expect(round.jitterMs, 80);
      expect(round.underrunsPerSec, 0.4);
    });

    test('LinkQuality decodes integer-shaped lossPct / underrunsPerSec', () {
      // jsonEncode of `0.0` may serialize as `0` on some encoders; the
      // decoder must accept either shape rather than rejecting an
      // otherwise-valid sample. (jitterMs is the only int-typed field.)
      final wire =
          '{"kind":"link_quality","peerId":"p","seq":1,"atMs":0,"v":1,"lossPct":0,"jitterMs":40,"underrunsPerSec":0}';
      final decoded = FrequencyMessage.decode(wire) as LinkQuality;
      expect(decoded.lossPct, 0.0);
      expect(decoded.underrunsPerSec, 0.0);
      expect(decoded.jitterMs, 40);
    });

    test('LinkQuality rejects out-of-range values', () {
      const base =
          '{"kind":"link_quality","peerId":"p","seq":1,"atMs":0,"v":1,"jitterMs":40,"underrunsPerSec":0.1';
      final negativeLoss = '$base,"lossPct":-1.0}';
      final overLoss = '$base,"lossPct":150.0}';
      final negativeJitter =
          '{"kind":"link_quality","peerId":"p","seq":1,"atMs":0,"v":1,"lossPct":1.0,"jitterMs":-1,"underrunsPerSec":0.1}';
      final negativeUnderruns =
          '{"kind":"link_quality","peerId":"p","seq":1,"atMs":0,"v":1,"lossPct":1.0,"jitterMs":40,"underrunsPerSec":-0.5}';
      expect(
        () => FrequencyMessage.decode(negativeLoss),
        throwsFormatException,
      );
      expect(() => FrequencyMessage.decode(overLoss), throwsFormatException);
      expect(
        () => FrequencyMessage.decode(negativeJitter),
        throwsFormatException,
      );
      expect(
        () => FrequencyMessage.decode(negativeUnderruns),
        throwsFormatException,
      );
    });

    test('LinkQuality rejects over-upper-bound jitterMs / underrunsPerSec', () {
      // A peer can otherwise send int64-garbage observability values that skew
      // the host voice-debug dashboard; the decoder bounds them like lossPct.
      final overJitter =
          '{"kind":"link_quality","peerId":"p","seq":1,"atMs":0,"v":1,"lossPct":1.0,"jitterMs":${LinkQuality.kMaxJitterMs + 1},"underrunsPerSec":0.1}';
      final overUnderruns =
          '{"kind":"link_quality","peerId":"p","seq":1,"atMs":0,"v":1,"lossPct":1.0,"jitterMs":40,"underrunsPerSec":${LinkQuality.kMaxUnderrunsPerSec + 1}}';
      final hugeJitter =
          '{"kind":"link_quality","peerId":"p","seq":1,"atMs":0,"v":1,"lossPct":1.0,"jitterMs":9223372036854775807,"underrunsPerSec":0.1}';
      expect(() => FrequencyMessage.decode(overJitter), throwsFormatException);
      expect(
        () => FrequencyMessage.decode(overUnderruns),
        throwsFormatException,
      );
      expect(() => FrequencyMessage.decode(hugeJitter), throwsFormatException);
    });

    test('LinkQuality accepts values at the upper bound', () {
      final atJitter =
          '{"kind":"link_quality","peerId":"p","seq":1,"atMs":0,"v":1,"lossPct":1.0,"jitterMs":${LinkQuality.kMaxJitterMs},"underrunsPerSec":${LinkQuality.kMaxUnderrunsPerSec}}';
      final decoded = FrequencyMessage.decode(atJitter) as LinkQuality;
      expect(decoded.jitterMs, LinkQuality.kMaxJitterMs);
      expect(decoded.underrunsPerSec, LinkQuality.kMaxUnderrunsPerSec);
    });

    test('LinkQuality rejects wrong-typed numeric fields', () {
      final stringLoss =
          '{"kind":"link_quality","peerId":"p","seq":1,"atMs":0,"v":1,"lossPct":"oops","jitterMs":40,"underrunsPerSec":0.1}';
      final floatJitter =
          '{"kind":"link_quality","peerId":"p","seq":1,"atMs":0,"v":1,"lossPct":1.0,"jitterMs":40.5,"underrunsPerSec":0.1}';
      expect(() => FrequencyMessage.decode(stringLoss), throwsFormatException);
      expect(() => FrequencyMessage.decode(floatJitter), throwsFormatException);
    });

    test('BitrateHint round-trips with target + bps', () {
      const msg = BitrateHint(
        peerId: 'p-host',
        seq: 7,
        atMs: 0,
        target: 'p-guest-a',
        bps: 16000,
      );
      final json = jsonDecode(msg.encode()) as Map<String, dynamic>;
      expect(json['kind'], 'bitrate_hint');
      expect(json['target'], 'p-guest-a');
      expect(json['bps'], 16000);
      final round = _roundTrip(msg);
      expect(round.target, 'p-guest-a');
      expect(round.bps, 16000);
    });

    test('BitrateHint rejects missing or wrong-typed target', () {
      final missing =
          '{"kind":"bitrate_hint","peerId":"p","seq":1,"atMs":0,"v":1,"bps":16000}';
      final intTarget =
          '{"kind":"bitrate_hint","peerId":"p","seq":1,"atMs":0,"v":1,"bps":16000,"target":42}';
      expect(() => FrequencyMessage.decode(missing), throwsFormatException);
      expect(() => FrequencyMessage.decode(intTarget), throwsFormatException);
    });

    test('BitrateHint rejects non-positive or non-int bps', () {
      final negative =
          '{"kind":"bitrate_hint","peerId":"p","seq":1,"atMs":0,"v":1,"target":"g","bps":-100}';
      final zero =
          '{"kind":"bitrate_hint","peerId":"p","seq":1,"atMs":0,"v":1,"target":"g","bps":0}';
      final string =
          '{"kind":"bitrate_hint","peerId":"p","seq":1,"atMs":0,"v":1,"target":"g","bps":"16000"}';
      expect(() => FrequencyMessage.decode(negative), throwsFormatException);
      expect(() => FrequencyMessage.decode(zero), throwsFormatException);
      expect(() => FrequencyMessage.decode(string), throwsFormatException);
    });

    test('BitrateHint rejects bps above kMaxBps', () {
      final over =
          '{"kind":"bitrate_hint","peerId":"p","seq":1,"atMs":0,"v":1,"target":"g","bps":500001}';
      final giant =
          '{"kind":"bitrate_hint","peerId":"p","seq":1,"atMs":0,"v":1,"target":"g","bps":9007199254740992}';
      expect(() => FrequencyMessage.decode(over), throwsFormatException);
      expect(() => FrequencyMessage.decode(giant), throwsFormatException);
      // kMaxBps itself is accepted
      final atLimit =
          '{"kind":"bitrate_hint","peerId":"p","seq":1,"atMs":0,"v":1,"target":"g","bps":${BitrateHint.kMaxBps}}';
      expect(
        (FrequencyMessage.decode(atLimit) as BitrateHint).bps,
        BitrateHint.kMaxBps,
      );
    });
  });

  group('ProtocolPeer', () {
    test('JSON round-trip preserves all fields', () {
      const original = ProtocolPeer(
        peerId: 'p',
        displayName: 'Maya',
        btDevice: 'AirPods Pro',
        muted: true,
        talking: true,
      );
      final round = ProtocolPeer.fromJson(original.toJson());
      expect(round, original);
    });

    test('defaults muted/talking to false when missing on the wire', () {
      final round = ProtocolPeer.fromJson({
        'peerId': 'p',
        'displayName': 'Maya',
      });
      expect(round.muted, isFalse);
      expect(round.talking, isFalse);
      expect(round.btDevice, isNull);
    });

    test('hashCode + toString cover terminal members', () {
      const a = ProtocolPeer(
        peerId: 'p',
        displayName: 'Maya',
        btDevice: 'AirPods Pro',
        muted: true,
        talking: true,
      );
      const b = ProtocolPeer(
        peerId: 'p',
        displayName: 'Maya',
        btDevice: 'AirPods Pro',
        muted: true,
        talking: true,
      );
      expect(a.hashCode, b.hashCode);
      expect(a.toString(), contains('Maya'));
      expect(a.toString(), contains('muted=true'));
    });
  });

  group('JoinDenyReason.fromWire', () {
    test('throws FormatException on unknown reason', () {
      expect(
        () => JoinDenyReasonWire.fromWire('moon-phase'),
        throwsFormatException,
      );
    });
  });

  group('MediaOp.fromWire', () {
    test('throws FormatException on unknown op', () {
      expect(() => MediaOpWire.fromWire('teleport'), throwsFormatException);
    });
  });

  group('MediaState equality + hashCode', () {
    test('value-equal instances are equal', () {
      const a = MediaState(
        source: 'spotify',
        trackIdx: 1,
        playing: true,
        positionMs: 4200,
      );
      const b = MediaState(
        source: 'spotify',
        trackIdx: 1,
        playing: true,
        positionMs: 4200,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('different field flips equality', () {
      const a = MediaState(
        source: 'spotify',
        trackIdx: 1,
        playing: true,
        positionMs: 4200,
      );
      const b = MediaState(
        source: 'spotify',
        trackIdx: 1,
        playing: false,
        positionMs: 4200,
      );
      expect(a == b, isFalse);
    });
  });

  group('MediaState field type rejection', () {
    const base =
        '{"kind":"join_accepted","peerId":"h","seq":1,"atMs":0,"v":1,"hostPeerId":"h","roster":[],"mediaState":';

    test('rejects non-string source as FormatException', () {
      final wire = '$base{"source":42,"trackIdx":1,"playing":true,"positionMs":0}}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('rejects non-int trackIdx as FormatException', () {
      final wire = '$base{"source":"s","trackIdx":"2","playing":true,"positionMs":0}}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('rejects non-bool playing as FormatException', () {
      final wire = '$base{"source":"s","trackIdx":1,"playing":"true","positionMs":0}}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('rejects non-int positionMs as FormatException', () {
      final wire = '$base{"source":"s","trackIdx":1,"playing":true,"positionMs":37.5}}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('rejects negative trackIdx as FormatException', () {
      final wire = '$base{"source":"s","trackIdx":-1,"playing":true,"positionMs":0}}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('rejects negative positionMs as FormatException', () {
      final wire = '$base{"source":"s","trackIdx":0,"playing":true,"positionMs":-1}}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('accepts zero trackIdx and zero positionMs', () {
      final wire = '$base{"source":"s","trackIdx":0,"playing":true,"positionMs":0}}';
      expect(() => FrequencyMessage.decode(wire), returnsNormally);
    });
  });

  group('NeighborSignal equality + hashCode', () {
    test('value-equal instances are equal', () {
      const a = NeighborSignal(peerId: 'p', rssi: -65);
      const b = NeighborSignal(peerId: 'p', rssi: -65);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('different rssi flips equality', () {
      const a = NeighborSignal(peerId: 'p', rssi: -65);
      const b = NeighborSignal(peerId: 'p', rssi: -70);
      expect(a == b, isFalse);
    });
  });

  group('HostTransfer', () {
    const validUuid = '550e8400-e29b-41d4-a716-446655440000';

    test('round-trips with a canonical sessionUuid', () {
      const msg = HostTransfer(
        peerId: 'p1',
        seq: 1,
        atMs: 0,
        newHostPeerId: 'p2',
        sessionUuid: validUuid,
      );
      final rt = _roundTrip(msg);
      expect(rt.sessionUuid, validUuid);
      expect(rt.newHostPeerId, 'p2');
    });

    test('decode rejects non-canonical sessionUuid as FormatException', () {
      for (final bad in [
        'not-a-uuid',
        '550E8400-E29B-41D4-A716-446655440000', // uppercase
        '550e8400e29b41d4a716446655440000', // no hyphens
        '',
        '550e840-e29b-41d4-a716-446655440000', // short first segment
      ]) {
        final wire =
            '{"kind":"host_transfer","v":1,"peerId":"p1","seq":1,"atMs":0,'
            '"newHostPeerId":"p2","sessionUuid":"$bad"}';
        expect(
          () => FrequencyMessage.decode(wire),
          throwsFormatException,
          reason: 'expected rejection for sessionUuid="$bad"',
        );
      }
    });
  });

  group('exhaustive switch on FrequencyMessage', () {
    // Compile-time check: if a new sealed subclass is added, this switch
    // becomes non-exhaustive and the analyzer fails. That's the whole point
    // of using sealed for the protocol.
    String describe(FrequencyMessage m) => switch (m) {
      JoinRequest() => 'join_request',
      JoinAccepted() => 'join_accepted',
      JoinDenied() => 'join_denied',
      Leave() => 'leave',
      RemovePeer() => 'remove_peer',
      RosterUpdate() => 'roster_update',
      TalkingState() => 'talking',
      MuteState() => 'mute',
      MediaCommand() => 'media',
      SignalReport() => 'signal_report',
      LinkQuality() => 'link_quality',
      BitrateHint() => 'bitrate_hint',
      Heartbeat() => 'ping',
      HostTransfer() => 'host_transfer',
    };

    test('every kind has a branch', () {
      const samples = <FrequencyMessage>[
        JoinRequest(peerId: 'p', seq: 1, atMs: 0, displayName: 'x'),
        Leave(peerId: 'p', seq: 1, atMs: 0),
        Heartbeat(peerId: 'p', seq: 1, atMs: 0),
      ];
      for (final s in samples) {
        expect(describe(s), s.kind);
      }
    });
  });
}
