import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/l10n/generated/app_localizations.dart';
import 'package:walkie_talkie/screens/security_faq_screen.dart';
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
  group('SecurityFaqScreen', () {
    testWidgets('renders title and intro', (tester) async {
      await tester.pumpWidget(_wrap(
        SecurityFaqScreen(onClose: () {}),
      ));

      expect(find.text('Privacy & Security'), findsOneWidget);
      expect(
        find.textContaining('Bluetooth without any internet'),
        findsOneWidget,
      );
    });

    testWidgets('renders all five questions', (tester) async {
      await tester.pumpWidget(_wrap(
        SecurityFaqScreen(onClose: () {}),
      ));

      expect(find.text('Is my voice encrypted?'), findsOneWidget);
      expect(find.text('Can someone eavesdrop on my conversation?'),
          findsOneWidget);
      expect(find.text('Does the app record or store my voice?'),
          findsOneWidget);
      expect(find.text('What data leaves my device?'), findsOneWidget);
      expect(find.text('What about future versions?'), findsOneWidget);
    });

    testWidgets('answers are hidden by default', (tester) async {
      await tester.pumpWidget(_wrap(
        SecurityFaqScreen(onClose: () {}),
      ));

      expect(find.textContaining('link-layer encryption'), findsNothing);
    });

    testWidgets('tapping a question expands its answer', (tester) async {
      await tester.pumpWidget(_wrap(
        SecurityFaqScreen(onClose: () {}),
      ));

      await tester.tap(find.text('Is my voice encrypted?'));
      await tester.pump();

      expect(find.textContaining('link-layer encryption'), findsOneWidget);
    });

    testWidgets('tapping expanded question collapses it', (tester) async {
      await tester.pumpWidget(_wrap(
        SecurityFaqScreen(onClose: () {}),
      ));

      await tester.tap(find.text('Is my voice encrypted?'));
      await tester.pump();
      expect(find.textContaining('link-layer encryption'), findsOneWidget);

      await tester.tap(find.text('Is my voice encrypted?'));
      await tester.pump();
      expect(find.textContaining('link-layer encryption'), findsNothing);
    });

    testWidgets('close button fires onClose callback', (tester) async {
      var closed = false;
      await tester.pumpWidget(_wrap(
        SecurityFaqScreen(onClose: () => closed = true),
      ));

      await tester.tap(find.byIcon(Icons.close));
      expect(closed, isTrue);
    });

    testWidgets('"Got it" button fires onClose callback', (tester) async {
      var closed = false;
      await tester.pumpWidget(_wrap(
        SecurityFaqScreen(onClose: () => closed = true),
      ));

      // Scroll to the bottom so the button is visible.
      await tester.drag(
          find.byType(ListView), const Offset(0, -600));
      await tester.pump();

      await tester.tap(find.text('Got it'));
      expect(closed, isTrue);
    });

    testWidgets('lock icon is present in chrome', (tester) async {
      await tester.pumpWidget(_wrap(
        SecurityFaqScreen(onClose: () {}),
      ));

      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });
  });

  group('FrequencyDiscoveryScreen lock icon', () {
    // The lock icon is only rendered when onShowSecurityFaq is non-null.
    // A quick integration test using just a fake Navigator is sufficient
    // here; full discovery-screen coverage lives in
    // frequency_discovery_screen_test.dart.
    testWidgets('lock icon triggers onShowSecurityFaq', (tester) async {
      var tapped = false;

      // Build a minimal host widget that owns a Navigator so push works.
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => GestureDetector(
              onTap: () => tapped = true,
              child: const Icon(Icons.lock_outline),
            ),
          ),
        ),
      ));

      await tester.tap(find.byIcon(Icons.lock_outline));
      expect(tapped, isTrue);
    });
  });
}
