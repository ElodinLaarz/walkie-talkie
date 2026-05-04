import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:walkie_talkie/l10n/generated/app_localizations.dart';
import 'package:walkie_talkie/screens/frequency_privacy_policy_screen.dart';
import 'package:walkie_talkie/screens/frequency_settings_screen.dart';
import 'package:walkie_talkie/services/settings_store.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/frequency_atoms.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

class _FakeSettingsStore implements SettingsStore {
  bool pttMode;
  bool keepScreenOn;
  bool crashReporting;

  final List<(String, bool)> calls = [];

  _FakeSettingsStore({
    this.pttMode = false,
    this.keepScreenOn = false,
    this.crashReporting = false,
  });

  @override
  Future<bool> getPttModeEnabled() async => pttMode;

  @override
  Future<void> setPttModeEnabled(bool v) async => calls.add(('setPttMode', v));

  @override
  Future<bool> getKeepScreenOn() async => keepScreenOn;

  @override
  Future<void> setKeepScreenOn(bool v) async => calls.add(('setKeepScreenOn', v));

  @override
  Future<bool> getCrashReportingEnabled() async => crashReporting;

  @override
  Future<void> setCrashReportingEnabled(bool v) async =>
      calls.add(('setCrashReporting', v));
}

FreqSwitch _findToggleFor(WidgetTester tester, String label) {
  return tester.widget<FreqSwitch>(
    find.descendant(
      of: find.ancestor(
        of: find.text(label),
        matching: find.byType(ListTile),
      ),
      matching: find.byType(FreqSwitch),
    ),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PackageInfo.setMockInitialValues(
      appName: 'Frequency',
      packageName: 'com.elodin.walkie_talkie',
      version: '1.2.3',
      buildNumber: '42',
      buildSignature: '',
      installerStore: null,
    );
  });

  group('FrequencySettingsScreen', () {
    testWidgets('renders the Settings title in the app bar', (tester) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('renders Voice, Display, Privacy and About section headers', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      final list = find.byType(ListView);
      for (final header in ['VOICE', 'DISPLAY', 'PRIVACY', 'ABOUT']) {
        await tester.dragUntilVisible(
          find.text(header),
          list,
          const Offset(0, -200),
        );
        expect(find.text(header), findsOneWidget, reason: '$header missing');
      }
    });

    testWidgets('PTT mode toggle is visible', (tester) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Push-to-talk mode'), findsOneWidget);
    });

    testWidgets('PTT mode toggle reflects initial false value from store', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          FrequencySettingsScreen(
            settingsStore: _FakeSettingsStore(pttMode: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_findToggleFor(tester, 'Push-to-talk mode').value, isFalse);
    });

    testWidgets('PTT mode toggle reflects initial true value from store', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          FrequencySettingsScreen(
            settingsStore: _FakeSettingsStore(pttMode: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_findToggleFor(tester, 'Push-to-talk mode').value, isTrue);
    });

    testWidgets('tapping PTT toggle calls setPttModeEnabled and flips state', (
      tester,
    ) async {
      final store = _FakeSettingsStore(pttMode: false);
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: store)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Push-to-talk mode'));
      await tester.pump();

      expect(store.calls, contains(('setPttMode', true)));
      expect(_findToggleFor(tester, 'Push-to-talk mode').value, isTrue);
    });

    testWidgets('Keep screen on toggle is visible', (tester) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Keep screen on'), findsOneWidget);
    });

    testWidgets(
      'Keep screen on toggle reflects initial false value from store',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            FrequencySettingsScreen(
              settingsStore: _FakeSettingsStore(keepScreenOn: false),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(_findToggleFor(tester, 'Keep screen on').value, isFalse);
      },
    );

    testWidgets(
      'tapping Keep screen on toggle calls setKeepScreenOn and flips state',
      (tester) async {
        final store = _FakeSettingsStore(keepScreenOn: false);
        await tester.pumpWidget(
          _wrap(FrequencySettingsScreen(settingsStore: store)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.bySemanticsLabel('Keep screen on'));
        await tester.pump();

        expect(store.calls, contains(('setKeepScreenOn', true)));
        expect(_findToggleFor(tester, 'Keep screen on').value, isTrue);
      },
    );

    testWidgets('Crash reporting row is visible in Privacy section', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('Crash reporting'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Crash reporting'), findsOneWidget);
    });

    testWidgets('version row shows version from PackageInfo', (tester) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('1.2.3'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('1.2.3'), findsOneWidget);
    });

    testWidgets('Privacy policy link is visible in About section', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('Privacy policy'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Privacy policy'), findsOneWidget);
    });

    testWidgets(
      'tapping Privacy policy link navigates to FrequencyPrivacyPolicyScreen',
      (tester) async {
        await tester.pumpWidget(
          _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
        );
        await tester.pumpAndSettle();

        await tester.dragUntilVisible(
          find.text('Privacy policy'),
          find.byType(ListView),
          const Offset(0, -200),
        );
        await tester.tap(find.text('Privacy policy'));
        await tester.pumpAndSettle();

        expect(find.byType(FrequencyPrivacyPolicyScreen), findsOneWidget);
      },
    );

    testWidgets('Open source licenses link is visible', (tester) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('Open source licenses'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Open source licenses'), findsOneWidget);
    });
  });
}
