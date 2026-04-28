import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/bloc/frequency_session_cubit.dart';
import 'package:walkie_talkie/bloc/frequency_session_state.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/protocol/peer.dart';
import 'package:walkie_talkie/services/audio_service.dart';
import 'package:walkie_talkie/services/identity_store.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';

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

class _FakeRecentFrequenciesStore implements RecentFrequenciesStore {
  final List<String> _entries;
  bool throwOnGet = false;
  bool throwOnRecord = false;
  int recordCalls = 0;

  _FakeRecentFrequenciesStore({List<String>? initial})
      : _entries = List<String>.of(initial ?? const []);

  @override
  Future<List<String>> getRecent() async {
    if (throwOnGet) throw StateError('boom');
    return List<String>.unmodifiable(_entries);
  }

  @override
  Future<void> record(String freq) async {
    recordCalls++;
    if (throwOnRecord) throw StateError('boom');
    final trimmed = freq.trim();
    if (trimmed.isEmpty) return;
    _entries
      ..remove(trimmed)
      ..insert(0, trimmed);
    // Mirror the production cap so the fake doesn't silently let tests
    // drift past behavior the real store enforces.
    if (_entries.length > HiveRecentFrequenciesStore.maxEntries) {
      _entries.removeRange(
        HiveRecentFrequenciesStore.maxEntries,
        _entries.length,
      );
    }
  }

  @override
  Future<void> clear() async => _entries.clear();
}

// Zero delays so reconnect tests don't actually wait.
const _testReconnectDelays = [
  Duration.zero,
  Duration.zero,
  Duration.zero,
  Duration.zero,
  Duration.zero,
  Duration.zero,
];

FrequencySessionCubit _makeCubit({
  IdentityStore? identityStore,
  RecentFrequenciesStore? recentFrequenciesStore,
  AudioService? audio,
  List<Duration>? reconnectDelays,
}) =>
    FrequencySessionCubit(
      identityStore: identityStore ?? _FakeStore(),
      recentFrequenciesStore:
          recentFrequenciesStore ?? _FakeRecentFrequenciesStore(),
      audio: audio,
      reconnectDelays: reconnectDelays,
    );

