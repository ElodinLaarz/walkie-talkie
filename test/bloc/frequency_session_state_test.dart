import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/bloc/frequency_session_state.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/protocol/peer.dart';

void main() {
  group('SessionRoom.copyWith', () {
    late SessionRoom base;

    setUp(() {
      base = const SessionRoom(
        myName: 'Alice',
        roomFreq: '99.1',
        roomIsHost: false,
        hostPeerId: 'host-1',
        macAddress: 'AA:BB:CC:DD:EE:FF',
        sessionUuidLow8: 'deadbeef01234567',
        connectionPhase: ConnectionPhase.online,
      );
    });

    test('passes through unchanged fields', () {
      final copy = base.copyWith(myName: 'Bob');
      expect(copy.myName, 'Bob');
      expect(copy.hostPeerId, base.hostPeerId);
      expect(copy.macAddress, base.macAddress);
      expect(copy.sessionUuidLow8, base.sessionUuidLow8);
      expect(copy.mediaState, isNull);
    });

    test('explicit null clears hostPeerId', () {
      final copy = base.copyWith(hostPeerId: null);
      expect(copy.hostPeerId, isNull);
    });

    test('explicit null clears macAddress', () {
      final copy = base.copyWith(macAddress: null);
      expect(copy.macAddress, isNull);
    });

    test('explicit null clears sessionUuidLow8', () {
      final copy = base.copyWith(sessionUuidLow8: null);
      expect(copy.sessionUuidLow8, isNull);
    });

    test('explicit null clears mediaState', () {
      final withMedia = base.copyWith(
        mediaState: const MediaState(
          source: 'local',
          trackIdx: 0,
          playing: true,
          positionMs: 0,
        ),
      );
      final cleared = withMedia.copyWith(mediaState: null);
      expect(cleared.mediaState, isNull);
    });

    test('wrong type for hostPeerId throws ArgumentError', () {
      expect(
        () => base.copyWith(hostPeerId: 123),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('wrong type for macAddress throws ArgumentError', () {
      expect(
        () => base.copyWith(macAddress: 42),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('wrong type for sessionUuidLow8 throws ArgumentError', () {
      expect(
        () => base.copyWith(sessionUuidLow8: true),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('wrong type for mediaState throws ArgumentError', () {
      expect(
        () => base.copyWith(mediaState: 'not-a-MediaState'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('roster wrapped in unmodifiable', () {
      final peer = const ProtocolPeer(
        peerId: 'p1',
        displayName: 'Peer 1',
      );
      final copy = base.copyWith(roster: [peer]);
      expect(() => copy.roster.add(peer), throwsUnsupportedError);
    });
  });
}
