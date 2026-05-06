import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/invite_sheet.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: child),
  );
}

void main() {
  group('InviteSheet', () {
    testWidgets('renders INVITE NEARBY heading and freq label', (tester) async {
      await tester.pumpWidget(_wrap(const InviteSheet(freq: '103.7')));
      expect(find.text('INVITE NEARBY'), findsOneWidget);
      expect(find.text('103.7'), findsOneWidget);
    });

    testWidgets('shows "Copy invite link" button initially', (tester) async {
      await tester.pumpWidget(_wrap(const InviteSheet(freq: '91.5')));
      expect(find.text('Copy invite link'), findsOneWidget);
      expect(find.text('Copied invite'), findsNothing);
    });

    testWidgets('tapping copy button changes label to "Copied invite"', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const InviteSheet(freq: '91.5')));
      await tester.tap(find.text('Copy invite link'));
      await tester.pump();
      expect(find.text('Copied invite'), findsOneWidget);
      expect(find.text('Copy invite link'), findsNothing);
    });

    testWidgets('"Copied invite" reverts after 1600ms', (tester) async {
      await tester.pumpWidget(_wrap(const InviteSheet(freq: '91.5')));
      await tester.tap(find.text('Copy invite link'));
      await tester.pump();
      expect(find.text('Copied invite'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1599));
      expect(find.text('Copied invite'), findsOneWidget);
      expect(find.text('Copy invite link'), findsNothing);

      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Copy invite link'), findsOneWidget);
      expect(find.text('Copied invite'), findsNothing);
    });
  });
}
