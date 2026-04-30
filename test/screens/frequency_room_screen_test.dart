import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:walkie_talkie/bloc/frequency_session_cubit.dart';
import 'package:walkie_talkie/bloc/frequency_session_state.dart';
import 'package:walkie_talkie/data/frequency_models.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/protocol/peer.dart';
import 'package:walkie_talkie/screens/frequency_room_screen.dart';
import 'package:walkie_talkie/services/audio_service.dart';
import 'package:walkie_talkie/services/identity_store.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/frequency_toast_host.dart';

/// MethodChannel name the audio service uses to talk to the native engine.
/// Must match the constant in `lib/services/audio_service.dart`.
const _audioChannel = MethodChannel('com.elodin.walkie_talkie/audio');

class MockFrequencySessionCubit extends Mock implements FrequencySessionCubit {}
class MockIdentityStore extends Mock implements IdentityStore {}

/// Phone-portrait viewport. The chrome's intrinsic content width sits in
/// the 372–375px range (live chip + HOST chip + 3 ghost buttons), so 412dp
/// passes when the bundled font happens to be slightly narrower than Inter
/// but fails by sub-pixel amounts under other system fonts. 432dp (Pixel 8
/// Pro density) gives consistent headroom across renderers. The taller
/// height lets the peer drawer's modal sheet sit fully on-screen even when
/// the test framework injects a fake-keyboard inset.
const _viewport = Size(432, 1200);

/// Long enough to settle modal-sheet entry (~250 ms).
const _settle = Duration(milliseconds: 500);

