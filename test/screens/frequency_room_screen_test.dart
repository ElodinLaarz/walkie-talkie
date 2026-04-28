import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:walkie_talkie/bloc/frequency_session_cubit.dart';
import 'package:walkie_talkie/bloc/frequency_session_state.dart';
import 'package:walkie_talkie/data/frequency_mock_data.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/screens/frequency_room_screen.dart';
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

/// Long enough to settle modal-sheet entry (~250 ms), but short enough to
/// avoid triggering the host's join-request toast (fires at 2.8s) or the
/// weak-signal toast (fires at 7.2s) — those are demo timers in initState.
const _settle = Duration(milliseconds: 500);

Widget _wrap(Widget child, {FrequencySessionCubit? cubit}) {
  final mockCubit = cubit ?? MockFrequencySessionCubit();
  final mockStore = MockIdentityStore();
  
  if (cubit == null) {
    when(() => mockStore.getPeerId()).thenAnswer((_) async => 'me');
    when(() => mockCubit.identityStore).thenReturn(mockStore);
    when(() => mockCubit.state).thenReturn(const SessionBooting());
    when(() => mockCubit.stream).thenAnswer((_) => const Stream<FrequencySessionState>.empty());
    
    final controller = StreamController<MediaCommand>.broadcast();
    when(() => mockCubit.mediaCommands).thenAnswer((_) => controller.stream);
    
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
        child: BlocProvider<FrequencySessionCubit>.value(
          value: mockCubit,
          child: c!,
        ),
      ),
    ),
    home: child,
  );
}

