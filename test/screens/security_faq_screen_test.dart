import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:walkie_talkie/l10n/generated/app_localizations.dart';
import 'package:walkie_talkie/screens/frequency_settings_screen.dart';
import 'package:walkie_talkie/screens/security_faq_screen.dart';
import 'package:walkie_talkie/services/settings_store.dart';
import 'package:walkie_talkie/theme/app_theme.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

class _FakeSettingsStore implements SettingsStore {
  @override
  Future<bool> getCrashReportingEnabled() async => false;
  @override
  Future<void> setCrashReportingEnabled(bool v) async {}
  @override
  Future<bool> getPttModeEnabled() async => false;
  @override
  Future<void> setPttModeEnabled(bool v) async {}
  @override
  Future<bool> getKeepScreenOn() async => false;
  @override
  Future<void> setKeepScreenOn(bool v) async {}
}

void main() {
  group('SecurityFaqScreen', () {
    testWidgets('renders title and intro', (tester) async {
      await tester.pumpWidget(_wrap(const SecurityFaqScreen()));

      expect(find.text('Privacy & Security'), findsOneWidget);
      expect(
        find.textContaining('Bluetooth without any internet'),
        findsOneWidget,
      );
    });

    testWidgets('renders all five questions', (tester) async {
      await tester.pumpWidget(_wrap(const SecurityFaqScreen()));

      expect(find.text('Is my voice encrypted?'), findsOneWidget);
      expect(
          find.text('Can someone eavesdrop on my conversation?'), findsOneWidget);
      expect(find.text('Does the app record or store my voice?'), findsOneWidget);
      expect(find.text('What data leaves my device?'), findsOneWidget);
      expect(find.text('What about future versions?'), findsOneWidget);
    });

    testWidgets('answers are hidden by default', (tester) async {
      await tester.pumpWidget(_wrap(const SecurityFaqScreen()));

      expect(find.textContaining('not enforce Bluetooth pairing'), findsNothing);
    });

    testWidgets('tapping a question expands its answer', (tester) async {
      await tester.pumpWidget(_wrap(const SecurityFaqScreen()));

      await tester.tap(find.text('Is my voice encrypted?'));
      await tester.pump();

      expect(find.textContaining('not enforce Bluetooth pairing'), findsOneWidget);
    });

    testWidgets('tapping expanded question collapses it', (tester) async {
      await tester.pumpWidget(_wrap(const SecurityFaqScreen()));

      await tester.tap(find.text('Is my voice encrypted?'));
      await tester.pump();
      expect(find.textContaining('not enforce Bluetooth pairing'), findsOneWidget);

      await tester.tap(find.text('Is my voice encrypted?'));
      await tester.pump();
      expect(find.textContaining('not enforce Bluetooth pairing'), findsNothing);
    });

    testWidgets('close button pops the screen', (tester) async {
      await tester.pumpWidget(_wrap(Builder(builder: (context) {
        return Scaffold(
          body: Builder(builder: (innerContext) {
            return ElevatedButton(
              onPressed: () => Navigator.of(innerContext).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SecurityFaqScreen(),
                ),
              ),
              child: const Text('open'),
            );
          }),
        );
      })));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(SecurityFaqScreen), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(SecurityFaqScreen), findsNothing);
    });

    testWidgets('"Got it" button pops the screen', (tester) async {
      await tester.pumpWidget(_wrap(Builder(builder: (context) {
        return Scaffold(
          body: Builder(builder: (innerContext) {
            return ElevatedButton(
              onPressed: () => Navigator.of(innerContext).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SecurityFaqScreen(),
                ),
              ),
              child: const Text('open'),
            );
          }),
        );
      })));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pump();

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(find.byType(SecurityFaqScreen), findsNothing);
    });
  });

  group('FrequencySettingsScreen security FAQ link', () {
    setUp(() {
      // The settings screen calls PackageInfo.fromPlatform() in its async
      // initState. Without mock values the platform channel throws, but the
      // screen's try-catch handles that and still sets _loaded=true.
      // Providing mock values makes the version row render with real data
      // and avoids test-environment exception noise.
      PackageInfo.setMockInitialValues(
        appName: 'Frequency',
        packageName: 'com.elodin.walkie_talkie',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
        installerStore: null,
      );
    });

    // The settings screen body is gated on `_loaded`, which flips only after
    // the async initState chain (Future.wait + PackageInfo) resolves.
    // pumpAndSettle drains all pending futures and frames so the body renders.
    testWidgets('Privacy section shows Security FAQ link', (tester) async {
      await tester.pumpWidget(_wrap(
        FrequencySettingsScreen(settingsStore: _FakeSettingsStore()),
      ));
      await tester.pumpAndSettle();

      // The Privacy section may be below the fold — scroll down to find it.
      await tester.dragUntilVisible(
        find.text('Privacy & Security FAQ'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Privacy & Security FAQ'), findsOneWidget);
    });

    testWidgets('tapping Security FAQ link opens SecurityFaqScreen',
        (tester) async {
      await tester.pumpWidget(_wrap(
        FrequencySettingsScreen(settingsStore: _FakeSettingsStore()),
      ));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('Privacy & Security FAQ'),
        find.byType(ListView),
        const Offset(0, -200),
      );

      await tester.tap(find.text('Privacy & Security FAQ'));
      await tester.pumpAndSettle();

      expect(find.byType(SecurityFaqScreen), findsOneWidget);
    });
  });
}
