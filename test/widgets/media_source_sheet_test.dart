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

    testWidgets('check icon is on the selected row and absent from others', (
      tester,
    ) async {
      Finder rowContaining(String label) => find
          .ancestor(of: find.text(label), matching: find.byType(InkWell))
          .first;

      // Spotify selected.
      await tester.pumpWidget(
        _wrap(const MediaSourceSheet(current: 'spotify')),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: rowContaining('Spotify'),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rowContaining('Podcasts'),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );

      // Switch to Podcasts — check icon must move.
      await tester.pumpWidget(
        _wrap(const MediaSourceSheet(current: 'Podcasts')),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: rowContaining('Podcasts'),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rowContaining('Spotify'),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );
    });
  });

  group('MediaSource enum metadata', () {
    test('isPodcast is true for podcast sources', () {
      expect(MediaSource.podcasts.isPodcast, isTrue);
      expect(MediaSource.pocketCasts.isPodcast, isTrue);
      expect(MediaSource.youtubeMusic.isPodcast, isFalse);
      expect(MediaSource.spotify.isPodcast, isFalse);
    });

    test('appUri is null for the generic Podcasts source', () {
      expect(MediaSource.podcasts.appUri, isNull);
    });

    test('appUri returns expected URIs for non-generic sources', () {
      expect(
        MediaSource.youtubeMusic.appUri,
        Uri.parse('https://music.youtube.com/'),
      );
      expect(
        MediaSource.spotify.appUri,
        Uri.parse('https://open.spotify.com/'),
      );
      expect(MediaSource.pocketCasts.appUri, Uri.parse('https://pca.st/'));
    });

    test('fromWireKey resolves known keys', () {
      for (final s in MediaSource.values) {
        expect(MediaSourceExtension.fromWireKey(s.wireKey), s);
      }
    });

    test('fromWireKey falls back to youtubeMusic for unknown keys', () {
      expect(
        MediaSourceExtension.fromWireKey('mystery-source'),
        MediaSource.youtubeMusic,
      );
      expect(MediaSourceExtension.fromWireKey(''), MediaSource.youtubeMusic);
    });
  });

  group('launchSourceApp', () {
    test('returns false immediately for sources with null appUri', () async {
      // Generic Podcasts has no canonical app — fast path, never hits
      // url_launcher's platform channel.
      expect(await launchSourceApp(MediaSource.podcasts), isFalse);
    });
  });
}
