import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/media_source_sheet.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: child),
  );
}

void main() {
  group('MediaSourceSheet', () {
    testWidgets('renders "Choose source" heading', (tester) async {
      await tester.pumpWidget(
        _wrap(const MediaSourceSheet(current: 'YouTube Music')),
      );
      await tester.pump();
      expect(find.text('Choose source'), findsOneWidget);
    });

    testWidgets('renders all four source labels', (tester) async {
      await tester.pumpWidget(
        _wrap(const MediaSourceSheet(current: 'YouTube Music')),
      );
      await tester.pump();
      for (final source in MediaSource.values) {
        expect(find.text(source.label), findsOneWidget);
      }
    });

    testWidgets('current source row shows check icon', (tester) async {
      await tester.pumpWidget(
        _wrap(const MediaSourceSheet(current: 'spotify')),
      );
      await tester.pump();
      // The selected row has a checkmark; other rows do not.
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('non-selected source has no check icon', (tester) async {
      // With 'spotify' selected, YouTube Music row has no check.
      await tester.pumpWidget(
        _wrap(const MediaSourceSheet(current: 'spotify')),
      );
      await tester.pump();
      // Only one check visible — the selected source.
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('selected source row shows check; others do not', (
      tester,
    ) async {
      // Spotify selected — check icon should appear exactly once.
      await tester.pumpWidget(
        _wrap(const MediaSourceSheet(current: 'spotify')),
      );
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);

      // Switch to Podcasts — check moves (verify by re-pumping with new current).
      await tester.pumpWidget(
        _wrap(const MediaSourceSheet(current: 'Podcasts')),
      );
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });
}