void main() {
  group('FrequencySessionCubit', () {
    test('starts in SessionBooting', () {
      final cubit = _makeCubit();
      expect(cubit.state, isA<SessionBooting>());
    });

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap with a persisted name routes to Discovery',
      build: () => _makeCubit(
        identityStore: _FakeStore(initial: 'Maya'),
      ),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [const SessionDiscovery(myName: 'Maya')],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap without a persisted name routes to Onboarding',
      build: () => _makeCubit(),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [const SessionOnboarding()],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap falls through to Onboarding when the store throws',
      build: () => _makeCubit(
        identityStore: _FakeStore()..throwOnGet = true,
      ),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [const SessionOnboarding()],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'completeOnboarding persists and advances to Discovery',
      build: () => _makeCubit(),
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
      build: () => _makeCubit(
        identityStore: _FakeStore()..throwOnSet = true,
      ),
      seed: () => const SessionOnboarding(),
      act: (cubit) => cubit.completeOnboarding('Sam'),
      expect: () => [const SessionDiscovery(myName: 'Sam')],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'rename in Discovery updates the name in place',
      build: () => _makeCubit(
        identityStore: _FakeStore(initial: 'Maya'),
      ),
      seed: () => const SessionDiscovery(myName: 'Maya'),
      act: (cubit) => cubit.rename('Maya R.'),
      expect: () => [const SessionDiscovery(myName: 'Maya R.')],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'rename still updates name when persistence throws',
      build: () => _makeCubit(
        identityStore: _FakeStore(initial: 'Maya')..throwOnSet = true,
      ),
      seed: () => const SessionDiscovery(myName: 'Maya'),
      act: (cubit) => cubit.rename('Maya R.'),
      expect: () => [const SessionDiscovery(myName: 'Maya R.')],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'rename in Room preserves freq + host role',
      build: () => _makeCubit(),
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
      build: () => _makeCubit(),
      seed: () => const SessionOnboarding(),
      act: (cubit) => cubit.rename('Sam'),
      expect: () => const <FrequencySessionState>[],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'joinRoom from Discovery enters the Room with freq + host flag',
      build: () => _makeCubit(),
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
      build: () => _makeCubit(),
      seed: () => const SessionOnboarding(),
      act: (cubit) => cubit.joinRoom(freq: '104.3', isHost: true),
      expect: () => const <FrequencySessionState>[],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'joinRoom as guest threads MAC + sessionUuidLow8 onto SessionRoom',
      // The GATT-client transport (issue #43) reads these off SessionRoom
      // to dial the host. They have to survive the Discovery → Room
      // transition or the guest has nothing to connect to.
      build: () => _makeCubit(),
      seed: () => const SessionDiscovery(myName: 'Maya'),
      act: (cubit) => cubit.joinRoom(
        freq: '104.3',
        isHost: false,
        macAddress: 'AA:BB:CC:DD:EE:FF',
        sessionUuidLow8: '0011223344556677',
      ),
      expect: () => [
        const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: false,
          macAddress: 'AA:BB:CC:DD:EE:FF',
          sessionUuidLow8: '0011223344556677',
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'joinRoom as host drops MAC + sessionUuidLow8 even if accidentally passed',
      // The local user IS the host on this path, so a remote MAC would be
      // meaningless. We strip it defensively rather than trusting callers
      // to omit it — keeps SessionRoom's invariant clean for the
      // GATT-client issue's "if mac != null, dial it" branch.
      build: () => _makeCubit(),
      seed: () => const SessionDiscovery(myName: 'Maya'),
      act: (cubit) => cubit.joinRoom(
        freq: '104.3',
        isHost: true,
        macAddress: 'AA:BB:CC:DD:EE:FF',
        sessionUuidLow8: '0011223344556677',
      ),
      expect: () => [
        const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: true,
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'leaveRoom drops back to Discovery with the prior name',
      build: () => _makeCubit(),
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
      build: () => _makeCubit(),
      seed: () => const SessionDiscovery(myName: 'Maya'),
      act: (cubit) => cubit.leaveRoom(),
      expect: () => const <FrequencySessionState>[],
    );

    // ── Recent-frequencies persistence ─────────────────────────────────

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap surfaces the persisted recent-frequencies list on Discovery',
      build: () => _makeCubit(
        identityStore: _FakeStore(initial: 'Maya'),
        recentFrequenciesStore: _FakeRecentFrequenciesStore(
          initial: const ['100.1', '92.4'],
        ),
      ),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [
        const SessionDiscovery(
          myName: 'Maya',
          recentHostedFrequencies: ['100.1', '92.4'],
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap with no persisted name does not read recent frequencies',
      // No name → Onboarding; the store hasn't been used by the user yet,
      // so reading it would just be wasted I/O on a fresh install.
      build: () => _makeCubit(
        recentFrequenciesStore: _FakeRecentFrequenciesStore()..throwOnGet = true,
      ),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [const SessionOnboarding()],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap tolerates a recent-frequencies read failure',
      // Name reads fine, recent-freqs read throws — Discovery should
      // still land, with an empty list, instead of stranding the user
      // in Booting.
      build: () => _makeCubit(
        identityStore: _FakeStore(initial: 'Maya'),
        recentFrequenciesStore: _FakeRecentFrequenciesStore()..throwOnGet = true,
      ),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [const SessionDiscovery(myName: 'Maya')],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'completeOnboarding loads recent frequencies into Discovery',
      build: () => _makeCubit(
        recentFrequenciesStore: _FakeRecentFrequenciesStore(
          initial: const ['92.4'],
        ),
      ),
      seed: () => const SessionOnboarding(),
      act: (cubit) => cubit.completeOnboarding('Devon'),
      expect: () => [
        const SessionDiscovery(
          myName: 'Devon',
          recentHostedFrequencies: ['92.4'],
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'rename in Discovery preserves the recent-frequencies list',
      // Re-reading on every rename would be wasted I/O and would briefly
      // flicker the section if persistence is slow — the loaded list
      // should pass through unchanged.
      build: () => _makeCubit(
        identityStore: _FakeStore(initial: 'Maya'),
      ),
      seed: () => const SessionDiscovery(
        myName: 'Maya',
        recentHostedFrequencies: ['100.1', '92.4'],
      ),
      act: (cubit) => cubit.rename('Maya R.'),
      expect: () => [
        const SessionDiscovery(
          myName: 'Maya R.',
          recentHostedFrequencies: ['100.1', '92.4'],
        ),
      ],
    );

    test(
      'joinRoom as host records the freq in the recent-frequencies store',
      () async {
        final recent = _FakeRecentFrequenciesStore();
        final cubit = _makeCubit(recentFrequenciesStore: recent);
        cubit.emit(const SessionDiscovery(myName: 'Maya'));

        await cubit.joinRoom(freq: '104.3', isHost: true);
        // Let the fire-and-forget record() complete.
        await Future<void>.delayed(Duration.zero);

        expect(recent.recordCalls, 1);
        expect(await recent.getRecent(), ['104.3']);

        await cubit.close();
      },
    );

    test(
      'joinRoom as guest does NOT record the freq',
      () async {
        // Guest-side joins reflect "I tuned in to someone else's channel"
        // — those don't belong in *my* recent-hosted list.
        final recent = _FakeRecentFrequenciesStore();
        final cubit = _makeCubit(recentFrequenciesStore: recent);
        cubit.emit(const SessionDiscovery(myName: 'Maya'));

        await cubit.joinRoom(freq: '104.3', isHost: false);
        await Future<void>.delayed(Duration.zero);

        expect(recent.recordCalls, 0);

        await cubit.close();
      },
    );

    test(
      'joinRoom as host swallows record() failures',
      () async {
        // The user has already committed to entering the room; a disk
        // hiccup must not bubble up as an unhandled async error or
        // block the state transition.
        final recent = _FakeRecentFrequenciesStore()..throwOnRecord = true;
        final cubit = _makeCubit(recentFrequenciesStore: recent);
        cubit.emit(const SessionDiscovery(myName: 'Maya'));

        await expectLater(
          cubit.joinRoom(freq: '104.3', isHost: true),
          completes,
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state, isA<SessionRoom>());

        await cubit.close();
      },
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'leaveRoom re-reads recent frequencies so a just-hosted freq is at the top',
      build: () {
        // Pre-seed the store with '104.3' to model the freq the user
        // just hosted having been recorded during joinRoom.
        return _makeCubit(
          recentFrequenciesStore: _FakeRecentFrequenciesStore(
            initial: const ['104.3', '92.4'],
          ),
        );
      },
      seed: () => const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: true,
      ),
      act: (cubit) => cubit.leaveRoom(),
      expect: () => [
        const SessionDiscovery(
          myName: 'Maya',
          recentHostedFrequencies: ['104.3', '92.4'],
        ),
      ],
    );

    // ── Wire-protocol surface ──────────────────────────────────────────

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'applyJoinAccepted lands roster + hostPeerId + mediaState on the room',
      build: () => _makeCubit(),
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
      build: () => _makeCubit(),
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
      build: () => _makeCubit(),
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
      final cubit = _makeCubit();
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
      final cubit = _makeCubit();
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
        final cubit = _makeCubit();
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
      final cubit = _makeCubit();
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
      final cubit = _makeCubit(identityStore: store);
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
      final cubit = _makeCubit(identityStore: store);
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
      final cubit = _makeCubit();
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
      final cubit = _makeCubit();
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
      build: () => _makeCubit(),
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

  // ── Reconnect / ConnectionPhase ───────────────────────────────────────

  group('notifyDrop / ConnectionPhase', () {
    late AudioService audio;
    // The mock handler returns values pushed here; empty = return false.
    final List<bool> connectQueue = [];
    // Completer to block the first connectDevice call so we can inspect
    // intermediate state.
    Completer<bool>? blockFirst;

    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    setUp(() {
      audio = AudioService();
      connectQueue.clear();
      blockFirst = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.elodin.walkie_talkie/audio'),
        (MethodCall call) async {
          if (call.method == 'connectDevice') {
            final blocker = blockFirst;
            if (blocker != null) {
              blockFirst = null;
              return blocker.future;
            }
            if (connectQueue.isEmpty) return false;
            return connectQueue.removeAt(0);
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.elodin.walkie_talkie/audio'),
        null,
      );
    });

    test('notifyDrop without audio injected is a no-op', () async {
      final cubit = _makeCubit(
        reconnectDelays: _testReconnectDelays,
      ); // no audio
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
        macAddress: 'AA:BB:CC:DD:EE:FF',
      ));

      await cubit.notifyDrop(macAddress: 'AA:BB:CC:DD:EE:FF');

      expect(
        (cubit.state as SessionRoom).connectionPhase,
        ConnectionPhase.online,
      );
      await cubit.close();
    });

    test('notifyDrop on host room is a no-op', () async {
      final cubit = _makeCubit(
        audio: audio,
        reconnectDelays: _testReconnectDelays,
      );
      cubit.emit(const SessionRoom(
        myName: 'Devon',
        roomFreq: '104.3',
        roomIsHost: true,
      ));

      await cubit.notifyDrop(macAddress: 'AA:BB:CC:DD:EE:FF');

      expect(
        (cubit.state as SessionRoom).connectionPhase,
        ConnectionPhase.online,
      );
      await cubit.close();
    });

    test('notifyDrop transitions state to reconnecting', () async {
      // Block the first connectDevice so we can observe the intermediate state.
      final blocker = Completer<bool>();
      blockFirst = blocker;

      final cubit = _makeCubit(
        audio: audio,
        reconnectDelays: _testReconnectDelays,
      );
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
        macAddress: 'AA:BB:CC:DD:EE:FF',
      ));

      final dropFuture = cubit.notifyDrop(macAddress: 'AA:BB:CC:DD:EE:FF');

      // Yield to let the cubit emit reconnecting before connectDevice resolves.
      await Future<void>.delayed(Duration.zero);

      expect(
        (cubit.state as SessionRoom).connectionPhase,
        ConnectionPhase.reconnecting,
      );

      // Let the connection succeed and allow the cubit to finish.
      blocker.complete(true);
      await dropFuture;

      await cubit.close();
    });

    test('notifyDrop while already reconnecting is a no-op', () async {
      final blocker = Completer<bool>();
      blockFirst = blocker;

      final cubit = _makeCubit(
        audio: audio,
        reconnectDelays: _testReconnectDelays,
      );
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
      ));

      final first = cubit.notifyDrop(macAddress: 'AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero); // let it emit reconnecting

      expect(
        (cubit.state as SessionRoom).connectionPhase,
        ConnectionPhase.reconnecting,
      );

      // Second call while already reconnecting — state must not change.
      await cubit.notifyDrop(macAddress: 'AA:BB:CC:DD:EE:FF');
      expect(
        (cubit.state as SessionRoom).connectionPhase,
        ConnectionPhase.reconnecting,
      );

      blocker.complete(true);
      await first;
      await cubit.close();
    });

    test('applyJoinAccepted resets connectionPhase to online', () async {
      final cubit = _makeCubit(
        audio: audio,
        reconnectDelays: _testReconnectDelays,
      );
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
        connectionPhase: ConnectionPhase.reconnecting,
      ));

      cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        hostPeerId: 'p-host',
        roster: const [],
      ));

      expect(
        (cubit.state as SessionRoom).connectionPhase,
        ConnectionPhase.online,
      );
      await cubit.close();
    });

    test(
      'applyJoinAccepted mid-reconnect does not trigger spurious leaveRoom',
      () async {
        // Scenario: reconnect attempt is running; the native BLE stack
        // re-establishes the link and the host sends JoinAccepted before
        // attempt() returns. That causes attempt() to return false (cancel
        // propagates). The cubit must NOT treat this as a failure.
        final blocker = Completer<bool>();
        blockFirst = blocker;

        final cubit = _makeCubit(
          audio: audio,
          reconnectDelays: _testReconnectDelays,
        );
        cubit.emit(const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: false,
        ));

        final dropFuture = cubit.notifyDrop(macAddress: 'AA:BB:CC:DD:EE:FF');
        await Future<void>.delayed(Duration.zero); // enter reconnecting

        // Host JoinAccepted arrives — cancels the controller and sets online.
        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [],
        ));

        // Let the blocked connectDevice resolve with false (the cancel signal
        // will override it anyway, but the mock needs to settle).
        blocker.complete(false);
        await dropFuture;

        // State must remain SessionRoom(online), not Discovery.
        expect(cubit.state, isA<SessionRoom>());
        expect(
          (cubit.state as SessionRoom).connectionPhase,
          ConnectionPhase.online,
        );
        await cubit.close();
      },
    );

    test('leaveRoom() during reconnect cancels the controller', () async {
      final blocker = Completer<bool>();
      blockFirst = blocker;

      final cubit = _makeCubit(
        audio: audio,
        reconnectDelays: _testReconnectDelays,
      );
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
      ));

      final dropFuture = cubit.notifyDrop(macAddress: 'AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero); // enter reconnecting

      // User manually leaves — must cancel the reconnect controller.
      final leaveFuture = cubit.leaveRoom();
      blocker.complete(false); // unblock so futures settle
      await Future.wait([dropFuture, leaveFuture]);

      // Should be in Discovery, not stuck in reconnecting.
      expect(cubit.state, isA<SessionDiscovery>());
      await cubit.close();
    });

    test('notifyDrop drops to Discovery when all retries fail', () async {
      // connectQueue empty → mock always returns false.
      final cubit = _makeCubit(
        audio: audio,
        reconnectDelays: _testReconnectDelays,
      );
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
        macAddress: 'AA:BB:CC:DD:EE:FF',
      ));

      await cubit.notifyDrop(macAddress: 'AA:BB:CC:DD:EE:FF');

      expect(cubit.state, isA<SessionDiscovery>());
      await cubit.close();
    });

    test('close() during reconnect does not throw', () async {
      final blocker = Completer<bool>();
      blockFirst = blocker;

      final cubit = _makeCubit(
        audio: audio,
        reconnectDelays: _testReconnectDelays,
      );
      cubit.emit(const SessionRoom(
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: false,
      ));

      final dropFuture = cubit.notifyDrop(macAddress: 'AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero); // enter reconnecting

      await cubit.close();
      blocker.complete(false);
      await expectLater(dropFuture, completes);
    });
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
