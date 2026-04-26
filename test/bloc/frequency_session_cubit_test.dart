import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/bloc/frequency_session_cubit.dart';
import 'package:walkie_talkie/bloc/frequency_session_state.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/protocol/peer.dart';
import 'package:walkie_talkie/services/identity_store.dart';

class _FakeStore implements IdentityStore {
  String? _name;
  String? _peerId;
  bool throwOnGet = false;
  bool throwOnSet = false;
  bool throwOnGetPeerId = false;
  int setCalls = 0;

  _FakeStore({String? initial}) : _name = initial;

  @override
  Future<String?> getDisplayName() async {
    if (throwOnGet) throw StateError('boom');
    return _name;
  }

  @override
  Future<void> setDisplayName(String value) async {
    setCalls++;
    if (throwOnSet) throw StateError('boom');
    final trimmed = value.trim();
    _name = trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<String> getPeerId() async {
    if (throwOnGetPeerId) throw StateError('boom');
    return _peerId ??= 'fake-peer-id';
  }
}

void main() {
  group('FrequencySessionCubit', () {
    test('starts in SessionBooting', () {
      final cubit = FrequencySessionCubit(identityStore: _FakeStore());
      expect(cubit.state, isA<SessionBooting>());
    });

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap with a persisted name routes to Discovery',
      build: () => FrequencySessionCubit(
        identityStore: _FakeStore(initial: 'Maya'),
      ),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [const SessionDiscovery(myName: 'Maya')],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap without a persisted name routes to Onboarding',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [const SessionOnboarding()],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap falls through to Onboarding when the store throws',
      build: () => FrequencySessionCubit(
        identityStore: _FakeStore()..throwOnGet = true,
      ),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [const SessionOnboarding()],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'completeOnboarding persists and advances to Discovery',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const SessionOnboarding(),
      act: (cubit) => cubit.completeOnboarding('Devon'),
      expect: () => [const SessionDiscovery(myName: 'Devon')],
      verify: (cubit) async {
        expect((cubit.identityStore as _FakeStore).setCalls, 1);
        expect(await cubit.identityStore.getDisplayName(), 'Devon');
      },
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'completeOnboarding still advances when persistence throws',
      build: () => FrequencySessionCubit(
        identityStore: _FakeStore()..throwOnSet = true,
      ),
      seed: () => const SessionOnboarding(),
      act: (cubit) => cubit.completeOnboarding('Sam'),
      expect: () => [const SessionDiscovery(myName: 'Sam')],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'rename in Discovery updates the name in place',
      build: () => FrequencySessionCubit(
        identityStore: _FakeStore(initial: 'Maya'),
      ),
      seed: () => const SessionDiscovery(myName: 'Maya'),
      act: (cubit) => cubit.rename('Maya R.'),
      expect: () => [const SessionDiscovery(myName: 'Maya R.')],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'rename still updates name when persistence throws',
      build: () => FrequencySessionCubit(
        identityStore: _FakeStore(initial: 'Maya')..throwOnSet = true,
      ),
      seed: () => const SessionDiscovery(myName: 'Maya'),
      act: (cubit) => cubit.rename('Maya R.'),
      expect: () => [const SessionDiscovery(myName: 'Maya R.')],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'rename in Room preserves freq + host role',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: true,
      ),
      act: (cubit) => cubit.rename('Maya R.'),
      expect: () => [
        const SessionRoom(
          myName: 'Maya R.',
          roomFreq: '104.3',
          roomIsHost: true,
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'rename in Booting/Onboarding is a no-op on the visible state',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const SessionOnboarding(),
      act: (cubit) => cubit.rename('Sam'),
      expect: () => const <FrequencySessionState>[],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'joinRoom from Discovery enters the Room with freq + host flag',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const SessionDiscovery(myName: 'Maya'),
      act: (cubit) => cubit.joinRoom(freq: '104.3', isHost: true),
      expect: () => [
        const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: true,
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'joinRoom outside Discovery is a no-op',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const SessionOnboarding(),
      act: (cubit) => cubit.joinRoom(freq: '104.3', isHost: true),
      expect: () => const <FrequencySessionState>[],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'leaveRoom drops back to Discovery with the prior name',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: true,
      ),
      act: (cubit) => cubit.leaveRoom(),
      expect: () => [const SessionDiscovery(myName: 'Maya')],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'leaveRoom outside Room is a no-op',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const SessionDiscovery(myName: 'Maya'),
      act: (cubit) => cubit.leaveRoom(),
      expect: () => const <FrequencySessionState>[],
    );

    // ── Wire-protocol surface ──────────────────────────────────────────

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'applyJoinAccepted lands roster + hostPeerId + mediaState on the room',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
      ),
      act: (cubit) => cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 7,
        atMs: 1234,
        hostPeerId: 'p-host',
        roster: const [
          ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
          ProtocolPeer(peerId: 'p-maya', displayName: 'Maya'),
        ],
        mediaState: const MediaState(
          source: 'YouTube Music',
          trackIdx: 2,
          playing: true,
          positionMs: 37000,
        ),
      )),
      expect: () => [
        SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: false,
          hostPeerId: 'p-host',
          roster: const [
            ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
            ProtocolPeer(peerId: 'p-maya', displayName: 'Maya'),
          ],
          mediaState: const MediaState(
            source: 'YouTube Music',
            trackIdx: 2,
            playing: true,
            positionMs: 37000,
          ),
        ),
      ],
    );

    test('SessionRoom.copyWith returns an unmodifiable roster', () {
      // Wire-decoded JoinAccepted.roster is a plain mutable list. Once
      // it lands in SessionRoom, callers shouldn't be able to mutate
      // it retroactively — past states must stay stable.
      final mutable = <ProtocolPeer>[
        const ProtocolPeer(peerId: 'a', displayName: 'A'),
      ];
      final room = const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
      ).copyWith(roster: mutable);

      expect(
        () => room.roster.add(const ProtocolPeer(peerId: 'b', displayName: 'B')),
        throwsUnsupportedError,
      );
      // The originally-passed list is independent — mutating it must
      // not bleed into the stored roster.
      mutable.add(const ProtocolPeer(peerId: 'c', displayName: 'C'));
      expect(room.roster, hasLength(1));
    });

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'applyJoinAccepted with null mediaState clears the prior snapshot on rejoin',
      // The host-has-nothing-playing case: copyWith must distinguish
      // "argument omitted" from "argument explicitly null", or the stale
      // mediaState from the last connection survives the rejoin.
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
        hostPeerId: 'p-host',
        mediaState: const MediaState(
          source: 'YouTube Music',
          trackIdx: 4,
          playing: true,
          positionMs: 60000,
        ),
      ),
      act: (cubit) => cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        hostPeerId: 'p-host',
        roster: const [],
        // mediaState omitted from the wire = null in the typed message.
      )),
      expect: () => [
        const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: false,
          hostPeerId: 'p-host',
          // mediaState should be cleared, not retained from before.
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'applyJoinAccepted outside SessionRoom is a no-op',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const SessionDiscovery(myName: 'Maya'),
      act: (cubit) => cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        hostPeerId: 'p-host',
        roster: const [],
      )),
      expect: () => const <FrequencySessionState>[],
    );

    test('applyJoinAccepted resets the per-peer sequence counter', () async {
      // Per the protocol: a fresh JoinAccepted (initial join or reconnect)
      // resets seq counters on both ends — receivers clear lastSeq[peer]
      // and senders restart at 1. We exercise the sender side here.
      final cubit = FrequencySessionCubit(identityStore: _FakeStore());
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
      ));

      // Bump the counter by sending a couple of commands first.
      await cubit.sendMediaCommand(op: MediaOp.play, source: 'YouTube Music');
      await cubit.sendMediaCommand(op: MediaOp.pause, source: 'YouTube Music');

      cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        hostPeerId: 'p-host',
        roster: const [],
      ));

      final next = cubit.mediaCommands.first;
      await cubit.sendMediaCommand(op: MediaOp.play, source: 'YouTube Music');
      final emitted = await next;
      expect(emitted.seq, 1, reason: 'seq should restart at 1 after rejoin');

      await cubit.close();
    });

    test('sendMediaCommand emits the originator command on the stream', () async {
      final cubit = FrequencySessionCubit(identityStore: _FakeStore());
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
      ));

      final emissions = <MediaCommand>[];
      final sub = cubit.mediaCommands.listen(emissions.add);

      await cubit.sendMediaCommand(
        op: MediaOp.seek,
        source: 'YouTube Music',
        positionMs: 91500,
      );

      // Drain the broadcast event-queue scheduling.
      await Future<void>.delayed(Duration.zero);

      expect(emissions, hasLength(1));
      expect(emissions.single.peerId, 'fake-peer-id');
      expect(emissions.single.op, MediaOp.seek);
      expect(emissions.single.positionMs, 91500);
      expect(emissions.single.seq, 1);

      await sub.cancel();
      await cubit.close();
    });

    test(
      'applyHostMediaEcho re-emits the host-echoed command for non-originator UI '
      'reaction',
      () async {
        final cubit = FrequencySessionCubit(identityStore: _FakeStore());
        cubit.emit(const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: false,
          hostPeerId: 'p-host',
        ));

        final emissions = <MediaCommand>[];
        final sub = cubit.mediaCommands.listen(emissions.add);

        // Host echoes a "skip" command originally issued by another peer.
        cubit.applyHostMediaEcho(const MediaCommand(
          peerId: 'p-host',
          seq: 12,
          atMs: 9999,
          op: MediaOp.skip,
          source: 'YouTube Music',
        ));

        await Future<void>.delayed(Duration.zero);

        expect(emissions, hasLength(1));
        expect(emissions.single.peerId, 'p-host');
        expect(emissions.single.op, MediaOp.skip);

        await sub.cancel();
        await cubit.close();
      },
    );

    test('applyJoinAccepted after close is a silent no-op', () async {
      // BLE callbacks can fire after the user navigates away and the
      // cubit closes; we shouldn't throw on a post-dispose emit.
      final cubit = FrequencySessionCubit(identityStore: _FakeStore());
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
      ));
      await cubit.close();

      expect(
        () => cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [],
        )),
        returnsNormally,
      );
    });

    test('sendMediaCommand swallows getPeerId failures', () async {
      // Identity-store errors at this point shouldn't escape as
      // unhandled async errors — room-screen callers fire-and-forget,
      // so an unhandled rethrow would crash the zone.
      final store = _FakeStore()..throwOnGetPeerId = true;
      final cubit = FrequencySessionCubit(identityStore: store);
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
      ));

      await expectLater(
        cubit.sendMediaCommand(op: MediaOp.play, source: 'YouTube Music'),
        completes,
      );

      await cubit.close();
    });

    test('sendMediaCommand suspended through close is a silent no-op', () async {
      // The race the close-ordering fix protects: sendMediaCommand awaits
      // getPeerId, close() runs, sendMediaCommand resumes — must not throw
      // `Bad state: Cannot add new events after calling close`.
      final completer = Completer<String>();
      final store = _GatedPeerIdStore(completer.future);
      final cubit = FrequencySessionCubit(identityStore: store);
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
      ));

      final pending = cubit.sendMediaCommand(
        op: MediaOp.play,
        source: 'YouTube Music',
      );

      // Close the cubit while sendMediaCommand is still awaiting.
      final closing = cubit.close();
      // Now release the peer-id resolution — sendMediaCommand resumes
      // post-close.
      completer.complete('p-late');

      await expectLater(pending, completes);
      await closing;
    });

    test('applyHostMediaEcho after close is a silent no-op', () async {
      // Same shape: a late RESPONSE-notify shouldn't throw
      // `Bad state: Cannot add new events after calling close`.
      final cubit = FrequencySessionCubit(identityStore: _FakeStore());
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
      ));
      await cubit.close();

      expect(
        () => cubit.applyHostMediaEcho(const MediaCommand(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          op: MediaOp.play,
          source: 'YouTube Music',
        )),
        returnsNormally,
      );
    });

    test('applyHostMediaEcho outside SessionRoom is a no-op', () async {
      final cubit = FrequencySessionCubit(identityStore: _FakeStore());
      // No room emitted; we're sitting in Booting.
      final emissions = <MediaCommand>[];
      final sub = cubit.mediaCommands.listen(emissions.add);

      cubit.applyHostMediaEcho(const MediaCommand(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        op: MediaOp.play,
        source: 'YouTube Music',
      ));

      await Future<void>.delayed(Duration.zero);
      expect(emissions, isEmpty);

      await sub.cancel();
      await cubit.close();
    });

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'rename in Room preserves the JoinAccepted snapshot fields',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
        hostPeerId: 'p-host',
        roster: const [ProtocolPeer(peerId: 'p-host', displayName: 'Devon')],
        mediaState: const MediaState(
          source: 'YouTube Music',
          trackIdx: 2,
          playing: true,
          positionMs: 37000,
        ),
      ),
      act: (cubit) => cubit.rename('Maya R.'),
      expect: () => [
        SessionRoom(
          myName: 'Maya R.',
          roomFreq: '104.3',
          roomIsHost: false,
          hostPeerId: 'p-host',
          roster: const [ProtocolPeer(peerId: 'p-host', displayName: 'Devon')],
          mediaState: const MediaState(
            source: 'YouTube Music',
            trackIdx: 2,
            playing: true,
            positionMs: 37000,
          ),
        ),
      ],
    );
  });

  group('FrequencySessionState', () {
    test('Equatable equality treats identical fields as equal', () {
      const a = SessionDiscovery(myName: 'Maya');
      const b = SessionDiscovery(myName: 'Maya');
      expect(a, equals(b));
    });

    test('Equatable equality distinguishes Booting from Onboarding', () {
      expect(const SessionBooting(), isNot(equals(const SessionOnboarding())));
    });

    test('SessionRoom carries non-null freq + host', () {
      const r = SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: true,
      );
      expect(r.roomFreq, '104.3');
      expect(r.roomIsHost, isTrue);
    });
  });
}

/// IdentityStore whose `getPeerId` blocks on a caller-supplied future.
/// Lets a test wedge `sendMediaCommand` mid-await so we can drive a
/// `close()` between the await and the resume — the exact race the
/// close-ordering fix addresses.
class _GatedPeerIdStore implements IdentityStore {
  final Future<String> _peerIdFuture;
  _GatedPeerIdStore(this._peerIdFuture);

  @override
  Future<String?> getDisplayName() async => null;

  @override
  Future<void> setDisplayName(String value) async {}

  @override
  Future<String> getPeerId() => _peerIdFuture;
}