Widget _wrap(Widget child, {FrequencySessionCubit? cubit, AudioService? audio}) {
  final mockCubit = cubit ?? MockFrequencySessionCubit();
  final mockStore = MockIdentityStore();
  final providedAudio = audio ?? AudioService();

  if (cubit == null) {
    when(() => mockStore.getPeerId()).thenAnswer((_) async => 'me');
    when(() => mockCubit.identityStore).thenReturn(mockStore);
    when(() => mockCubit.state).thenReturn(const SessionBooting());
    when(() => mockCubit.stream).thenAnswer((_) => const Stream<FrequencySessionState>.empty());

    final controller = StreamController<MediaCommand>.broadcast();
    when(() => mockCubit.mediaCommands).thenAnswer((_) => controller.stream);

    final weakSignalController =
        StreamController<({String peerId, String displayName})>.broadcast();
    when(() => mockCubit.weakSignalEvents)
        .thenAnswer((_) => weakSignalController.stream);

    when(() => mockCubit.sendMediaCommand(
          op: any(named: 'op'),
          source: any(named: 'source'),
          trackIdx: any(named: 'trackIdx'),
          positionMs: any(named: 'positionMs'),
        )).thenAnswer((invocation) async {
      final op = invocation.namedArguments[#op] as MediaOp;
      final source = invocation.namedArguments[#source] as String;
      final trackIdx = invocation.namedArguments[#trackIdx] as int?;
      final positionMs = invocation.namedArguments[#positionMs] as int?;
      controller.add(MediaCommand(
        peerId: 'me',
        seq: 1,
        atMs: DateTime.now().millisecondsSinceEpoch,
        op: op,
        source: source,
        trackIdx: trackIdx,
        positionMs: positionMs,
      ));
    });

    when(() => mockCubit.broadcastMute(any())).thenAnswer((_) async {});
  }

  return MaterialApp(
    theme: AppTheme.light(),
    // Match production placement so toast pushes inside the room don't
    // trip the FrequencyToastHost.of() lookup.
    builder: (context, c) => FrequencyToastHost(
      child: MediaQuery(
        // Test environment can inject a fake keyboard inset when text
        // fields focus, which would push modal sheet content off-screen
        // (same gotcha as the discovery rename test).
        data: MediaQuery.of(context).copyWith(viewInsets: EdgeInsets.zero),
        // Mirror production: AudioService comes from the provider so the
        // room screen's identity-assertion (#129) finds the same instance
        // it stored in `_audio`.
        child: RepositoryProvider<AudioService>.value(
          value: providedAudio,
          child: BlocProvider<FrequencySessionCubit>.value(
            value: mockCubit,
            child: c!,
          ),
        ),
      ),
    ),
    home: child,
  );
}

Widget _room({
  bool isHost = false,
  bool pttMode = false,
  MediaKind mediaKind = MediaKind.music,
  VoidCallback? onLeave,
}) =>
    FrequencyRoomScreen(
      freq: '104.3',
      isHost: isHost,
      myName: 'Caleb',
      mediaKind: mediaKind,
      pttMode: pttMode,
      onLeave: onLeave ?? () {},
    );

/// Spins up a real cubit + parks it in `SessionRoom('104.3')` so a test
/// can directly seed roster / mediaState via `applyJoinAccepted`. The
/// `onLocalTalking` subscription is satisfied by leaving `audio: null`,
/// which leaves `_audio?.localTalking` unsubscribed — voice-path tests
/// that need it construct the cubit themselves with explicit args.
FrequencySessionCubit _seededCubit({bool isHost = false}) {
  final cubit = FrequencySessionCubit(
    identityStore: _MemoryStore(),
    recentFrequenciesStore: _NullRecentFrequenciesStore(),
  );
  cubit
    ..emit(const SessionDiscovery(myName: 'Caleb'))
    ..joinRoom(freq: '104.3', isHost: isHost);
  return cubit;
}

void main() {
  /// Captures every audio MethodChannel call the room screen makes during a
  /// single test. Reset in `setUp` so cross-test bleed is impossible.
  final audioCalls = <MethodCall>[];

  setUpAll(() {
    registerFallbackValue(MediaOp.play);
  });

  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.implicitView!
      ..physicalSize = _viewport
      ..devicePixelRatio = 1.0;

    // Stub the audio MethodChannel so `AudioService` calls land on the test
    // recorder instead of throwing `MissingPluginException`. The screen's
    // initState fires startVoice + setMuted before the first pump, so the
    // handler must be in place before pumpWidget.
    audioCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_audioChannel, (call) async {
      audioCalls.add(call);
      // All audio methods this screen calls return bool today; returning
      // true keeps the await chain happy without forcing per-method
      // dispatch.
      return true;
    });
  });

  tearDown(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.implicitView!
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_audioChannel, null);
  });

  group('FrequencyRoomScreen', () {
    testWidgets(
      'uses the AudioService from the provider, not a fresh one (#129)',
      (tester) async {
        // Two distinct instances: the one wired into the provider vs.
        // a parallel one that should NOT end up as the screen's `_audio`.
        // The screen's debug assertion (`identical(_audio, provider)`)
        // is the lock — if we ever regress and build a second instance
        // inside the screen, the framework crashes the test here.
        final providerAudio = AudioService();
        await tester.pumpWidget(_wrap(_room(), audio: providerAudio));
        await tester.pump();

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('renders the on-air chrome with the local user as the only chip',
        (tester) async {
      await tester.pumpWidget(_wrap(_room()));
      await tester.pump();

      // On-air pill in the chrome carries the frequency.
      expect(find.text('On air'), findsOneWidget);
      expect(find.text('104.3'), findsOneWidget);

      // Me-row shows the configured name without the muted suffix.
      expect(find.text('Caleb'), findsOneWidget);
      expect(find.textContaining('· muted'), findsNothing);

      // No mock peer roster — single-user room shows just the local user
      // (acceptance criterion for #105). SectionLabel uppercases its text.
      expect(find.text('ON THIS FREQUENCY · 1'), findsOneWidget);
    });

    testWidgets(
      'me-row no longer leaks the mock "Sony WH-1000XM5" placeholder',
      // Acceptance criterion for #105: `kPeople.first.btDevice` used to seed
      // the local user's BT label even in production, shipping that string
      // to real users. The me-row now reads the audio-output label until a
      // real route is reported.
      (tester) async {
        await tester.pumpWidget(_wrap(_room()));
        await tester.pump();

        expect(find.text('Sony WH-1000XM5'), findsNothing);
      },
    );

    testWidgets('host chip only shows when isHost: true', (tester) async {
      await tester.pumpWidget(_wrap(_room(isHost: true)));
      await tester.pump();
      expect(find.text('HOST'), findsOneWidget);
    });

    testWidgets('host chip is absent for guests', (tester) async {
      await tester.pumpWidget(_wrap(_room(isHost: false)));
      await tester.pump();
      expect(find.text('HOST'), findsNothing);
    });

    testWidgets('mute toggles the me-row label and the button text',
        (tester) async {
      await tester.pumpWidget(_wrap(_room()));
      await tester.pump();

      // Initial: Mute button visible, no muted suffix on me-row.
      expect(find.text('Mute'), findsOneWidget);
      expect(find.text('Caleb'), findsOneWidget);

      await tester.tap(find.text('Mute'));
      await tester.pump();

      expect(find.text('Caleb · muted'), findsOneWidget);
      expect(find.text('Unmute'), findsOneWidget);
      expect(find.text('Mute'), findsNothing);

      // And back.
      await tester.tap(find.text('Unmute'));
      await tester.pump();
      expect(find.text('Caleb'), findsOneWidget);
      expect(find.text('Mute'), findsOneWidget);
    });

    testWidgets('PTT mode swaps the mute button for Hold to talk',
        (tester) async {
      await tester.pumpWidget(_wrap(_room(pttMode: true)));
      await tester.pump();

      expect(find.text('Hold to talk'), findsOneWidget);
      expect(find.text('Mute'), findsNothing);
      expect(find.text('Unmute'), findsNothing);
      // Footer hint updates too.
      expect(
        find.text('Push-to-talk · hold the mic button to transmit'),
        findsOneWidget,
      );
    });

    testWidgets('open-mic mode shows the open-mic footer hint',
        (tester) async {
      await tester.pumpWidget(_wrap(_room()));
      await tester.pump();
      expect(
        find.text('Open mic · everyone hears you when not muted'),
        findsOneWidget,
      );
    });

    testWidgets('play/pause flips the transport icon and the Live/Paused badge',
        (tester) async {
      await tester.pumpWidget(_wrap(_room()));
      await tester.pump();

      // Initial: playing → pause icon visible (the transport button shows
      // "what tapping it will do"), badge says Live.
      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
      expect(find.text('Live'), findsOneWidget);

      // Tap the play/pause button.
      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Live'), findsNothing);
    });

    testWidgets(
      'opening a peer row reveals the drawer with volume + mute switch',
      (tester) async {
        // Drive the roster from the cubit instead of a mock list — that's
        // the production path now that #105 dropped the demo roster.
        final cubit = _seededCubit();
        addTearDown(cubit.close);

        await tester.pumpWidget(_wrap(_room(), cubit: cubit));
        await tester.pump();
        await tester.pump();

        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [
            ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
          ],
        ));
        await tester.pump();

        await tester.tap(find.text('Devon'));
        await tester.pump(_settle);

        expect(find.text('Mute from your side'), findsOneWidget);
        expect(find.text('Their voice volume'), findsOneWidget);
      },
    );

    testWidgets('peer drawer hides Remove for guests', (tester) async {
      final cubit = _seededCubit();
      addTearDown(cubit.close);

      await tester.pumpWidget(_wrap(_room(isHost: false), cubit: cubit));
      await tester.pump();
      await tester.pump();

      cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-host',
        seq: 1,
        atMs: 0,
        hostPeerId: 'p-host',
        roster: const [
          ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
        ],
      ));
      await tester.pump();

      await tester.tap(find.text('Devon'));
      await tester.pump(_settle);

      expect(find.text('Remove from frequency'), findsNothing);
    });

    testWidgets('peer drawer surfaces Remove for hosts', (tester) async {
      final cubit = _seededCubit(isHost: true);
      addTearDown(cubit.close);

      await tester.pumpWidget(_wrap(_room(isHost: true), cubit: cubit));
      await tester.pump();
      await tester.pump();

      cubit.applyJoinAccepted(JoinAccepted(
        peerId: 'p-guest',
        seq: 1,
        atMs: 0,
        hostPeerId: 'me-peer-id',
        roster: const [
          ProtocolPeer(peerId: 'p-guest', displayName: 'Devon'),
        ],
      ));
      await tester.pump();

      await tester.tap(find.text('Devon'));
      await tester.pump(_settle);

      expect(find.text('Remove from frequency'), findsOneWidget);
    });

    testWidgets(
      'opening peer drawer on a cubit-driven roster does not crash on missing volume entry',
      // Regression for #103: in production the `_volumes` map is empty
      // until the user adjusts a slider, so reading `_volumes[person.id]!`
      // for any cubit-driven peer threw a null dereference. The drawer
      // must read through `_volumeFor`, which falls back to the default
      // volume for unknown peer ids.
      (tester) async {
        final cubit = _seededCubit();
        addTearDown(cubit.close);

        await tester.pumpWidget(_wrap(_room(), cubit: cubit));
        // Pump twice: first to settle initState's post-frame
        // microtasks (startVoice + the identity-store read inside
        // _resolveMyPeerId), second to drain the resulting setStates.
        await tester.pump();
        await tester.pump();

        // Land a roster with a single non-self peer. Different peerId
        // from the identity store's `'me-peer-id'` so the screen
        // doesn't filter it out as the local user.
        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [
            ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
          ],
        ));
        await tester.pump();

        expect(find.text('Devon'), findsOneWidget);

        // Tap the cubit-driven peer row — pre-fix this threw because
        // `_volumes['p-host']` was null and the bang operator
        // dereferenced it.
        await tester.tap(find.text('Devon'));
        await tester.pump(_settle);

        // Drawer rendered — same content the demo-roster test
        // checks, but driven through the production roster path.
        expect(find.text('Mute from your side'), findsOneWidget);
        expect(find.text('Their voice volume'), findsOneWidget);
        // Lock the fallback contract: both the peer row's
        // volume label (still visible behind the drawer) and the
        // drawer's label track `_kDefaultPeerVolume` (0.7) for
        // unknown peer ids.
        expect(find.text('70%'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('podcast media kind switches the source label',
        (tester) async {
      await tester.pumpWidget(_wrap(_room(mediaKind: MediaKind.podcast)));
      await tester.pump();

      // The "Listening together · …" eyebrow uppercases the source name.
      expect(find.text('LISTENING TOGETHER · PODCASTS'), findsOneWidget);
    });

    testWidgets('Leave button fires onLeave', (tester) async {
      var leaveCount = 0;
      await tester.pumpWidget(_wrap(_room(onLeave: () => leaveCount++)));
      await tester.pump();

      // The leave action is the rightmost ghost button in the chrome.
      await tester.tap(find.byIcon(Icons.logout));
      await tester.pump();

      expect(leaveCount, 1);
    });

    testWidgets(
      'rejoin with no mediaState resets the transport instead of stranding '
      'on the prior snapshot',
      (tester) async {
        final cubit = _seededCubit();
        addTearDown(cubit.close);

        await tester.pumpWidget(_wrap(_room(), cubit: cubit));
        await tester.pump();

        // Land an initial snapshot (playing).
        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [],
          mediaState: const MediaState(
            source: 'YouTube Music',
            trackIdx: 1,
            playing: true,
            positionMs: 91000,
          ),
        ));
        await tester.pump();
        expect(find.text('Live'), findsOneWidget);

        // Rejoin: host says "nothing playing" (mediaState absent on the
        // wire). The transport should reset, not strand on the prior state.
        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 2,
          atMs: 1,
          hostPeerId: 'p-host',
          roster: const [],
        ));
        await tester.pump();
        expect(find.text('Paused'), findsOneWidget);
      },
    );

    testWidgets(
      'startVoice fires on entry, stopVoice fires on dispose',
      (tester) async {
        await tester.pumpWidget(_wrap(_room()));
        // Drain the post-frame microtask that resolves startVoice's then().
        await tester.pump();

        expect(
          audioCalls.where((c) => c.method == 'startVoice').length,
          1,
          reason: 'startVoice must be called once on entry',
        );

        // Pump an empty widget tree to dispose the room.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        expect(
          audioCalls.where((c) => c.method == 'stopVoice').length,
          1,
          reason: 'stopVoice must be called on dispose',
        );
      },
    );

    testWidgets(
      'open-mic mute toggle pushes setMuted to the audio engine',
      (tester) async {
        await tester.pumpWidget(_wrap(_room()));
        await tester.pump();

        // Initial: not muted (open-mic default).
        // Tap Mute → setMuted(true) on the engine.
        await tester.tap(find.text('Mute'));
        await tester.pump();
        expect(
          audioCalls.last,
          isMethodCall('setMuted', arguments: {'muted': true}),
        );

        // Tap Unmute → setMuted(false).
        await tester.tap(find.text('Unmute'));
        await tester.pump();
        expect(
          audioCalls.last,
          isMethodCall('setMuted', arguments: {'muted': false}),
        );
      },
    );

    testWidgets(
      'PTT hold/release pushes setMuted(false) and setMuted(true)',
      (tester) async {
        await tester.pumpWidget(_wrap(_room(pttMode: true)));
        await tester.pump();

        // Press the PTT button — engine unmutes.
        final ptt = find.text('Hold to talk');
        final pttCenter = tester.getCenter(ptt);
        final gesture = await tester.startGesture(pttCenter);
        await tester.pump();
        expect(
          audioCalls.last,
          isMethodCall('setMuted', arguments: {'muted': false}),
        );

        // Release — engine re-mutes.
        await gesture.up();
        await tester.pump();
        expect(
          audioCalls.last,
          isMethodCall('setMuted', arguments: {'muted': true}),
        );
      },
    );

    testWidgets(
      'PTT mode start emits setMuted(true) — push-to-talk default is muted',
      (tester) async {
        await tester.pumpWidget(_wrap(_room(pttMode: true)));
        await tester.pump();

        // The very first setMuted after startVoice resolves must reflect
        // the PTT default (muted-until-held), not the open-mic default.
        final firstSetMuted =
            audioCalls.firstWhere((c) => c.method == 'setMuted');
        expect(firstSetMuted.arguments, {'muted': true});
      },
    );

    testWidgets(
      'applyJoinAccepted snapshot promotes the source on rejoin',
      (tester) async {
        // Real cubit so the BlocListener actually reacts to state changes.
        final cubit = _seededCubit();
        addTearDown(cubit.close);

        await tester.pumpWidget(_wrap(_room(), cubit: cubit));
        await tester.pump();

        // Initial render — no snapshot, eyebrow shows the local default
        // source for music.
        expect(find.text('LISTENING TOGETHER · YOUTUBE MUSIC'), findsOneWidget);

        // Host's JoinAccepted lands; mediaState says we're paused on a
        // different source. The eyebrow promotes the host's source verbatim
        // and the transport flips to Paused.
        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [],
          mediaState: const MediaState(
            source: 'Spotify',
            trackIdx: 1,
            playing: false,
            positionMs: 91000,
          ),
        ));
        await tester.pump();

        expect(find.text('LISTENING TOGETHER · SPOTIFY'), findsOneWidget);
        expect(find.text('Paused'), findsOneWidget);
      },
    );

    testWidgets(
      'queuePlay command for an out-of-range trackIdx grows the placeholder queue '
      'instead of throwing RangeError',
      // Regression for Copilot review on PR #153: with a catalog-less
      // placeholder queue, `_onMediaCommand`'s queuePlay branch wrote
      // `_trackIdx = cmd.trackIdx!` directly, so any hop past the
      // current placeholder length crashed on the next read of `_track`.
      (tester) async {
        final cubit = _seededCubit();
        addTearDown(cubit.close);

        await tester.pumpWidget(_wrap(_room(), cubit: cubit));
        await tester.pump();

        // Route a queuePlay through the cubit's mediaCommands stream
        // — same path the wire-driven case uses. trackIdx 7 is well
        // beyond any default placeholder size.
        cubit.applyHostMediaEcho(MediaCommand(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          op: MediaOp.queuePlay,
          source: 'YouTube Music',
          trackIdx: 7,
        ));
        await tester.pump();

        // The screen survived (no RangeError) and the placeholder
        // queue grew enough for the new index — visible as the
        // 8th-track label.
        expect(tester.takeException(), isNull);
        expect(find.text('Track 8'), findsOneWidget);
      },
    );

    testWidgets(
      'applyJoinAccepted snapshot rides snapshot.trackIdx through, '
      'progress reflects positionMs without being clamped to 0:01',
      // Regression for gemini-code-assist comment on PR #153: the
      // first cut of `_applyMediaSnapshot` hardcoded `_trackIdx = 0`
      // (losing the protocol-level index) and clamped progress to the
      // 1-second duration of `emptyMediaLib.queue[0]`, so any nonzero
      // positionMs collapsed to 0:01 on screen and the slider was
      // pinned to its right edge.
      (tester) async {
        final cubit = _seededCubit();
        addTearDown(cubit.close);

        await tester.pumpWidget(_wrap(_room(), cubit: cubit));
        await tester.pump();

        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [],
          mediaState: const MediaState(
            // 91s into the 2nd track on the wire — trackIdx must ride
            // through so outgoing media commands keep referencing the
            // same index the host published.
            source: 'Spotify',
            trackIdx: 1,
            playing: true,
            positionMs: 91000,
          ),
        ));
        await tester.pump();

        // Placeholder title reflects the host's index (1-based).
        expect(find.text('Track 2'), findsOneWidget);
        // Elapsed timestamp surfaces the 1:31 mark — would have shown
        // 0:01 (clamped against emptyMediaLib's 1-second duration)
        // pre-fix.
        expect(find.text('1:31'), findsOneWidget);
      },
    );
  });
}

class _MemoryStore implements IdentityStore {
  String? _name;
  String? _peerId;

  _MemoryStore({String? displayName}) : _name = displayName;

  @override
  Future<String?> getDisplayName() async => _name;

  @override
  Future<void> setDisplayName(String value) async {
    final trimmed = value.trim();
    _name = trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<String> getPeerId() async => _peerId ??= 'me-peer-id';
}

/// Inert RecentFrequenciesStore — these tests don't exercise the
/// recent-frequencies path, but the cubit constructor now requires one.
class _NullRecentFrequenciesStore implements RecentFrequenciesStore {
  @override
  Future<List<String>> getRecent() async => const [];
  @override
  Future<void> record(String freq) async {}
  @override
  Future<void> clear() async {}
}
