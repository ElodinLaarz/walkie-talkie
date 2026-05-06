import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/data/frequency_models.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/queue_sheet.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: child),
  );
}

final _lib = MediaSourceLib(
  name: 'Spotify',
  kind: MediaKind.music,
  queue: [
    const Track(
      title: 'Song Alpha',
      artist: 'Artist A',
      durationSeconds: 180,
      tag: 'a',
    ),
    const Track(
      title: 'Song Beta',
      artist: 'Artist B',
      durationSeconds: 240,
      tag: 'b',
    ),
    const Track(
      title: 'Song Gamma',
      artist: 'Artist C',
      durationSeconds: 300,
      tag: 'c',
    ),
  ],
);

void main() {
  group('QueueSheet', () {
    testWidgets('renders "Shared queue" heading', (tester) async {
      await tester.pumpWidget(
        _wrap(QueueSheet(lib: _lib, currentIdx: 0, onPlay: (_) {})),
      );
      await tester.pump();
      expect(find.text('Shared queue'), findsOneWidget);
    });

    testWidgets('renders all track titles', (tester) async {
      await tester.pumpWidget(
        _wrap(QueueSheet(lib: _lib, currentIdx: 0, onPlay: (_) {})),
      );
      await tester.pump();
      expect(find.text('Song Alpha'), findsOneWidget);
      expect(find.text('Song Beta'), findsOneWidget);
      expect(find.text('Song Gamma'), findsOneWidget);
    });

    testWidgets('onPlay fires with correct index when track tapped', (
      tester,
    ) async {
      int? played;
      await tester.pumpWidget(
        _wrap(QueueSheet(lib: _lib, currentIdx: 0, onPlay: (i) => played = i)),
      );
      await tester.pump();
      await tester.tap(find.text('Song Beta'));
      await tester.pump();
      expect(played, 1);
    });

    testWidgets('Change source button visible when onChangeSource provided', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          QueueSheet(
            lib: _lib,
            currentIdx: 0,
            onPlay: (_) {},
            onChangeSource: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.bySemanticsLabel('Change source'), findsOneWidget);
    });

    testWidgets('Change source button absent when onChangeSource is null', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(QueueSheet(lib: _lib, currentIdx: 0, onPlay: (_) {})),
      );
      await tester.pump();
      expect(find.bySemanticsLabel('Change source'), findsNothing);
    });
  });
}
