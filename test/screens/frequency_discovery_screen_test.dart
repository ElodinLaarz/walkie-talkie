import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:walkie_talkie/bloc/discovery_cubit.dart';
import 'package:walkie_talkie/bloc/discovery_state.dart';
import 'package:walkie_talkie/l10n/generated/app_localizations.dart';
import 'package:walkie_talkie/screens/frequency_discovery_screen.dart';
import 'package:walkie_talkie/screens/security_faq_screen.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';
import 'package:walkie_talkie/theme/app_theme.dart';

class MockDiscoveryCubit extends Mock implements DiscoveryCubit {}

Widget _wrap(Widget child, {DiscoveryCubit? cubit}) {
  final mockCubit = cubit ?? MockDiscoveryCubit();
  if (cubit == null) {
    when(() => mockCubit.state).thenReturn(DiscoveryInitial());
    when(() => mockCubit.stream).thenAnswer((_) => const Stream.empty());
    when(() => mockCubit.startDiscovery()).thenAnswer((_) async {});
    when(() => mockCubit.stopDiscovery()).thenAnswer((_) async {});
    when(() => mockCubit.close()).thenAnswer((_) async {});
  }

  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, navigator) => MediaQuery(
      data: MediaQuery.of(context).copyWith(viewInsets: EdgeInsets.zero),
      child: BlocProvider<DiscoveryCubit>.value(
        value: mockCubit,
        child: navigator!,
      ),
    ),
    home: child,
  );
}

/// The Discovery screen runs a perpetual `PulseDot` animation, so
/// `pumpAndSettle` would time out. Pump for a fixed window long enough to
/// render initial state and finish modal-sheet transitions (~250 ms each)
/// without waiting for the loop to settle.
const _settleWindow = Duration(milliseconds: 800);