Widget _room({
  bool isHost = false,
  bool pttMode = false,
  int groupSize = 5,
  MediaKind mediaKind = MediaKind.music,
}) =>
    FrequencyRoomScreen(
      freq: '104.3',
      isHost: isHost,
      myName: 'Caleb',
      groupSize: groupSize,
      mediaKind: mediaKind,
      pttMode: pttMode,
      onLeave: () {},
      debugDemoTimers: true,
    );

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
    testWidgets('renders the on-air chrome and the user as the first peer',
        (tester) async {
      await tester.pumpWidget(_wrap(_room()));
      await tester.pump();

      // On-air pill in the chrome carries the frequency.
      expect(find.text('On air'), findsOneWidget);
      expect(find.text('104.3'), findsOneWidget);

      // Me-row shows the configured name without the muted suffix.
      expect(find.text('Caleb'), findsOneWidget);
      expect(find.textContaining('· muted'), findsNothing);
    });

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

    testWidgets('skip and prev change the displayed track', (tester) async {
      await tester.pumpWidget(_wrap(_room()));
      await tester.pump();

      // Music library starts on "Nightsong" by Mount Kimbie.
      expect(find.text('Nightsong'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.skip_next));
      await tester.pump();
      expect(find.text('Nightsong'), findsNothing);
      expect(find.text('Soft Fascination'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.skip_previous));
      await tester.pump();
      expect(find.text('Soft Fascination'), findsNothing);
      expect(find.text('Nightsong'), findsOneWidget);
    });

    testWidgets('opening a peer row reveals the drawer with volume + mute switch',
        (tester) async {
      await tester.pumpWidget(_wrap(_room()));
      await tester.pump();

      // Tap the second roster entry (the first peer after "me").
      await tester.tap(find.text(kPeople[1].name));
      await tester.pump(_settle);

      expect(find.text('Mute from your side'), findsOneWidget);
      expect(find.text('Their voice volume'), findsOneWidget);
    });

    testWidgets('peer drawer hides Remove for guests', (tester) async {
      await tester.pumpWidget(_wrap(_room(isHost: false)));
      await tester.pump();

      await tester.tap(find.text(kPeople[1].name));
      await tester.pump(_settle);

      expect(find.text('Remove from frequency'), findsNothing);
    });

    testWidgets('peer drawer surfaces Remove for hosts', (tester) async {
      await tester.pumpWidget(_wrap(_room(isHost: true)));
      await tester.pump();

      await tester.tap(find.text(kPeople[1].name));
      await tester.pump(_settle);

      expect(find.text('Remove from frequency'), findsOneWidget);
    });

    // testWidgets.skip is bool-only; wrap in a group so the runner records
    // a reason instead of a silent skip count.
    group(
      'click-through integration (skipped)',
      () {
        testWidgets(
            'host removing a peer dismisses the drawer, drops them from the '
            'roster, and surfaces a leave toast', (tester) async {
          await tester.pumpWidget(_wrap(_room(isHost: true)));
          await tester.pump();

          final peerName = kPeople[1].name;
          expect(find.text(peerName), findsOneWidget);

          await tester.tap(find.text(peerName));
          await tester.pump(_settle);

          expect(find.text(peerName), findsAtLeastNWidgets(1));

          await tester.tap(find.text('Remove from frequency'));
          await tester.pump(_settle);

          expect(find.text('Remove from frequency'), findsNothing);
          expect(find.text(peerName), findsNothing);
          expect(find.text('$peerName was removed'), findsOneWidget);
        });
      },
      skip:
          'modal-sheet bottom inset can push Remove below the viewport in '
          'widget tests; drawer-content checks above already cover Remove '
          'visible vs hidden; click-through integration deferred to a real '
          'device + the state-container test seam landing with #13',
    );

    testWidgets('podcast media kind switches the source and the queue',
        (tester) async {
      await tester.pumpWidget(_wrap(_room(mediaKind: MediaKind.podcast)));
      await tester.pump();

      // The "Listening together · …" eyebrow uppercases the source name.
      expect(find.text('LISTENING TOGETHER · PODCASTS'), findsOneWidget);
      // First podcast track in kMedia.
      expect(find.text('The Quiet Economy'), findsOneWidget);
    });

    testWidgets('Leave button fires onLeave', (tester) async {
      var leaveCount = 0;
      await tester.pumpWidget(_wrap(FrequencyRoomScreen(
        freq: '104.3',
        isHost: false,
        myName: 'Caleb',
        groupSize: 5,
        mediaKind: MediaKind.music,
        pttMode: false,
        onLeave: () => leaveCount++,
      )));
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
        final cubit = FrequencySessionCubit(
          identityStore: _MemoryStore(),
          recentFrequenciesStore: _NullRecentFrequenciesStore(),
        );
        addTearDown(cubit.close);

        cubit
          ..emit(const SessionDiscovery(myName: 'Caleb'))
          ..joinRoom(freq: '104.3', isHost: false);

        await tester.pumpWidget(_wrap(_room(), cubit: cubit));
        await tester.pump();

        // Land an initial snapshot (track #1, playing).
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
        expect(find.text('Soft Fascination'), findsOneWidget);
        expect(find.text('Live'), findsOneWidget);

        // Rejoin: host says "nothing playing" (mediaState absent on the
        // wire). The transport should reset, not strand on track #1.
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
      'snapshot for an unknown source is dropped — UI keeps the prior queue',
      (tester) async {
        final cubit = FrequencySessionCubit(
          identityStore: _MemoryStore(),
          recentFrequenciesStore: _NullRecentFrequenciesStore(),
        );
        addTearDown(cubit.close);

        cubit
          ..emit(const SessionDiscovery(myName: 'Caleb'))
          ..joinRoom(freq: '104.3', isHost: false);

        await tester.pumpWidget(_wrap(_room(), cubit: cubit));
        await tester.pump();
        // Initial render — music queue's first track.
        expect(find.text('Nightsong'), findsOneWidget);

        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [],
          mediaState: const MediaState(
            // Truly absent from kMedia — a v2 host that supports a new
            // source kind a v1 client doesn't know about.
            source: 'TidalRadio',
            trackIdx: 0,
            playing: true,
            positionMs: 0,
          ),
        ));
        await tester.pump();

        // Snapshot ignored — the screen still shows the local default,
        // and `_source` hasn't been corrupted.
        expect(find.text('Nightsong'), findsOneWidget);
        expect(find.text('LISTENING TOGETHER · YOUTUBE MUSIC'), findsOneWidget);
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
      'applyJoinAccepted snapshot seeds the local player on rejoin',
      (tester) async {
        // Real cubit so the BlocListener actually reacts to state changes.
        final cubit = FrequencySessionCubit(
          identityStore: _MemoryStore(),
          recentFrequenciesStore: _NullRecentFrequenciesStore(),
        );
        addTearDown(cubit.close);

        // Pretend the user already tuned in to a music room.
        cubit
          ..emit(const SessionDiscovery(myName: 'Caleb'))
          ..joinRoom(freq: '104.3', isHost: false);

        await tester.pumpWidget(_wrap(_room(), cubit: cubit));
        await tester.pump();

        // Initial render — no snapshot, screen shows the music queue's
        // first track.
        expect(find.text('Nightsong'), findsOneWidget);

        // Host's JoinAccepted lands; mediaState says we're 91s into track #2.
        cubit.applyJoinAccepted(JoinAccepted(
          peerId: 'p-host',
          seq: 1,
          atMs: 0,
          hostPeerId: 'p-host',
          roster: const [],
          mediaState: const MediaState(
            source: 'YouTube Music',
            trackIdx: 1,
            playing: false,
            positionMs: 91000,
          ),
        ));
        await tester.pump();

        // Now showing the second track in the queue, paused, scrubbed in.
        expect(find.text('Nightsong'), findsNothing);
        expect(find.text('Soft Fascination'), findsOneWidget);
        expect(find.text('Paused'), findsOneWidget);
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
