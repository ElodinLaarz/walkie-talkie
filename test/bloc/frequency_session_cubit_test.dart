import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/bloc/frequency_session_cubit.dart';
import 'package:walkie_talkie/bloc/frequency_session_state.dart';
import 'package:walkie_talkie/protocol/framing.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/protocol/peer.dart';
import 'package:walkie_talkie/services/audio_service.dart';
import 'package:walkie_talkie/services/ble_control_transport.dart';
import 'package:walkie_talkie/services/heartbeat_scheduler.dart';
import 'package:walkie_talkie/services/identity_store.dart';
import 'package:walkie_talkie/services/permission_watcher.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';
import 'package:walkie_talkie/services/signal_reporter.dart';
import 'package:walkie_talkie/services/weak_signal_detector.dart';

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
    if (_entries.length > RecentFrequenciesStore.maxEntries) {
      _entries.removeRange(
        RecentFrequenciesStore.maxEntries,
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

/// Deterministic UUID whose low 12 bits map to mhzDisplay '104.3' via
/// `FrequencySession`'s 880 + (low12 % 200) tenths formula
/// (low 3 nibbles = 0x0a3 = 163; 880 + 163 = 1043 → "104.3"). Pinning it
/// here means existing host-path tests can keep asserting `roomFreq:
/// '104.3'` without each one having to wire up its own mint stub.
const _testHostSessionUuid = '00000000-0000-4000-8000-0000000000a3';

FrequencySessionCubit _makeCubit({
  IdentityStore? identityStore,
  RecentFrequenciesStore? recentFrequenciesStore,
  AudioService? audio,
  PermissionWatcher? permissionWatcher,
  List<Duration>? reconnectDelays,
  HeartbeatScheduler? heartbeats,
  BleControlTransport? transport,
  SignalReporter? signalReporter,
  WeakSignalDetector? weakSignalDetector,
  String Function()? mintSessionUuid,
}) =>
    FrequencySessionCubit(
      identityStore: identityStore ?? _FakeStore(),
      recentFrequenciesStore:
          recentFrequenciesStore ?? _FakeRecentFrequenciesStore(),
      audio: audio,
      permissionWatcher: permissionWatcher,
      reconnectDelays: reconnectDelays,
      heartbeats: heartbeats,
      transport: transport,
      signalReporter: signalReporter,
      weakSignalDetector: weakSignalDetector,
      mintSessionUuid: mintSessionUuid ?? (() => _testHostSessionUuid),
    );

/// Drives the cubit's permission-revoked branch under test. The default
/// [DefaultPermissionWatcher] would talk to permission_handler over a
/// MethodChannel; this fake just exposes a controller so tests can push
/// arbitrary [AppPermission] lists in deterministic order.
class _FakePermissionWatcher implements PermissionWatcher {
  final StreamController<List<AppPermission>> controller =
      StreamController<List<AppPermission>>.broadcast();

  /// Result returned by [checkNow]. Tests that exercise the boot-time
  /// revoked path set this to a non-empty list before calling [bootstrap]
  /// so the cubit's defensive checkNow at the end of bootstrap surfaces
  /// the denied state.
  List<AppPermission> checkNowResult = const [];

  int checkNowCalls = 0;
  bool disposed = false;

  /// Push a missing list onto the watch stream.
  void push(List<AppPermission> missing) => controller.add(missing);

  @override
  Stream<List<AppPermission>> watch() => controller.stream;

  @override
  Future<List<AppPermission>> checkNow() async {
    checkNowCalls++;
    return checkNowResult;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await controller.close();
  }
}

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
      'joinRoom from Discovery enters the Room with derived freq, host flag, '
      'and a self-seeded roster',
      // Host bootstrap: minted UUID drives roomFreq via the same low-12-bit
      // mapping guests use, hostPeerId is pinned to the local peerId, and
      // the roster carries a single entry — the local user.
      build: () => _makeCubit(),
      seed: () => const SessionDiscovery(myName: 'Maya'),
      act: (cubit) => cubit.joinRoom(isHost: true),
      expect: () => [
        const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: true,
          hostPeerId: 'fake-peer-id',
          roster: [
            ProtocolPeer(peerId: 'fake-peer-id', displayName: 'Maya'),
          ],
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'joinRoom outside Discovery is a no-op',
      build: () => _makeCubit(),
      seed: () => const SessionOnboarding(),
      act: (cubit) => cubit.joinRoom(isHost: true),
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
        isHost: true,
        freq: '104.3',
        macAddress: 'AA:BB:CC:DD:EE:FF',
        sessionUuidLow8: '0011223344556677',
      ),
      expect: () => [
        const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: true,
          hostPeerId: 'fake-peer-id',
          roster: [
            ProtocolPeer(peerId: 'fake-peer-id', displayName: 'Maya'),
          ],
        ),
      ],
    );

    test(
      'joinRoom as host derives roomFreq from the freshly-minted sessionUuid',
      () async {
        // Decouple the test's mhz check from any specific UUID by minting
        // a different one and asserting the derived value matches the same
        // formula `FrequencySession.mhzDisplay` uses.
        // Low 3 nibbles = 0x123 = 291; 880 + (291 % 200) = 880 + 91 = 971
        // → '97.1'.
        const sessionUuid = '11111111-1111-4111-8111-111111111123';
        final cubit = _makeCubit(mintSessionUuid: () => sessionUuid);
        cubit.emit(const SessionDiscovery(myName: 'Maya'));

        await cubit.joinRoom(isHost: true);
        // Let the bootstrap's async peerId resolution settle.
        await Future<void>.delayed(Duration.zero);

        final room = cubit.state as SessionRoom;
        expect(room.roomFreq, '97.1');
        expect(room.hostPeerId, 'fake-peer-id');
        expect(room.roster, hasLength(1));
        expect(room.roster.single.peerId, 'fake-peer-id');
        expect(room.roster.single.displayName, 'Maya');

        await cubit.close();
      },
    );

    test(
      'joinRoom as host calls startAdvertising and startGattServer on audio '
      'with the minted sessionUuid + display name',
      () async {
        // Per issue #39's acceptance: a unit test verifies the host
        // bootstrap calls into the audio service with the right args. We
        // intercept the underlying MethodChannel rather than mocking the
        // service so this test stays anchored on the contract callers
        // depend on (the platform method names + arg map).
        TestWidgetsFlutterBinding.ensureInitialized();
        const channel = MethodChannel('com.elodin.walkie_talkie/audio');
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          // Both methods nominally return bool on the native side.
          return true;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        const sessionUuid = '00000000-0000-4000-8000-0000000000a3';
        final cubit = _makeCubit(
          audio: AudioService(),
          mintSessionUuid: () => sessionUuid,
        );
        cubit.emit(const SessionDiscovery(myName: 'Maya'));

        await cubit.joinRoom(isHost: true);
        // The cubit fires both calls unawaited; let the event loop drain.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        final advertise = calls.firstWhere((c) => c.method == 'startAdvertising');
        expect(advertise.arguments, {
          'sessionUuid': sessionUuid,
          'displayName': 'Maya',
        });
        expect(
          calls.where((c) => c.method == 'startGattServer'),
          hasLength(1),
        );

        await cubit.close();
      },
    );

    test(
      'joinRoom as host without an audio service still self-seeds the room',
      () async {
        // The native bootstrap is best-effort; without audio injected we
        // should still emit a host SessionRoom so the UI advances. The
        // cubit constructor allows audio == null for tests / loopback
        // builds; this guards that path.
        final cubit = _makeCubit(); // no audio
        cubit.emit(const SessionDiscovery(myName: 'Maya'));

        await cubit.joinRoom(isHost: true);
        await Future<void>.delayed(Duration.zero);

        final room = cubit.state as SessionRoom;
        expect(room.roomIsHost, isTrue);
        expect(room.hostPeerId, 'fake-peer-id');
        expect(room.roster.single.peerId, 'fake-peer-id');

        await cubit.close();
      },
    );

    test(
      'joinRoom as host bails out when peerId resolution fails — '
      'no broken room is emitted',
      () async {
        // hostPeerId is load-bearing for the protocol's message
        // attribution; seeding a room without it would just put the user
        // into a broken state they'd have to leave manually. Stay on
        // Discovery so the UI can retry.
        final store = _FakeStore(initial: 'Maya')..throwOnGetPeerId = true;
        final cubit = _makeCubit(identityStore: store);
        cubit.emit(const SessionDiscovery(myName: 'Maya'));

        await cubit.joinRoom(isHost: true);
        await Future<void>.delayed(Duration.zero);

        expect(cubit.state, isA<SessionDiscovery>());
        await cubit.close();
      },
    );

    test(
      'leaveRoom on a host room calls stopAdvertising + stopGattServer',
      () async {
        // Symmetric teardown: the host kicks off advertising + GATT in
        // joinRoom, so backing out of the room must close both surfaces.
        // Otherwise nearby phones keep seeing a phantom session.
        TestWidgetsFlutterBinding.ensureInitialized();
        const channel = MethodChannel('com.elodin.walkie_talkie/audio');
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        final cubit = _makeCubit(audio: AudioService());
        cubit.emit(const SessionDiscovery(myName: 'Maya'));

        await cubit.joinRoom(isHost: true);
        await Future<void>.delayed(Duration.zero);

        calls.clear();
        await cubit.leaveRoom();
        await Future<void>.delayed(Duration.zero);

        final methods = calls.map((c) => c.method).toSet();
        expect(methods, containsAll(<String>{'stopAdvertising', 'stopGattServer'}));

        await cubit.close();
      },
    );

    test(
      'leaveRoom on a guest room does NOT call host-side stop methods',
      () async {
        // Guests don't own the advertiser / GATT server, so leaving a
        // guest-role room mustn't tear down a (possibly co-hosted) room
        // on the same device.
        TestWidgetsFlutterBinding.ensureInitialized();
        const channel = MethodChannel('com.elodin.walkie_talkie/audio');
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        final cubit = _makeCubit(audio: AudioService());
        cubit.emit(const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: false,
        ));

        calls.clear();
        await cubit.leaveRoom();
        await Future<void>.delayed(Duration.zero);

        final methods = calls.map((c) => c.method).toSet();
        expect(methods, isNot(contains('stopAdvertising')));
        expect(methods, isNot(contains('stopGattServer')));

        await cubit.close();
      },
    );

    test(
      'close() while in a host room tears down host BLE surfaces',
      () async {
        // Same teardown as leaveRoom — without it, killing the cubit
        // mid-session leaks the advertiser + GATT server.
        TestWidgetsFlutterBinding.ensureInitialized();
        const channel = MethodChannel('com.elodin.walkie_talkie/audio');
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        final cubit = _makeCubit(audio: AudioService());
        cubit.emit(const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: true,
        ));

        calls.clear();
        await cubit.close();
        await Future<void>.delayed(Duration.zero);

        final methods = calls.map((c) => c.method).toSet();
        expect(methods, containsAll(<String>{'stopAdvertising', 'stopGattServer'}));
      },
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

  // ── Heartbeats / dirty-disconnect ──────────────────────────────────────

  group('Heartbeats', () {
    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    /// Builds a transport whose `send` writes to [outbox] without touching
    /// MethodChannels. The incoming stream is exposed via [inbox] so tests
    /// can deliver synthesised wire messages.
    ({BleControlTransport transport, List<Uint8List> outbox, StreamController<({String endpointId, Uint8List bytes})> inbox})
        makeTestTransport() {
      final outbox = <Uint8List>[];
      final inbox = StreamController<({String endpointId, Uint8List bytes})>.broadcast();
      final transport = BleControlTransport.forTest(
        controlBytes: inbox.stream,
        writeBytes: (bytes) async {
          outbox.add(bytes);
        },
      );
      return (transport: transport, outbox: outbox, inbox: inbox);
    }

    test(
      'joinRoom starts the heartbeat scheduler when a transport is wired; '
      'leaveRoom stops it',
      () async {
        final t = makeTestTransport();
        final scheduler = HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
          missThreshold: const Duration(seconds: 60),
        );
        final cubit = _makeCubit(
          heartbeats: scheduler,
          transport: t.transport,
        );
        cubit.emit(const SessionDiscovery(myName: 'Maya'));

        expect(scheduler.isRunning, isFalse);
        await cubit.joinRoom(freq: '104.3', isHost: true);
        expect(scheduler.isRunning, isTrue);

        await cubit.leaveRoom();
        expect(scheduler.isRunning, isFalse);

        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test(
      'joinRoom without a transport does NOT start the heartbeat scheduler',
      () async {
        // The wire-less loopback mode is the path widget tests use, and
        // a periodic timer outliving the test triggers Flutter's
        // "Timer is still pending" assertion. Heartbeats are useless
        // without a transport (no wire to ping) so we leave the scheduler
        // dormant.
        final scheduler = HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
        );
        final cubit = _makeCubit(heartbeats: scheduler);
        cubit.emit(const SessionDiscovery(myName: 'Maya'));
        await cubit.joinRoom(freq: '104.3', isHost: true);

        expect(scheduler.isRunning, isFalse);
        await cubit.close();
      },
    );

    test('cubit.close() stops the heartbeat scheduler', () async {
      final t = makeTestTransport();
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(hours: 1),
      );
      final cubit = _makeCubit(
        heartbeats: scheduler,
        transport: t.transport,
      );
      cubit.emit(const SessionDiscovery(myName: 'Maya'));
      await cubit.joinRoom(freq: '104.3', isHost: true);
      expect(scheduler.isRunning, isTrue);

      await cubit.close();
      expect(scheduler.isRunning, isFalse);
      await t.inbox.close();
      t.transport.dispose();
    });

    test(
      'inbound non-Heartbeat messages also refresh the watermark',
      () async {
        // The cubit treats any inbound activity as a sign-of-life so an
        // actively-chatty peer can't be declared lost on a delayed
        // dedicated ping. Pin that contract — `notePingFrom` must run
        // for non-`Heartbeat` kinds too.
        final t = makeTestTransport();
        final scheduler = HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
        );
        final cubit = _makeCubit(
          heartbeats: scheduler,
          transport: t.transport,
        );
        await cubit.bootstrap();
        cubit.emit(const SessionDiscovery(myName: 'Devon'));
        await cubit.joinRoom(freq: '104.3', isHost: true);

        final updateJson = const RosterUpdate(
          peerId: 'p-guest',
          seq: 1,
          atMs: 1000,
          roster: [],
        ).encode();
        for (final frag in encodeFragments(updateJson)) {
          t.inbox.add((endpointId: 'AA:BB', bytes: frag));
        }
        await Future<void>.delayed(Duration.zero);

        expect(scheduler.lastSeen, contains('p-guest'));

        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test(
      'incoming Heartbeat refreshes the watermark for the sender',
      () async {
        final t = makeTestTransport();
        final scheduler = HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
        );
        final cubit = _makeCubit(
          heartbeats: scheduler,
          transport: t.transport,
        );
        await cubit.bootstrap(); // wires the transport.incoming subscription
        cubit.emit(const SessionDiscovery(myName: 'Maya'));
        await cubit.joinRoom(freq: '104.3', isHost: true);

        // Inject a Heartbeat from a guest peer — frame it through
        // encodeFragments so the inbox receives the same shape it would
        // see from the native GATT layer.
        final pingJson = const Heartbeat(
          peerId: 'p-guest',
          seq: 1,
          atMs: 1000,
        ).encode();
        for (final frag in encodeFragments(pingJson)) {
          t.inbox.add((endpointId: 'AA:BB', bytes: frag));
        }
        await Future<void>.delayed(Duration.zero);

        expect(scheduler.lastSeen, contains('p-guest'));

        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test(
      'host: peer-lost drops the peer from the roster and broadcasts RosterUpdate',
      () async {
        final t = makeTestTransport();
        // Use a deterministic clock so debugTick() can drive the silence test.
        var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
        final scheduler = HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
          missThreshold: const Duration(seconds: 15),
          clock: () => fakeNow,
        );
        final cubit = _makeCubit(
          heartbeats: scheduler,
          transport: t.transport,
        );
        cubit.emit(const SessionDiscovery(myName: 'Devon'));
        await cubit.joinRoom(freq: '104.3', isHost: true);
        // Seed the host's roster (would normally come from JoinAccepted /
        // RosterUpdate flow). This is the snapshot the lost-peer handler
        // edits down.
        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [
            ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
            ProtocolPeer(peerId: 'p-stale', displayName: 'Stale'),
            ProtocolPeer(peerId: 'p-fresh', displayName: 'Fresh'),
          ],
        ));

        // p-stale pinged at t=0; p-fresh pings at t=14. Tick at t=20 → only
        // p-stale should be declared lost (20s > 15s threshold).
        scheduler.notePingFrom('p-stale');
        fakeNow = fakeNow.add(const Duration(seconds: 14));
        scheduler.notePingFrom('p-fresh');
        fakeNow = fakeNow.add(const Duration(seconds: 6));
        scheduler.debugTick();
        await Future<void>.delayed(Duration.zero); // settle the broadcast

        final room = cubit.state as SessionRoom;
        expect(
          room.roster.map((p) => p.peerId),
          unorderedEquals(['p-host', 'p-fresh']),
          reason: 'p-stale crossed the silence threshold',
        );

        // The cubit should have written a RosterUpdate to the wire so the
        // remaining guests learn of the drop. We don't pin the exact framing
        // here (other tests cover encodeFragments) — just check that *some*
        // outbound bytes contain "roster_update".
        final wire = t.outbox.map((b) => String.fromCharCodes(b)).join();
        expect(wire, contains('roster_update'));
        expect(wire, contains('p-fresh'));
        expect(wire, isNot(contains('p-stale')));

        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test(
      'guest: host-lost transitions the room to reconnecting via notifyDrop',
      () async {
        final t = makeTestTransport();
        // notifyDrop needs an AudioService; keep it on a non-existent MAC
        // and let the (zero-delay) attempts fail.
        const channel = MethodChannel('com.elodin.walkie_talkie/audio');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async => false);
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
        final scheduler = HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
          missThreshold: const Duration(seconds: 15),
          clock: () => fakeNow,
        );
        final audio = AudioService();
        final cubit = _makeCubit(
          heartbeats: scheduler,
          transport: t.transport,
          audio: audio,
          reconnectDelays: _testReconnectDelays,
        );
        cubit.emit(const SessionDiscovery(myName: 'Maya'));
        await cubit.joinRoom(
          freq: '104.3',
          isHost: false,
          macAddress: 'AA:BB:CC:DD:EE:FF',
        );
        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [ProtocolPeer(peerId: 'p-host', displayName: 'Devon')],
        ));

        scheduler.notePingFrom('p-host');
        fakeNow = fakeNow.add(const Duration(seconds: 20));
        scheduler.debugTick();
        // Yield once so notifyDrop emits ConnectionPhase.reconnecting before
        // the (zero-delay) attempts exhaust.
        await Future<void>.delayed(Duration.zero);

        // notifyDrop has been entered: state must be SessionRoom with
        // reconnecting phase, OR the loop has already exhausted to Discovery.
        final s = cubit.state;
        if (s is SessionRoom) {
          expect(s.connectionPhase, isNot(ConnectionPhase.online));
        } else {
          expect(s, isA<SessionDiscovery>());
        }

        // Drain any pending reconnect work before closing so background
        // futures don't outlive the test.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test(
      'guest: a non-host peer-lost is ignored',
      () async {
        final t = makeTestTransport();
        var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
        final scheduler = HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
          missThreshold: const Duration(seconds: 15),
          clock: () => fakeNow,
        );
        final cubit = _makeCubit(
          heartbeats: scheduler,
          transport: t.transport,
        );
        cubit.emit(const SessionDiscovery(myName: 'Maya'));
        await cubit.joinRoom(
          freq: '104.3',
          isHost: false,
          macAddress: 'AA:BB:CC:DD:EE:FF',
        );
        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [
            ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
            ProtocolPeer(peerId: 'p-other', displayName: 'Other'),
          ],
        ));

        // A non-host peer goes silent. The guest doesn't know about other
        // guests (star topology — that's the host's bookkeeping), so it
        // must NOT call notifyDrop / leaveRoom on a stale watermark.
        scheduler.notePingFrom('p-other');
        fakeNow = fakeNow.add(const Duration(seconds: 30));
        scheduler.debugTick();

        final s = cubit.state;
        expect(s, isA<SessionRoom>());
        expect((s as SessionRoom).connectionPhase, ConnectionPhase.online);

        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test(
      'leaveRoom wipes transport idempotency state for every peer',
      () async {
        // Held-over watermarks across a leave + re-join would silently
        // swallow `seq=1` of the next session per protocol — exercise the
        // forgetAllPeers cleanup end-to-end.
        final t = makeTestTransport();
        final scheduler = HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
        );
        final cubit = _makeCubit(
          heartbeats: scheduler,
          transport: t.transport,
        );
        await cubit.bootstrap();
        cubit.emit(const SessionDiscovery(myName: 'Devon'));
        await cubit.joinRoom(freq: '104.3', isHost: true);

        // Push two peers' messages to advance the transport's per-peer
        // sequence watermarks past 1.
        for (final peer in const ['p-a', 'p-b']) {
          for (var seq = 1; seq <= 3; seq++) {
            for (final frag in encodeFragments(
                Heartbeat(peerId: peer, seq: seq, atMs: 0).encode())) {
              t.inbox.add((endpointId: peer, bytes: frag));
            }
          }
        }
        await Future<void>.delayed(Duration.zero);

        await cubit.leaveRoom();

        // Re-emit Discovery so we can synthesise a re-join behaviour
        // through the transport.
        cubit.emit(const SessionDiscovery(myName: 'Devon'));
        await cubit.joinRoom(freq: '104.3', isHost: true);

        // After leaveRoom + new joinRoom, a fresh `seq=1` from p-a must
        // not be filtered as a duplicate. We piggyback on the watermark
        // refresh: notePingFrom doesn't drive the sequence filter, so the
        // best signal here is whether the inbound message is dispatched
        // through to `_heartbeats.notePingFrom` (only happens on accept).
        for (final frag in encodeFragments(
            const Heartbeat(peerId: 'p-a', seq: 1, atMs: 0).encode())) {
          t.inbox.add((endpointId: 'p-a', bytes: frag));
        }
        await Future<void>.delayed(Duration.zero);
        expect(scheduler.lastSeen, contains('p-a'),
            reason: 'fresh seq=1 must pass the cleared sequence filter');

        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test(
      'guest host-lost forgets the host on the transport before reconnect',
      () async {
        // Per Gemini review: the fresh JoinAccepted after reconnect resets
        // seq to 1, so the transport's stale watermark from the dying
        // session must be cleared — otherwise the new session's first
        // messages get silently swallowed.
        const channel = MethodChannel('com.elodin.walkie_talkie/audio');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async => false);
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        final t = makeTestTransport();
        var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
        final scheduler = HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
          missThreshold: const Duration(seconds: 15),
          clock: () => fakeNow,
        );
        final cubit = _makeCubit(
          heartbeats: scheduler,
          transport: t.transport,
          audio: AudioService(),
          reconnectDelays: _testReconnectDelays,
        );
        await cubit.bootstrap();
        cubit.emit(const SessionDiscovery(myName: 'Maya'));
        await cubit.joinRoom(
          freq: '104.3',
          isHost: false,
          macAddress: 'AA:BB:CC:DD:EE:FF',
        );
        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [ProtocolPeer(peerId: 'p-host', displayName: 'Devon')],
        ));

        // Push the host's seq watermark past 1 by sending a message.
        for (final frag in encodeFragments(
            const Heartbeat(peerId: 'p-host', seq: 5, atMs: 0).encode())) {
          t.inbox.add((endpointId: 'p-host', bytes: frag));
        }
        await Future<void>.delayed(Duration.zero);

        scheduler.notePingFrom('p-host');
        fakeNow = fakeNow.add(const Duration(seconds: 16));
        scheduler.debugTick();
        // Yield once so notifyDrop fires + the host-forget runs ahead of
        // the (zero-delay) reconnect attempts.
        await Future<void>.delayed(Duration.zero);

        // After the silence detection, a fresh JoinAccepted (seq=1) for the
        // host should be accepted by the transport's filter — proving the
        // stale seq=5 watermark was cleared.
        for (final frag in encodeFragments(JoinAccepted(
                peerId: 'p-host', seq: 1, atMs: 0, hostPeerId: 'p-host',
                roster: const []).encode())) {
          t.inbox.add((endpointId: 'p-host', bytes: frag));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Drain background reconnect work before closing.
        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test('forgetPeer is wired through Leave dispatch', () async {
      final t = makeTestTransport();
      final scheduler = HeartbeatScheduler(
        pingInterval: const Duration(hours: 1),
      );
      final cubit = _makeCubit(
        heartbeats: scheduler,
        transport: t.transport,
      );
      await cubit.bootstrap();
      cubit.emit(const SessionDiscovery(myName: 'Devon'));
      await cubit.joinRoom(freq: '104.3', isHost: true);
      cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        hostPeerId: 'p-host',
        roster: const [
          ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
          ProtocolPeer(peerId: 'p-guest', displayName: 'Maya'),
        ],
      ));

      // Synthesise a Leave from p-guest delivered through the transport.
      scheduler.notePingFrom('p-guest');
      expect(scheduler.lastSeen, contains('p-guest'));

      final leaveJson = const Leave(peerId: 'p-guest', seq: 1, atMs: 0).encode();
      for (final frag in encodeFragments(leaveJson)) {
        t.inbox.add((endpointId: 'AA:BB', bytes: frag));
      }
      await Future<void>.delayed(Duration.zero);

      // Note: the dispatch first calls notePingFrom(p-guest) (any inbound
      // activity refreshes the watermark) and then forgetPeer(p-guest). The
      // net effect on the table is "removed".
      expect(scheduler.lastSeen, isNot(contains('p-guest')));

      await cubit.close();
      await t.inbox.close();
      t.transport.dispose();
    });
  });

  // ── SignalReport / weak-signal ────────────────────────────────────────

  group('SignalReport', () {
    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    /// Same harness shape as the Heartbeats group's `makeTestTransport`,
    /// duplicated here to keep the two groups independently movable.
    ({
      BleControlTransport transport,
      List<Uint8List> outbox,
      StreamController<({String endpointId, Uint8List bytes})> inbox,
    }) makeTestTransport() {
      final outbox = <Uint8List>[];
      final inbox =
          StreamController<({String endpointId, Uint8List bytes})>.broadcast();
      final transport = BleControlTransport.forTest(
        controlBytes: inbox.stream,
        writeBytes: (bytes) async {
          outbox.add(bytes);
        },
      );
      return (transport: transport, outbox: outbox, inbox: inbox);
    }

    /// Audio service backed by the test message channel — getCurrentRssi
    /// returns whatever's in [rssi] at the time of the call. Mutating the
    /// list between cubit ticks lets a test simulate signal changes.
    AudioService makeRssiAudio(List<({String peerId, int rssi})> rssi) {
      final audio = AudioService();
      const channel = MethodChannel('com.elodin.walkie_talkie/audio');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getCurrentRssi') {
          return rssi
              .map((r) => {'peerId': r.peerId, 'rssi': r.rssi})
              .toList();
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      return audio;
    }

    test(
      'guest joinRoom with audio + transport starts the SignalReporter; '
      'leaveRoom stops it',
      () async {
        final t = makeTestTransport();
        final reporter =
            SignalReporter(interval: const Duration(hours: 1));
        final cubit = _makeCubit(
          transport: t.transport,
          audio: makeRssiAudio(const []),
          signalReporter: reporter,
          // Reuse a long-interval scheduler so the heartbeat plane
          // doesn't fight the test for the foreground.
          heartbeats: HeartbeatScheduler(
            pingInterval: const Duration(hours: 1),
          ),
        );
        cubit.emit(const SessionDiscovery(myName: 'Maya'));

        expect(reporter.isRunning, isFalse);
        await cubit.joinRoom(
          freq: '104.3',
          isHost: false,
          macAddress: 'AA:BB',
        );
        expect(reporter.isRunning, isTrue);

        await cubit.leaveRoom();
        expect(reporter.isRunning, isFalse);

        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test(
      'host joinRoom does NOT start the SignalReporter (host receives only)',
      () async {
        final t = makeTestTransport();
        final reporter =
            SignalReporter(interval: const Duration(hours: 1));
        final cubit = _makeCubit(
          transport: t.transport,
          audio: makeRssiAudio(const []),
          signalReporter: reporter,
          heartbeats: HeartbeatScheduler(
            pingInterval: const Duration(hours: 1),
          ),
        );
        cubit.emit(const SessionDiscovery(myName: 'Devon'));
        await cubit.joinRoom(freq: '104.3', isHost: true);

        expect(reporter.isRunning, isFalse,
            reason: 'host receives reports rather than sending them');

        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test('guest joinRoom without audio does NOT start the SignalReporter',
        () async {
      // Without audio there's no RSSI source to sample; starting the
      // reporter would just emit empty `SignalReport`s every 10s.
      final t = makeTestTransport();
      final reporter =
          SignalReporter(interval: const Duration(hours: 1));
      final cubit = _makeCubit(
        transport: t.transport,
        signalReporter: reporter,
        heartbeats: HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
        ),
      );
      cubit.emit(const SessionDiscovery(myName: 'Maya'));
      await cubit.joinRoom(
        freq: '104.3',
        isHost: false,
        macAddress: 'AA:BB',
      );

      expect(reporter.isRunning, isFalse);
      await cubit.close();
      await t.inbox.close();
      t.transport.dispose();
    });

    test('cubit.close() stops the SignalReporter', () async {
      final t = makeTestTransport();
      final reporter =
          SignalReporter(interval: const Duration(hours: 1));
      final cubit = _makeCubit(
        transport: t.transport,
        audio: makeRssiAudio(const []),
        signalReporter: reporter,
        heartbeats: HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
        ),
      );
      cubit.emit(const SessionDiscovery(myName: 'Maya'));
      await cubit.joinRoom(
        freq: '104.3',
        isHost: false,
        macAddress: 'AA:BB',
      );
      expect(reporter.isRunning, isTrue);

      await cubit.close();
      expect(reporter.isRunning, isFalse);
      await t.inbox.close();
      t.transport.dispose();
    });

    test(
      'host with two consecutive weak inbound reports emits weakSignalEvents',
      () async {
        final t = makeTestTransport();
        final cubit = _makeCubit(
          transport: t.transport,
          heartbeats: HeartbeatScheduler(
            pingInterval: const Duration(hours: 1),
          ),
        );
        await cubit.bootstrap();
        cubit.emit(const SessionDiscovery(myName: 'Devon'));
        await cubit.joinRoom(freq: '104.3', isHost: true);
        // Host's roster needs the neighbor's peerId so the cubit can
        // resolve a display name for the toast.
        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [
            ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
            ProtocolPeer(peerId: 'p-target', displayName: 'Maya'),
          ],
        ));

        final fired = <({String peerId, String displayName})>[];
        final sub = cubit.weakSignalEvents.listen(fired.add);
        addTearDown(sub.cancel);

        // Helper: serialize and feed a SignalReport into the inbox.
        Future<void> feedReport(int seq, int rssi) async {
          final json = SignalReport(
            peerId: 'p-guest',
            seq: seq,
            atMs: seq * 1000,
            neighbors: [NeighborSignal(peerId: 'p-target', rssi: rssi)],
          ).encode();
          for (final frag in encodeFragments(json)) {
            t.inbox.add((endpointId: 'AA:BB', bytes: frag));
          }
          await Future<void>.delayed(Duration.zero);
        }

        await feedReport(1, -85);
        // One weak report — under the threshold gate, no toast yet.
        expect(fired, isEmpty);

        await feedReport(2, -90);
        // Second consecutive weak — trips. Display name resolved from
        // the roster, not the wire.
        expect(fired, hasLength(1));
        expect(fired.first.peerId, 'p-target');
        expect(fired.first.displayName, 'Maya');

        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test('host suppresses toast for a neighbor that is not in the roster',
        () async {
      // Stale or off-roster neighbor reports should be a silent drop, not
      // a toast with a generic name. The host's roster is the source of
      // truth for who's actually in the room.
      final t = makeTestTransport();
      final cubit = _makeCubit(
        transport: t.transport,
        heartbeats: HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
        ),
      );
      await cubit.bootstrap();
      cubit.emit(const SessionDiscovery(myName: 'Devon'));
      await cubit.joinRoom(freq: '104.3', isHost: true);
      cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        hostPeerId: 'p-host',
        roster: const [ProtocolPeer(peerId: 'p-host', displayName: 'Devon')],
      ));

      final fired = <({String peerId, String displayName})>[];
      final sub = cubit.weakSignalEvents.listen(fired.add);
      addTearDown(sub.cancel);

      Future<void> feedReport(int seq) async {
        final json = SignalReport(
          peerId: 'p-guest',
          seq: seq,
          atMs: seq * 1000,
          neighbors: [
            const NeighborSignal(peerId: 'p-ghost', rssi: -90),
          ],
        ).encode();
        for (final frag in encodeFragments(json)) {
          t.inbox.add((endpointId: 'AA:BB', bytes: frag));
        }
        await Future<void>.delayed(Duration.zero);
      }

      await feedReport(1);
      await feedReport(2);
      expect(fired, isEmpty,
          reason: 'p-ghost is not in the roster — drop the event');

      await cubit.close();
      await t.inbox.close();
      t.transport.dispose();
    });

    test('host ignores inbound SignalReports when local role is guest',
        () async {
      // The host-only role check guards against a misbehaving / forged
      // report from another guest leaking into the local UI on a guest
      // device. Only the host owns the toast surface.
      final t = makeTestTransport();
      final cubit = _makeCubit(
        transport: t.transport,
        heartbeats: HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
        ),
      );
      await cubit.bootstrap();
      cubit.emit(const SessionDiscovery(myName: 'Maya'));
      await cubit.joinRoom(
        freq: '104.3',
        isHost: false,
        macAddress: 'AA:BB',
      );
      cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        hostPeerId: 'p-host',
        roster: const [
          ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
          ProtocolPeer(peerId: 'p-target', displayName: 'Sam'),
        ],
      ));

      final fired = <({String peerId, String displayName})>[];
      final sub = cubit.weakSignalEvents.listen(fired.add);
      addTearDown(sub.cancel);

      Future<void> feedReport(int seq) async {
        final json = SignalReport(
          peerId: 'p-other-guest',
          seq: seq,
          atMs: seq * 1000,
          neighbors: const [NeighborSignal(peerId: 'p-target', rssi: -90)],
        ).encode();
        for (final frag in encodeFragments(json)) {
          t.inbox.add((endpointId: 'BB:CC', bytes: frag));
        }
        await Future<void>.delayed(Duration.zero);
      }

      await feedReport(1);
      await feedReport(2);
      expect(fired, isEmpty);

      await cubit.close();
      await t.inbox.close();
      t.transport.dispose();
    });

    test('weakSignalDetector is cleared on leaveRoom', () async {
      // Pre-trip a counter, leave, re-join — the detector must start
      // fresh, not inherit the prior session's "one weak report" toward
      // the next trip.
      final t = makeTestTransport();
      final cubit = _makeCubit(
        transport: t.transport,
        heartbeats: HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
        ),
      );
      await cubit.bootstrap();
      cubit.emit(const SessionDiscovery(myName: 'Devon'));
      await cubit.joinRoom(freq: '104.3', isHost: true);
      cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        hostPeerId: 'p-host',
        roster: const [
          ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
          ProtocolPeer(peerId: 'p-target', displayName: 'Maya'),
        ],
      ));

      final fired = <({String peerId, String displayName})>[];
      final sub = cubit.weakSignalEvents.listen(fired.add);
      addTearDown(sub.cancel);

      // First report — starts a counter for p-target.
      for (final frag in encodeFragments(const SignalReport(
        peerId: 'p-guest',
        seq: 1,
        atMs: 1000,
        neighbors: [NeighborSignal(peerId: 'p-target', rssi: -90)],
      ).encode())) {
        t.inbox.add((endpointId: 'AA:BB', bytes: frag));
      }
      await Future<void>.delayed(Duration.zero);

      // Leave + rejoin — counter should be wiped on leave.
      await cubit.leaveRoom();
      cubit.emit(const SessionDiscovery(myName: 'Devon'));
      await cubit.joinRoom(freq: '104.3', isHost: true);
      cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        hostPeerId: 'p-host',
        roster: const [
          ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
          ProtocolPeer(peerId: 'p-target', displayName: 'Maya'),
        ],
      ));

      // One weak report in the new session — must NOT trip if the
      // detector was cleared on leave. (If state leaked, this would be
      // the second weak in a row and would fire.)
      for (final frag in encodeFragments(const SignalReport(
        peerId: 'p-guest',
        seq: 1,
        atMs: 1000,
        neighbors: [NeighborSignal(peerId: 'p-target', rssi: -90)],
      ).encode())) {
        t.inbox.add((endpointId: 'AA:BB', bytes: frag));
      }
      await Future<void>.delayed(Duration.zero);

      expect(fired, isEmpty);

      await cubit.close();
      await t.inbox.close();
      t.transport.dispose();
    });

    test('host self-toast is suppressed for the local hostPeerId', () async {
      // A guest's report can include the host as a neighbor (the host's
      // adverts/notifications are visible to the guest, so the GATT
      // client samples its RSSI). The host shouldn't toast itself.
      final t = makeTestTransport();
      final cubit = _makeCubit(
        transport: t.transport,
        heartbeats: HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
        ),
      );
      await cubit.bootstrap();
      cubit.emit(const SessionDiscovery(myName: 'Devon'));
      await cubit.joinRoom(freq: '104.3', isHost: true);
      cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        hostPeerId: 'p-host',
        roster: const [ProtocolPeer(peerId: 'p-host', displayName: 'Devon')],
      ));

      final fired = <({String peerId, String displayName})>[];
      final sub = cubit.weakSignalEvents.listen(fired.add);
      addTearDown(sub.cancel);

      for (var seq = 1; seq <= 2; seq++) {
        for (final frag in encodeFragments(SignalReport(
          peerId: 'p-guest',
          seq: seq,
          atMs: seq * 1000,
          neighbors: const [NeighborSignal(peerId: 'p-host', rssi: -95)],
        ).encode())) {
          t.inbox.add((endpointId: 'AA:BB', bytes: frag));
        }
        await Future<void>.delayed(Duration.zero);
      }

      expect(fired, isEmpty,
          reason: 'host should not surface a toast for itself');

      await cubit.close();
      await t.inbox.close();
      t.transport.dispose();
    });
  });

  // ── Permission revocation (#57) ─────────────────────────────────────────

  group('Permission revocation', () {
    test(
      'revoke from Discovery transitions to SessionPermissionDenied',
      () async {
        final watcher = _FakePermissionWatcher();
        final cubit = _makeCubit(
          identityStore: _FakeStore(initial: 'Maya'),
          permissionWatcher: watcher,
        );
        await cubit.bootstrap(); // subscribe to watcher
        expect(cubit.state, isA<SessionDiscovery>());

        watcher.push([AppPermission.microphone]);
        await Future<void>.delayed(Duration.zero);

        final s = cubit.state;
        expect(s, isA<SessionPermissionDenied>());
        expect((s as SessionPermissionDenied).missing,
            [AppPermission.microphone]);
        expect(s.myName, 'Maya');

        await cubit.close();
        await watcher.dispose();
      },
    );

    test(
      'revoke from Room tears down BLE state and surfaces denied screen',
      () async {
        final watcher = _FakePermissionWatcher();
        final scheduler = HeartbeatScheduler(
          pingInterval: const Duration(hours: 1),
        );
        final t = (() {
          final outbox = <Uint8List>[];
          final inbox = StreamController<
              ({String endpointId, Uint8List bytes})>.broadcast();
          final transport = BleControlTransport.forTest(
            controlBytes: inbox.stream,
            writeBytes: (bytes) async {
              outbox.add(bytes);
            },
          );
          return (transport: transport, outbox: outbox, inbox: inbox);
        })();
        final cubit = _makeCubit(
          identityStore: _FakeStore(initial: 'Maya'),
          heartbeats: scheduler,
          transport: t.transport,
          permissionWatcher: watcher,
        );
        await cubit.bootstrap();
        cubit.emit(const SessionDiscovery(myName: 'Maya'));
        await cubit.joinRoom(freq: '104.3', isHost: true);
        expect(scheduler.isRunning, isTrue);

        watcher.push([
          AppPermission.microphone,
          AppPermission.bluetooth,
        ]);
        await Future<void>.delayed(Duration.zero);

        // Heartbeat scheduler must have been stopped (mirrors leaveRoom
        // cleanup) so the cubit isn't pinging an absent transport.
        expect(scheduler.isRunning, isFalse);
        final s = cubit.state;
        expect(s, isA<SessionPermissionDenied>());
        expect((s as SessionPermissionDenied).missing, [
          AppPermission.microphone,
          AppPermission.bluetooth,
        ]);
        expect(s.myName, 'Maya');

        await cubit.close();
        await watcher.dispose();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test(
      'revoke from Onboarding is ignored (onboarding owns its own flow)',
      () async {
        final watcher = _FakePermissionWatcher();
        final cubit = _makeCubit(permissionWatcher: watcher);
        await cubit.bootstrap();
        expect(cubit.state, isA<SessionOnboarding>());

        watcher.push([AppPermission.microphone]);
        await Future<void>.delayed(Duration.zero);

        // Onboarding owns its own permission flow — the cubit must not
        // yank the user out mid-grant.
        expect(cubit.state, isA<SessionOnboarding>());

        await cubit.close();
        await watcher.dispose();
      },
    );

    test(
      'recover from denied returns to Discovery with the persisted name',
      () async {
        final watcher = _FakePermissionWatcher();
        final recent = _FakeRecentFrequenciesStore(initial: const ['100.1']);
        final cubit = _makeCubit(
          identityStore: _FakeStore(initial: 'Maya'),
          recentFrequenciesStore: recent,
          permissionWatcher: watcher,
        );
        await cubit.bootstrap();
        watcher.push([AppPermission.microphone]);
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state, isA<SessionPermissionDenied>());

        // User re-grants in Settings; watcher emits empty.
        watcher.push(const []);
        await Future<void>.delayed(Duration.zero);

        final s = cubit.state;
        expect(s, isA<SessionDiscovery>());
        expect((s as SessionDiscovery).myName, 'Maya');
        expect(s.recentHostedFrequencies, ['100.1']);

        await cubit.close();
        await watcher.dispose();
      },
    );

    test(
      'recover with no display name routes back to Onboarding',
      () async {
        final watcher = _FakePermissionWatcher();
        final cubit = _makeCubit(permissionWatcher: watcher);

        // Synthesize a denied state with no captured name (the watcher fires
        // before bootstrap reads the store on a fresh install with revoked
        // perms — defensive path).
        cubit.emit(SessionPermissionDenied(
          missing: const [AppPermission.microphone],
        ));
        await cubit.bootstrap();
        // Bootstrap may have routed to Onboarding already; re-seed denied.
        cubit.emit(SessionPermissionDenied(
          missing: const [AppPermission.microphone],
        ));

        watcher.push(const []);
        await Future<void>.delayed(Duration.zero);

        expect(cubit.state, isA<SessionOnboarding>());

        await cubit.close();
        await watcher.dispose();
      },
    );

    test(
      'changing missing list while denied refreshes the screen',
      () async {
        final watcher = _FakePermissionWatcher();
        final cubit = _makeCubit(
          identityStore: _FakeStore(initial: 'Maya'),
          permissionWatcher: watcher,
        );
        await cubit.bootstrap();

        watcher.push([AppPermission.microphone, AppPermission.bluetooth]);
        await Future<void>.delayed(Duration.zero);
        expect((cubit.state as SessionPermissionDenied).missing,
            [AppPermission.microphone, AppPermission.bluetooth]);

        // User re-grants mic but bluetooth still off.
        watcher.push([AppPermission.bluetooth]);
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state, isA<SessionPermissionDenied>());
        expect((cubit.state as SessionPermissionDenied).missing,
            [AppPermission.bluetooth]);

        await cubit.close();
        await watcher.dispose();
      },
    );

    test(
      'recheckPermissions delegates to the watcher',
      () async {
        final watcher = _FakePermissionWatcher();
        final cubit = _makeCubit(permissionWatcher: watcher);
        await cubit.bootstrap();
        // bootstrap performs a defensive checkNow() at the end so an
        // initial revoked snapshot isn't dropped during Booting; let that
        // call settle before counting recheckPermissions.
        await Future<void>.delayed(Duration.zero);
        final baseline = watcher.checkNowCalls;
        expect(baseline, 1);

        await cubit.recheckPermissions();
        expect(watcher.checkNowCalls, baseline + 1);

        await cubit.close();
        await watcher.dispose();
      },
    );

    test(
      'recheckPermissions is a no-op when no watcher is wired',
      () async {
        final cubit = _makeCubit();
        await cubit.bootstrap();
        await expectLater(cubit.recheckPermissions(), completes);
        await cubit.close();
      },
    );

    test(
      'fresh launch with already-revoked perms lands on the denied screen',
      () async {
        // Models the case where the user revoked perms via the system
        // notification shade or settings while the app was killed. The
        // watcher's first sample reports a non-empty missing list before
        // bootstrap finishes; the cubit's defensive checkNow at the end of
        // bootstrap must apply it instead of swallowing it during Booting.
        final watcher = _FakePermissionWatcher()
          ..checkNowResult = const [AppPermission.microphone];
        final cubit = _makeCubit(
          identityStore: _FakeStore(initial: 'Maya'),
          permissionWatcher: watcher,
        );

        await cubit.bootstrap();
        // bootstrap fires the defensive checkNow asynchronously.
        await Future<void>.delayed(Duration.zero);

        final s = cubit.state;
        expect(s, isA<SessionPermissionDenied>());
        expect((s as SessionPermissionDenied).missing,
            [AppPermission.microphone]);
        expect(s.myName, 'Maya');

        await cubit.close();
        await watcher.dispose();
      },
    );

    test(
      'recover-from-denied does not clobber a fresh denied state during the '
      'recent-frequencies disk-read await',
      () async {
        // Race: watcher reports all-granted → cubit starts
        // _recoverFromPermissionDenied which awaits _loadRecentFrequencies.
        // Mid-await, the user toggles a permission off again and the watcher
        // pushes a fresh denied state. Recovery must not overwrite that.
        final recent = _GatedRecentFrequenciesStore();
        final watcher = _FakePermissionWatcher();
        final cubit = _makeCubit(
          identityStore: _FakeStore(initial: 'Maya'),
          recentFrequenciesStore: recent,
          permissionWatcher: watcher,
        );
        await cubit.bootstrap();

        // Enter denied.
        watcher.push([AppPermission.microphone]);
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state, isA<SessionPermissionDenied>());

        // Wedge the next getRecent call so recovery's await blocks.
        final blocker = Completer<List<String>>();
        recent.gate = blocker.future;

        // User re-grants — recovery starts and awaits the slow disk read.
        watcher.push(const []);
        await Future<void>.delayed(Duration.zero);
        // Still denied (recovery is mid-await).
        expect(cubit.state, isA<SessionPermissionDenied>());

        // Mid-await, user toggles bluetooth off — fresh denied state lands.
        watcher.push([AppPermission.bluetooth]);
        await Future<void>.delayed(Duration.zero);
        expect((cubit.state as SessionPermissionDenied).missing,
            [AppPermission.bluetooth]);

        // Now the disk read completes. Recovery must NOT emit Discovery —
        // a newer denied state took its place.
        blocker.complete(const []);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state, isA<SessionPermissionDenied>());
        expect((cubit.state as SessionPermissionDenied).missing,
            [AppPermission.bluetooth]);

        await cubit.close();
        await watcher.dispose();
      },
    );
  });

  // ── TalkingState (VAD outbound) ───────────────────────────────────────

  group('TalkingState outbound', () {
    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    /// Same harness shape as the Heartbeats / SignalReport groups.
    ({
      BleControlTransport transport,
      List<Uint8List> outbox,
      StreamController<({String endpointId, Uint8List bytes})> inbox,
    }) makeTestTransport() {
      final outbox = <Uint8List>[];
      final inbox =
          StreamController<({String endpointId, Uint8List bytes})>.broadcast();
      final transport = BleControlTransport.forTest(
        controlBytes: inbox.stream,
        writeBytes: (bytes) async {
          outbox.add(bytes);
        },
      );
      return (transport: transport, outbox: outbox, inbox: inbox);
    }

    /// Reassembles the test transport's [outbox] back into the
    /// [FrequencyMessage]s the wire would carry.
    List<FrequencyMessage> drainOutbox(List<Uint8List> outbox) {
      final reassembler = FragmentReassembler();
      final messages = <FrequencyMessage>[];
      for (final bytes in outbox) {
        final json = reassembler.feed(bytes);
        if (json != null) messages.add(FrequencyMessage.decode(json));
      }
      return messages;
    }

    test(
      'rapid alternating VAD edges produce TalkingStates with strictly '
      'increasing seq numbers on the wire',
      () async {
        final t = makeTestTransport();
        final talking = StreamController<bool>.broadcast();
        addTearDown(talking.close);
        final audio = _StubLocalTalkingAudio(talking.stream);

        final cubit = _makeCubit(
          transport: t.transport,
          audio: audio,
          // Provided to satisfy construction; this test enters the room
          // via `emit(SessionRoom(...))` rather than `joinRoom()`, so
          // the scheduler is never started and does not affect the
          // wire assertions.
          heartbeats:
              HeartbeatScheduler(pingInterval: const Duration(hours: 1)),
        );
        await cubit.bootstrap(); // wires audio.localTalking → _onLocalTalking
        cubit.emit(const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: true,
        ));

        // Eight rapid edges, alternating true / false.
        for (var i = 0; i < 8; i++) {
          talking.add(i.isEven);
        }
        // Drain the chained sends: each VAD edge enqueues a microtask
        // that awaits the previous, so we need enough flushes to clear
        // them all.
        for (var i = 0; i < 16; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        final messages = drainOutbox(t.outbox);
        expect(messages, hasLength(8));
        for (final m in messages) {
          expect(m, isA<TalkingState>());
        }
        for (var i = 1; i < messages.length; i++) {
          expect(
            messages[i].seq,
            greaterThan(messages[i - 1].seq),
            reason: 'seq must strictly increase on the wire',
          );
        }
        // And the talking flags carry the original alternating pattern,
        // proving no edge was coalesced or dropped.
        for (var i = 0; i < messages.length; i++) {
          expect((messages[i] as TalkingState).talking, i.isEven);
        }

        await cubit.close();
        await t.inbox.close();
        t.transport.dispose();
      },
    );

    test(
      'a slow in-flight send blocks subsequent VAD edges from racing onto '
      'the wire',
      () async {
        // Replaces the per-write completer pattern: every writeBytes call
        // returns a future the test controls. With the chain in place,
        // only one write should be in flight at a time — the next VAD
        // edge waits for the previous send to complete before its bytes
        // hit the outbox.
        final outbox = <Uint8List>[];
        final completers = <Completer<void>>[];
        final transport = BleControlTransport.forTest(
          controlBytes: const Stream<({String endpointId, Uint8List bytes})>
              .empty(),
          writeBytes: (bytes) {
            outbox.add(bytes);
            final c = Completer<void>();
            completers.add(c);
            return c.future;
          },
        );

        final talking = StreamController<bool>.broadcast();
        addTearDown(talking.close);
        final audio = _StubLocalTalkingAudio(talking.stream);

        final cubit = _makeCubit(
          transport: transport,
          audio: audio,
          heartbeats:
              HeartbeatScheduler(pingInterval: const Duration(hours: 1)),
        );
        await cubit.bootstrap();
        cubit.emit(const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: true,
        ));

        // Fire three edges before completing any write.
        talking.add(true);
        talking.add(false);
        talking.add(true);
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        // Only the first write should be in flight; the next two wait
        // behind it on the chain.
        expect(outbox, hasLength(1));
        expect(completers, hasLength(1));

        // Release the first; the second's write should land next.
        completers[0].complete();
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(outbox, hasLength(2));

        completers[1].complete();
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(outbox, hasLength(3));

        completers[2].complete();
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        // All three landed in the order they were enqueued.
        final reassembler = FragmentReassembler();
        final talkingFlags = <bool>[];
        for (final bytes in outbox) {
          final json = reassembler.feed(bytes);
          if (json != null) {
            final msg = FrequencyMessage.decode(json);
            expect(msg, isA<TalkingState>());
            talkingFlags.add((msg as TalkingState).talking);
          }
        }
        expect(talkingFlags, [true, false, true]);

        await cubit.close();
        transport.dispose();
      },
    );

    test(
      'transport-level send failures do not poison the chain — later '
      'edges still reach the wire',
      () async {
        // First send throws; the chain must catch it so the second send
        // proceeds. Without the per-message try/catch, an exception
        // thrown out of a `then` callback rejects the chain future, and
        // the next `then(...)` runs in error mode rather than firing
        // the next VAD edge.
        final outbox = <Uint8List>[];
        var sendCount = 0;
        final transport = BleControlTransport.forTest(
          controlBytes: const Stream<({String endpointId, Uint8List bytes})>
              .empty(),
          writeBytes: (bytes) async {
            sendCount++;
            if (sendCount == 1) {
              throw StateError('first write fails');
            }
            outbox.add(bytes);
          },
        );

        final talking = StreamController<bool>.broadcast();
        addTearDown(talking.close);
        final audio = _StubLocalTalkingAudio(talking.stream);

        final cubit = _makeCubit(
          transport: transport,
          audio: audio,
          heartbeats:
              HeartbeatScheduler(pingInterval: const Duration(hours: 1)),
        );
        await cubit.bootstrap();
        cubit.emit(const SessionRoom(
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: true,
        ));

        talking.add(true);
        talking.add(false);
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        // The first write threw (so outbox stays empty for that one);
        // the second still landed.
        expect(sendCount, 2);
        expect(outbox, hasLength(1));
        final reassembler = FragmentReassembler();
        final json = reassembler.feed(outbox.single);
        final msg = FrequencyMessage.decode(json!);
        expect(msg, isA<TalkingState>());
        expect((msg as TalkingState).talking, isFalse);

        await cubit.close();
        transport.dispose();
      },
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

/// RecentFrequenciesStore whose `getRecent()` blocks on a caller-supplied
/// future, letting a test wedge an awaiting cubit method mid-await to
/// exercise races against state transitions that fire during the gap.
///
/// The first call always resolves immediately (so bootstrap can finish)
/// and only later calls block. Tests that want to wedge mid-recovery set
/// the gate before triggering the recovery path.
class _GatedRecentFrequenciesStore implements RecentFrequenciesStore {
  Future<List<String>>? gate;
  int callCount = 0;

  @override
  Future<List<String>> getRecent() async {
    callCount++;
    final g = gate;
    if (g == null) return const [];
    return g;
  }

  @override
  Future<void> record(String freq) async {}

  @override
  Future<void> clear() async {}
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

/// AudioService stub that exposes a caller-supplied stream as
/// [localTalking]. Subclassing the production class keeps the cubit's
/// `audio: ` parameter strongly typed without forcing every other
/// AudioService method into a fake. The host-teardown methods that
/// `cubit.close()` reaches when `roomIsHost: true` are stubbed to
/// no-ops so the tests stay hermetic and never hit the real
/// MethodChannel.
class _StubLocalTalkingAudio extends AudioService {
  _StubLocalTalkingAudio(this._localTalking);
  final Stream<bool> _localTalking;

  @override
  Stream<bool> get localTalking => _localTalking;

  @override
  Future<bool> stopAdvertising() async => true;

  @override
  Future<bool> stopGattServer() async => true;
}
