import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/l10n/generated/app_localizations.dart';
import 'package:walkie_talkie/screens/frequency_privacy_policy_screen.dart';
import 'package:walkie_talkie/theme/app_theme.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

void main() {
  group('FrequencyPrivacyPolicyScreen', () {
    testWidgets('renders headline, eyebrow, and last-updated stamp',
        (tester) async {
      await tester
          .pumpWidget(_wrap(const FrequencyPrivacyPolicyScreen()));

      expect(find.text('Privacy policy'), findsOneWidget);
      expect(find.text('POLICY'), findsOneWidget);
      expect(find.textContaining('Last updated'), findsOneWidget);
    });

    testWidgets('renders all required Play Console policy sections',
        (tester) async {
      await tester
          .pumpWidget(_wrap(const FrequencyPrivacyPolicyScreen()));

      // Scroll through to make sure every section is built.
      final list = find.byType(ListView);
      expect(list, findsOneWidget);
      await tester.dragUntilVisible(
        find.text('Contact'),
        list,
        const Offset(0, -200),
      );

      for (final title in const [
        'TL;DR',
        'Audio (microphone)',
        'Bluetooth identifiers',
        'On-device storage',
        'Crash and diagnostic data',
        'Permissions',
        "Children's privacy",
        'Data retention and deletion',
        'Contact',
      ]) {
        expect(find.text(title), findsOneWidget,
            reason: 'Missing required policy section: $title');
      }
    });

    testWidgets('close button pops the screen', (tester) async {
      await tester.pumpWidget(_wrap(Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: Builder(builder: (innerContext) {
              return ElevatedButton(
                onPressed: () => Navigator.of(innerContext).push(
                  MaterialPageRoute(
                    builder: (_) => const FrequencyPrivacyPolicyScreen(),
                  ),
                ),
                child: const Text('open'),
              );
            }),
          ),
        );
      })));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(FrequencyPrivacyPolicyScreen), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Close privacy policy'));
      await tester.pumpAndSettle();
      expect(find.byType(FrequencyPrivacyPolicyScreen), findsNothing);
    });
  });
}
