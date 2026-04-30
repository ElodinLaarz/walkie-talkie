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
      final missingV =
          '{"kind":"ping","peerId":"p1","seq":1,"atMs":0}';
      final stringV =
          '{"kind":"ping","peerId":"p1","seq":1,"atMs":0,"v":"1"}';
      expect(() => FrequencyMessage.decode(missingV), throwsFormatException);
      expect(() => FrequencyMessage.decode(stringV), throwsFormatException);
    });

    test('decode rejects messages with missing or non-string kind', () {
      final missingKind = '{"peerId":"p1","seq":1,"atMs":0,"v":1}';
      final intKind =
          '{"kind":42,"peerId":"p1","seq":1,"atMs":0,"v":1}';
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
              peerId: 'p-guest', displayName: 'Maya', btDevice: 'AirPods Pro'),
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

    test('JoinAccepted carries voicePsm when set, omits it on the wire when null',
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
    });

    test('JoinAccepted rejects invalid voicePsm values', () {
      const base =
          '{"kind":"join_accepted","peerId":"p-host","seq":7,"atMs":1234,"v":1,"hostPeerId":"p-host","roster":[]}';

      final evenPsm = base.replaceFirst('}', ',"voicePsm":128}');
      final outOfRangeLow = base.replaceFirst('}', ',"voicePsm":127}');
      final outOfRangeHigh = base.replaceFirst('}', ',"voicePsm":256}');
      final stringPsm = base.replaceFirst('}', ',"voicePsm":"129"}');
      final floatPsm = base.replaceFirst('}', ',"voicePsm":129.0}');

      expect(() => FrequencyMessage.decode(evenPsm), throwsFormatException);
      expect(() => FrequencyMessage.decode(outOfRangeLow), throwsFormatException);
      expect(() => FrequencyMessage.decode(outOfRangeHigh), throwsFormatException);
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
          peerId: 'p-host', seq: 1, atMs: 0, target: 'p-rude-guest');
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
          ProtocolPeer(peerId: 'b', displayName: 'B', muted: true, talking: true),
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

    test('queue_play decoded without trackIdx is rejected as FormatException', () {
      final wire =
          '{"kind":"media","peerId":"p","seq":1,"atMs":0,"v":1,"op":"queue_play","source":"YouTube Music"}';
      expect(() => FrequencyMessage.decode(wire), throwsFormatException);
    });

    test('seek decoded without positionMs is rejected as FormatException', () {
      final wire =
          '{"kind":"media","peerId":"p","seq":1,"atMs":0,"v":1,"op":"seek","source":"YouTube Music"}';
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
      expect(() => FrequencyMessage.decode(negativeLoss), throwsFormatException);
      expect(() => FrequencyMessage.decode(overLoss), throwsFormatException);
      expect(
          () => FrequencyMessage.decode(negativeJitter), throwsFormatException);
      expect(
        () => FrequencyMessage.decode(negativeUnderruns),
        throwsFormatException,
      );
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
