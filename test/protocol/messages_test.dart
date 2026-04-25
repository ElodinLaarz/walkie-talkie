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
