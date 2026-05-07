import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/l10n/generated/app_localizations.dart';
import 'package:walkie_talkie/screens/frequency_explainer_screen.dart';
import 'package:walkie_talkie/theme/app_theme.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  group('FrequencyExplainerScreen non-embedded (default)', () {
    testWidgets('renders Scaffold with Skip + Next on the first page', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(FrequencyExplainerScreen(onDone: () {})));
      await tester.pumpAndSettle();

      expect(find.byType(Scaffold), findsOneWidget);
      // Skip button shows on non-last pages.
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
      // Get started only shows on the final page.
      expect(find.text('Get started'), findsNothing);
    });

    testWidgets('tapping Skip invokes onDone', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(FrequencyExplainerScreen(onDone: () => taps++)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(taps, 1);
    });

    testWidgets('Next advances to last page where Get started appears', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(FrequencyExplainerScreen(onDone: () {})));
      await tester.pumpAndSettle();

      // Three pages — tap Next twice to reach the end.
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('Get started'), findsOneWidget);
      expect(find.text('Skip'), findsNothing);
    });

    testWidgets('Back from page 2 returns to page 1 (exercises previousPage)', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(FrequencyExplainerScreen(onDone: () {})));
      await tester.pumpAndSettle();

      // Advance once.
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      // Back button should now be active.
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();

      // Skip is visible only on non-last pages — being back on page 0
      // (still non-last) means it's still showing.
      expect(find.text('Skip'), findsOneWidget);
    });

    testWidgets('Get started invokes onDone', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _wrap(FrequencyExplainerScreen(onDone: () => taps++)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();

      expect(taps, 1);
    });
  });

  group('FrequencyExplainerScreen embedded', () {
    testWidgets('embedded mode skips Scaffold + chrome', (tester) async {
      await tester.pumpWidget(
        _wrap(
          // Wrap in a Scaffold so MediaQuery + Material are available; the
          // screen under test must NOT add its own.
          Scaffold(
            body: FrequencyExplainerScreen(onDone: () {}, embedded: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The wrapping Scaffold is the only one — embedded mode must not
      // build its own.
      expect(find.byType(Scaffold), findsOneWidget);
      // No Skip button in embedded mode (chrome is suppressed).
      expect(find.text('Skip'), findsNothing);
      // Next button still shows.
      expect(find.text('Next'), findsOneWidget);
    });
  });
}
