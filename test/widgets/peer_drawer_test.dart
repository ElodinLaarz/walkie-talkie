import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/data/frequency_models.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/peer_drawer.dart';

/// Minimal host for testing [PeerDrawer] directly outside of a modal sheet.
Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: child),
  );
}

final _person = Person(
  id: 'p1',
  name: 'Alex',
  initials: 'AL',
  hue: 210,
  btDevice: 'AirPods Pro',
);

void main() {
  group('PeerDrawer', () {
    testWidgets('Block & Report button visible when onReport provided (#133)',
        (tester) async {
      await tester.pumpWidget(_wrap(
        PeerDrawer(
          person: _person,
          isHost: false,
          initialVolume: 0.7,
          initialMuted: false,
          onChanged: (_, __) {},
          onRemove: () {},
          onReport: () {},
        ),
      ));

      expect(find.text('Block & Report'), findsOneWidget);
    });

    testWidgets('Block & Report button hidden when onReport is null (#133)',
        (tester) async {
      await tester.pumpWidget(_wrap(
        PeerDrawer(
          person: _person,
          isHost: false,
          initialVolume: 0.7,
          initialMuted: false,
          onChanged: (_, __) {},
          onRemove: () {},
        ),
      ));

      expect(find.text('Block & Report'), findsNothing);
    });

    testWidgets('tapping Block & Report calls onReport callback (#133)',
        (tester) async {
      var reported = false;
      await tester.pumpWidget(_wrap(
        PeerDrawer(
          person: _person,
          isHost: false,
          initialVolume: 0.7,
          initialMuted: false,
          onChanged: (_, __) {},
          onRemove: () {},
          onReport: () => reported = true,
        ),
      ));

      await tester.tap(find.text('Block & Report'));
      await tester.pump();

      expect(reported, isTrue);
    });

    testWidgets('Block & Report does not show Remove section (#133)',
        (tester) async {
      // Non-host: no Remove button, but Block & Report IS shown.
      await tester.pumpWidget(_wrap(
        PeerDrawer(
          person: _person,
          isHost: false,
          initialVolume: 0.7,
          initialMuted: false,
          onChanged: (_, __) {},
          onRemove: () {},
          onReport: () {},
        ),
      ));

      expect(find.text('Remove from frequency'), findsNothing);
      expect(find.text('Block & Report'), findsOneWidget);
    });

    testWidgets('host sees both Remove and Block & Report (#133)',
        (tester) async {
      await tester.pumpWidget(_wrap(
        PeerDrawer(
          person: _person,
          isHost: true,
          initialVolume: 0.7,
          initialMuted: false,
          onChanged: (_, __) {},
          onRemove: () {},
          onReport: () {},
        ),
      ));

      expect(find.text('Remove from frequency'), findsOneWidget);
      expect(find.text('Block & Report'), findsOneWidget);
    });
  });
}
