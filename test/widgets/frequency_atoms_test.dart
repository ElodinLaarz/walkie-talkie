import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/data/frequency_models.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/frequency_atoms.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: Center(child: child)),
  );
}

const _person = Person(
  id: 'p1',
  name: 'Jordan',
  initials: 'JO',
  hue: 200,
  btDevice: 'Pixel Buds',
);

void main() {
  group('FreqChip', () {
    testWidgets('renders label text', (tester) async {
      await tester.pumpWidget(_wrap(const FreqChip(label: 'Paused')));
      expect(find.text('Paused'), findsOneWidget);
    });

    testWidgets('live=true uses accent semantics label', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const FreqChip(label: 'Live', live: true, semanticLabel: 'On air'),
        ),
      );
      expect(find.bySemanticsLabel('On air'), findsOneWidget);
    });
  });

  group('FreqAvatar', () {
    testWidgets('renders initials', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const FreqAvatar(
            person: _person,
            size: 40,
            talking: false,
            muted: false,
          ),
        ),
      );
      expect(find.text('JO'), findsOneWidget);
    });

    testWidgets('semantics include name', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const FreqAvatar(
            person: _person,
            size: 40,
            talking: false,
            muted: false,
          ),
        ),
      );
      expect(find.bySemanticsLabel(RegExp('Jordan')), findsOneWidget);
    });

    testWidgets('semantics append "talking" when talking=true', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const FreqAvatar(
            person: _person,
            size: 40,
            talking: true,
            muted: false,
          ),
        ),
      );
      expect(find.bySemanticsLabel(RegExp('talking')), findsOneWidget);
    });

    testWidgets('semantics append "muted" when muted=true', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const FreqAvatar(
            person: _person,
            size: 40,
            talking: false,
            muted: true,
          ),
        ),
      );
      expect(find.bySemanticsLabel(RegExp('muted')), findsOneWidget);
    });
  });

  group('VuMeter', () {
    testWidgets('renders without error when active', (tester) async {
      await tester.pumpWidget(_wrap(const VuMeter(active: true)));
      await tester.pump(const Duration(milliseconds: 100));
      // No assertion needed — just must not throw.
    });

    testWidgets('renders without error when inactive', (tester) async {
      await tester.pumpWidget(_wrap(const VuMeter(active: false)));
      await tester.pump();
    });
  });

  group('FreqSwitch', () {
    Semantics switchSemantics(WidgetTester tester) {
      return tester.widget<Semantics>(
        find
            .descendant(
              of: find.byType(FreqSwitch),
              matching: find.byType(Semantics),
            )
            .first,
      );
    }

    testWidgets('reports toggled=false when value is false', (tester) async {
      await tester.pumpWidget(
        _wrap(
          FreqSwitch(value: false, onChanged: (_) {}, semanticLabel: 'Mute'),
        ),
      );
      expect(switchSemantics(tester).properties.toggled, isFalse);
    });

    testWidgets('reports toggled=true when value is true', (tester) async {
      await tester.pumpWidget(
        _wrap(
          FreqSwitch(value: true, onChanged: (_) {}, semanticLabel: 'Mute'),
        ),
      );
      expect(switchSemantics(tester).properties.toggled, isTrue);
    });

    testWidgets('toggles value when tapped', (tester) async {
      bool? toggled;
      await tester.pumpWidget(
        _wrap(
          FreqSwitch(
            value: false,
            onChanged: (v) => toggled = v,
            semanticLabel: 'Mute',
          ),
        ),
      );
      await tester.tap(find.byType(FreqSwitch));
      await tester.pump();
      expect(toggled, isTrue);
    });

    testWidgets('disabled when onChanged is null', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const FreqSwitch(
            value: false,
            onChanged: null,
            semanticLabel: 'Mute',
          ),
        ),
      );
      expect(switchSemantics(tester).properties.enabled, isFalse);
    });
  });

  group('SignalBars', () {
    testWidgets('renders for strong signal (rssi -50)', (tester) async {
      await tester.pumpWidget(_wrap(const SignalBars(rssi: -50)));
      expect(find.byType(SignalBars), findsOneWidget);
    });

    testWidgets('renders for weak signal (rssi -100)', (tester) async {
      await tester.pumpWidget(_wrap(const SignalBars(rssi: -100)));
      expect(find.byType(SignalBars), findsOneWidget);
    });
  });
}
