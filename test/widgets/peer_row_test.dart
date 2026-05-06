import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/data/frequency_models.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/peer_row.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: child),
  );
}

const _person = Person(
  id: 'p1',
  name: 'Sam',
  initials: 'SA',
  hue: 120,
  btDevice: 'Galaxy Buds',
);

void main() {
  group('PeerRow', () {
    testWidgets('renders peer name and device', (tester) async {
      await tester.pumpWidget(
        _wrap(
          PeerRow(
            person: _person,
            first: true,
            talking: false,
            muted: false,
            volume: 0.8,
            onTap: () {},
          ),
        ),
      );
      expect(find.text('Sam'), findsOneWidget);
      expect(find.text('Galaxy Buds'), findsOneWidget);
    });

    testWidgets('shows volume percentage when not talking and not muted', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          PeerRow(
            person: _person,
            first: true,
            talking: false,
            muted: false,
            volume: 0.75,
            onTap: () {},
          ),
        ),
      );
      expect(find.text('75%'), findsOneWidget);
    });

    testWidgets('shows "muted" label when muted', (tester) async {
      await tester.pumpWidget(
        _wrap(
          PeerRow(
            person: _person,
            first: true,
            talking: false,
            muted: true,
            volume: 1.0,
            onTap: () {},
          ),
        ),
      );
      expect(find.text('muted'), findsOneWidget);
    });

    testWidgets('shows "talking" label when talking', (tester) async {
      await tester.pumpWidget(
        _wrap(
          PeerRow(
            person: _person,
            first: true,
            talking: true,
            muted: false,
            volume: 1.0,
            onTap: () {},
          ),
        ),
      );
      expect(find.text('talking'), findsOneWidget);
    });

    testWidgets('onTap fires when tapped', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _wrap(
          PeerRow(
            person: _person,
            first: true,
            talking: false,
            muted: false,
            volume: 1.0,
            onTap: () => tapped = true,
          ),
        ),
      );
      await tester.tap(find.byType(PeerRow));
      await tester.pump();
      expect(tapped, isTrue);
    });
  });
}
