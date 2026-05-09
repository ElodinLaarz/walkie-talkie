import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/data/frequency_models.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/now_playing_card.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

const _track = Track(
  title: 'Blue Ridge Mountains',
  artist: 'Fleet Foxes',
  durationSeconds: 240,
  tag: 'fleet-foxes-blue-ridge',
);

const _idleTrack = Track(
  title: 'Nothing playing',
  artist: '—',
  durationSeconds: 0,
  tag: '',
);

NowPlayingCard _card({
  Track track = _track,
  bool playing = false,
  int progress = 0,
  String source = 'spotify',
  VoidCallback? onPlay,
  VoidCallback? onNext,
  VoidCallback? onPrev,
  VoidCallback? onOpenQueue,
  ValueChanged<double>? onScrub,
  VoidCallback? onChangeSource,
}) {
  return NowPlayingCard(
    track: track,
    source: source,
    isPodcast: false,
    playing: playing,
    progress: progress,
    lastActionBy: 'Alex',
    lastActionWhat: 'added this',
    lastActionWhen: '2m ago',
    onPlay: onPlay ?? () {},
    onNext: onNext ?? () {},
    onPrev: onPrev ?? () {},
    onScrub: onScrub ?? (_) {},
    onOpenQueue: onOpenQueue ?? () {},
    onChangeSource: onChangeSource,
  );
}

void main() {
  group('NowPlayingCard', () {
    testWidgets('renders track title and artist', (tester) async {
      await tester.pumpWidget(_wrap(_card()));
      expect(find.text('Blue Ridge Mountains'), findsOneWidget);
      expect(find.text('Fleet Foxes'), findsOneWidget);
    });

    testWidgets('shows Play semantics when not playing', (tester) async {
      await tester.pumpWidget(_wrap(_card(playing: false)));
      await tester.pump();
      expect(find.bySemanticsLabel('Play'), findsOneWidget);
    });

    testWidgets('shows Pause semantics when playing', (tester) async {
      await tester.pumpWidget(_wrap(_card(playing: true)));
      await tester.pump();
      expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    });

    testWidgets('onPlay fires when play circle tapped', (tester) async {
      var played = false;
      await tester.pumpWidget(_wrap(_card(onPlay: () => played = true)));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Play'));
      await tester.pump();
      expect(played, isTrue);
    });

    testWidgets('onNext fires when next button tapped', (tester) async {
      var nextCalled = false;
      await tester.pumpWidget(_wrap(_card(onNext: () => nextCalled = true)));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Next track'));
      await tester.pump();
      expect(nextCalled, isTrue);
    });

    testWidgets('idle track skips Slider (no assertion on max==0)', (
      tester,
    ) async {
      // NowPlayingCard guards durationSeconds<=0; this must not throw.
      await tester.pumpWidget(_wrap(_card(track: _idleTrack)));
      await tester.pump();
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('last-action attribution row is rendered', (tester) async {
      await tester.pumpWidget(_wrap(_card()));
      await tester.pump();
      // lastActionWhen is a plain Text; lastActionBy/What are RichText spans.
      expect(find.text('2m ago'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is RichText &&
              w.text.toPlainText().contains('Alex') &&
              w.text.toPlainText().contains('added this'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('guest: no source chip, shows plain text label', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_card(source: 'spotify')));
      await tester.pump();
      expect(
        find.bySemanticsLabel(RegExp(r'Change source', caseSensitive: false)),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').contains('SPOTIFY'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('host: source chip shows source label', (tester) async {
      await tester.pumpWidget(
        _wrap(_card(source: 'spotify', onChangeSource: () {})),
      );
      await tester.pump();
      expect(
        find.bySemanticsLabel(RegExp(r'Change source.*Spotify')),
        findsOneWidget,
      );
      expect(find.text('SPOTIFY'), findsOneWidget);
    });

    testWidgets('host: tapping source chip fires onChangeSource', (
      tester,
    ) async {
      var called = false;
      await tester.pumpWidget(
        _wrap(_card(source: 'spotify', onChangeSource: () => called = true)),
      );
      await tester.pump();
      await tester.tap(
        find.bySemanticsLabel(RegExp(r'Change source.*Spotify')),
      );
      await tester.pump();
      expect(called, isTrue);
    });
  });
}