void main() {
  // The default test viewport is 800x600 (landscape). Force a phone-shaped
  // surface (Pixel 7-ish, 412x892 dp) so the chrome and the modal sheet have
  // the room they were designed for and taps don't fall off-screen.
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.implicitView!
      ..physicalSize = const Size(412, 892)
      ..devicePixelRatio = 1.0;
  });

  tearDown(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.implicitView!
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
  });

  group('FrequencyDiscoveryScreen', () {
    testWidgets('renders the persisted name as initials in the chrome',
        (tester) async {
      await tester.pumpWidget(_wrap(
        FrequencyDiscoveryScreen(
          myName: 'Devon',
          onPick: (_) {},
          onRename: (_) {},
        ),
      ));
      await tester.pump();

      expect(find.text('DE'), findsOneWidget);
    });

    testWidgets('tapping the identity chip opens a rename sheet seeded with the current name',
        (tester) async {
      await tester.pumpWidget(_wrap(
        FrequencyDiscoveryScreen(
          myName: 'Maya',
          onPick: (_) {},
          onRename: (_) {},
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('MA'));
      await tester.pump(_settleWindow);

      expect(find.text('Your handle'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Maya'), findsOneWidget);
    });

    testWidgets('saving a new name in the sheet calls onRename with the trimmed value',
        (tester) async {
      String? renamed;
      await tester.pumpWidget(_wrap(
        FrequencyDiscoveryScreen(
          myName: 'Maya',
          onPick: (_) {},
          onRename: (name) => renamed = name,
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('MA'));
      await tester.pump(_settleWindow);

      await tester.enterText(find.byType(TextField), '  Priya  ');
      // Submit through the IME `done` action (wired to the same _submit() as
      // the Save button). Avoids the test-environment quirk where the Save
      // button can sit below the simulated keyboard inset.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(_settleWindow);

      expect(renamed, 'Priya');
    });

    testWidgets('saving the same name does not invoke onRename', (tester) async {
      var renameCount = 0;
      await tester.pumpWidget(_wrap(
        FrequencyDiscoveryScreen(
          myName: 'Maya',
          onPick: (_) {},
          onRename: (_) => renameCount++,
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('MA'));
      await tester.pump(_settleWindow);
      // Submit unchanged via IME (same submit path the Save button uses).
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(_settleWindow);

      expect(renameCount, 0);
    });

    testWidgets('Save is disabled when the name field is cleared',
        (tester) async {
      String? renamed;
      await tester.pumpWidget(_wrap(
        FrequencyDiscoveryScreen(
          myName: 'Maya',
          onPick: (_) {},
          onRename: (name) => renamed = name,
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('MA'));
      await tester.pump(_settleWindow);
      await tester.enterText(find.byType(TextField), '');
      // Even submitting via IME should be a no-op for an empty field — the
      // submit path early-returns without popping the sheet.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(_settleWindow);

      expect(renamed, isNull);
    });

    testWidgets('Start a new Frequency fires onPick with isHost: true',
        (tester) async {
      DiscoveryResult? picked;
      await tester.pumpWidget(_wrap(
        FrequencyDiscoveryScreen(
          myName: 'Maya',
          onPick: (r) => picked = r,
          onRename: (_) {},
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('Start a new Frequency'));
      await tester.pump();

      expect(picked, isNotNull);
      expect(picked!.isHost, isTrue);
      expect(picked!.freq, isNotEmpty);
    });

    testWidgets(
      'omits the Recent section when there are no persisted frequencies',
      (tester) async {
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
            // recentHostedFrequencies defaults to empty.
          ),
        ));
        await tester.pump();

        expect(find.text('RECENT'), findsNothing);
        expect(find.text('Resume'), findsNothing);
      },
    );

    testWidgets(
      'renders a Resume row per persisted recent frequency',
      (tester) async {
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
            recentHostedFrequencies: const [
              RecentFrequency(freq: '100.1'),
              RecentFrequency(freq: '92.4'),
            ],
          ),
        ));
        await tester.pump();

        expect(find.text('RECENT'), findsOneWidget);
        // One Resume button per row.
        expect(find.text('Resume'), findsNWidgets(2));
        // Each row's freq is rendered inside a Text.rich span ("Host on X MHz"),
        // so match by substring. Use "Host on" prefix to avoid matching the
        // "Start new" hint which may also contain the frequency.
        expect(find.textContaining('Host on 100.1'), findsOneWidget);
        expect(find.textContaining('Host on 92.4'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping a Resume row fires onPick with isHost: true and that freq',
      (tester) async {
        DiscoveryResult? picked;
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (r) => picked = r,
            onRename: (_) {},
            recentHostedFrequencies: const [
              RecentFrequency(freq: '100.1'),
              RecentFrequency(freq: '92.4'),
            ],
          ),
        ));
        await tester.pump();

        // Tap the second row's Resume button.
        await tester.tap(find.text('Resume').last);
        await tester.pump();

        expect(picked, isNotNull);
        expect(picked!.isHost, isTrue);
        expect(picked!.freq, '92.4');
      },
    );

    testWidgets(
      'renders nickname instead of default title when one is set on a recent',
      (tester) async {
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
            recentHostedFrequencies: const [
              RecentFrequency(freq: '100.1', nickname: 'Family channel'),
              RecentFrequency(freq: '92.4'),
            ],
          ),
        ));
        await tester.pump();

        // The nickname replaces the default 'Your channel' title for the
        // nicknamed row; the un-nicknamed row still shows the default.
        expect(find.text('Family channel'), findsOneWidget);
        expect(find.text('Your channel'), findsOneWidget);
        // Both rows still surface the freq subtitle so the user can see the
        // underlying channel even after assigning a label.
        expect(find.textContaining('Host on 100.1'), findsOneWidget);
        expect(find.textContaining('Host on 92.4'), findsOneWidget);
      },
    );

    testWidgets(
      'renders the PINNED badge on rows that are pinned',
      (tester) async {
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
            recentHostedFrequencies: const [
              RecentFrequency(freq: '100.1', pinned: true),
              RecentFrequency(freq: '92.4'),
            ],
          ),
        ));
        await tester.pump();

        expect(find.text('PINNED'), findsOneWidget);
      },
    );

    testWidgets(
      'opening the recent overflow menu and tapping Pin fires onSetRecentPinned',
      (tester) async {
        ({String freq, bool pinned})? pinned;
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
            recentHostedFrequencies: const [
              RecentFrequency(freq: '100.1'),
            ],
            onSetRecentNickname: (_, _) {},
            onSetRecentPinned: (freq, p) =>
                pinned = (freq: freq, pinned: p),
          ),
        ));
        await tester.pump();

        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // Tap the InkWell wrapping the menu item rather than its Text — the
        // Text's centre lands on RenderAbsorbPointer (the modal barrier of
        // the popup), which dismisses the menu instead of triggering the
        // item.
        await tester.tap(find.widgetWithText(InkWell, 'Pin to top'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(pinned, isNotNull);
        expect(pinned!.freq, '100.1');
        expect(pinned!.pinned, isTrue);
      },
    );

    testWidgets(
      'opening the recent overflow menu on a pinned row shows Unpin and fires onSetRecentPinned(false)',
      (tester) async {
        ({String freq, bool pinned})? pinned;
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
            recentHostedFrequencies: const [
              RecentFrequency(freq: '100.1', pinned: true),
            ],
            onSetRecentNickname: (_, _) {},
            onSetRecentPinned: (freq, p) =>
                pinned = (freq: freq, pinned: p),
          ),
        ));
        await tester.pump();

        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // Pinned rows offer "Unpin" instead of "Pin to top".
        expect(find.text('Unpin'), findsOneWidget);
        expect(find.text('Pin to top'), findsNothing);

        // Tap the InkWell wrapping the Text — the Text's centre lands on
        // the popup's modal barrier in the test environment, so a direct
        // text tap dismisses the menu without triggering the item.
        await tester.tap(find.widgetWithText(InkWell, 'Unpin'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(pinned, isNotNull);
        expect(pinned!.freq, '100.1');
        expect(pinned!.pinned, isFalse);
      },
    );

    testWidgets(
      'opening Rename and saving a nickname fires onSetRecentNickname with the trimmed value',
      (tester) async {
        ({String freq, String? nickname})? saved;
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
            recentHostedFrequencies: const [
              RecentFrequency(freq: '100.1'),
            ],
            onSetRecentNickname: (freq, n) =>
                saved = (freq: freq, nickname: n),
            onSetRecentPinned: (_, _) {},
          ),
        ));
        await tester.pump();

        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.widgetWithText(InkWell, 'Rename'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        await tester.enterText(find.byType(TextField), '  Family channel  ');
        // Submit through the IME `done` action — same submit path as the
        // Save button. Avoids the test-environment quirk where the Save
        // button can sit below the simulated keyboard inset.
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump(_settleWindow);

        expect(saved, isNotNull);
        expect(saved!.freq, '100.1');
        expect(saved!.nickname, 'Family channel');
      },
    );

    testWidgets(
      'submitting an empty nickname clears the existing one (passes null)',
      (tester) async {
        ({String freq, String? nickname})? saved;
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
            recentHostedFrequencies: const [
              RecentFrequency(freq: '100.1', nickname: 'Family channel'),
            ],
            onSetRecentNickname: (freq, n) =>
                saved = (freq: freq, nickname: n),
            onSetRecentPinned: (_, _) {},
          ),
        ));
        await tester.pump();

        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.widgetWithText(InkWell, 'Rename'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        await tester.enterText(find.byType(TextField), '');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump(_settleWindow);

        expect(saved, isNotNull);
        expect(saved!.freq, '100.1');
        expect(saved!.nickname, isNull);
      },
    );

    testWidgets(
      'overflow menu is omitted when both nickname / pin callbacks are null',
      (tester) async {
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
            recentHostedFrequencies: const [
              RecentFrequency(freq: '100.1'),
            ],
            // Both nickname/pin handlers omitted — back-compat path for
            // embeddings that don't wire the persistence layer.
          ),
        ));
        await tester.pump();

        expect(find.byTooltip('Recent options'), findsNothing);
      },
    );

    testWidgets(
      'tapping the footer Privacy link pushes the privacy policy screen, '
      'and the close button pops back to Discovery',
      (tester) async {
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
          ),
        ));
        await tester.pump();

        // The link sits below the footer copy, so scroll the discovery
        // ListView until the Privacy text is visible before tapping it.
        final list = find.byType(ListView);
        final privacyButton = find.widgetWithText(TextButton, 'Privacy');
        await tester.dragUntilVisible(
          privacyButton,
          list,
          const Offset(0, -120),
        );
        await tester.pump();
        await tester.tap(privacyButton);
        // Two pumps cover the route transition: one to start the push,
        // one (with the settle window) to land the new page on top. We
        // can't pumpAndSettle because Discovery's perpetual PulseDot
        // animation never settles.
        await tester.pump();
        await tester.pump(_settleWindow);

        // The privacy policy screen has a unique POLICY eyebrow that the
        // discovery screen does not — anchoring on that avoids matching
        // discovery's own "Privacy" footer link.
        expect(find.text('POLICY'), findsOneWidget);
        expect(find.text('Privacy policy'), findsOneWidget);

        await tester.tap(find.bySemanticsLabel('Close privacy policy'));
        await tester.pump();
        await tester.pump(_settleWindow);

        expect(find.text('POLICY'), findsNothing);
        // We are back on Discovery, so its footer link is visible again.
        expect(privacyButton, findsOneWidget);
      },
    );

    testWidgets(
      'tapping the footer Licenses link pushes Flutter\'s LicensePage with our title',
      (tester) async {
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
          ),
        ));
        await tester.pump();

        final list = find.byType(ListView);
        final licensesButton = find.widgetWithText(TextButton, 'Licenses');
        await tester.dragUntilVisible(
          licensesButton,
          list,
          const Offset(0, -120),
        );
        await tester.pump();
        await tester.tap(licensesButton);
        // The license page renders an internal AnimatedSwitcher; pump
        // through the route + initial frame.
        await tester.pump();
        await tester.pump(_settleWindow);

        // The applicationName we hand to `showLicensePage` becomes the
        // header title — anchoring on the localized string proves we
        // reached LicensePage rather than just any new route.
        expect(find.text('Open source licenses'), findsWidgets);
      },
    );

    testWidgets(
      'tapping the footer Security FAQ link pushes SecurityFaqScreen, '
      'and the close button pops back to Discovery',
      (tester) async {
        await tester.pumpWidget(_wrap(
          FrequencyDiscoveryScreen(
            myName: 'Maya',
            onPick: (_) {},
            onRename: (_) {},
          ),
        ));
        await tester.pump();

        final list = find.byType(ListView);
        final securityButton = find.widgetWithText(TextButton, 'Security FAQ');
        await tester.dragUntilVisible(
          securityButton,
          list,
          const Offset(0, -120),
        );
        await tester.pump();
        await tester.tap(securityButton);
        await tester.pump();
        await tester.pump(_settleWindow);

        expect(find.byType(SecurityFaqScreen), findsOneWidget);

        await tester.tap(find.bySemanticsLabel('Close Privacy & Security FAQ'));
        await tester.pump();
        await tester.pump(_settleWindow);

        expect(find.byType(SecurityFaqScreen), findsNothing);
        expect(securityButton, findsOneWidget);
      },
    );
  });

  group('DiscoveryResult invariants', () {
    test('host DiscoveryResult with non-null MAC fails the host assert', () {
      // The Start-a-new-Frequency and Resume-recent paths are local-only
      // hosts — there's no remote to dial, so MAC + sessionUuidLow8 must
      // stay null. Catch the bad state at construction.
      expect(
        () => DiscoveryResult(
          freq: '104.3',
          isHost: true,
          macAddress: 'AA:BB:CC:DD:EE:FF',
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('guest DiscoveryResult with null MAC fails the guest assert', () {
      // The Nearby tap-to-join path always has both fields by construction
      // (we just carried them off the discovered advertisement). A null
      // here would mean the screen forgot to thread them — fail fast
      // rather than letting #43 dial nothing.
      expect(
        () => DiscoveryResult(
          freq: '104.3',
          isHost: false,
          sessionUuidLow8: '0011223344556677',
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('valid host and guest DiscoveryResults construct cleanly', () {
      expect(
        () => const DiscoveryResult(freq: '104.3', isHost: true),
        returnsNormally,
      );
      expect(
        () => const DiscoveryResult(
          freq: '104.3',
          isHost: false,
          macAddress: 'AA:BB:CC:DD:EE:FF',
          sessionUuidLow8: '0011223344556677',
        ),
        returnsNormally,
      );
    });
  });
}
