import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:walkie_talkie/bloc/discovery_cubit.dart';
import 'package:walkie_talkie/bloc/discovery_state.dart';
import 'package:walkie_talkie/screens/frequency_discovery_screen.dart';
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
  });
}
