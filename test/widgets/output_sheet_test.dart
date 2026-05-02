import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/output_sheet.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: SingleChildScrollView(child: child),
    ),
  );
}

/// Returns the first [Semantics] widget that is an ancestor of the widget
/// matched by [finder] and has a non-null [SemanticsProperties.enabled].
Semantics _rowSemantics(WidgetTester tester, Finder finder) {
  return tester
      .widgetList<Semantics>(
        find.ancestor(of: finder, matching: find.byType(Semantics)),
      )
      .firstWhere((s) => s.properties.enabled != null);
}

void main() {
  group('OutputSheet — BT row availability (#225)', () {
    testWidgets('BT row shows "no headphones" subtitle when btName is empty',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const OutputSheet(current: AudioOutput.speaker, btName: ''),
      ));

      expect(
        find.text('No headphones connected — pair in system Bluetooth settings'),
        findsOneWidget,
      );
    });

    testWidgets('BT row is semantically disabled when btName is empty',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const OutputSheet(current: AudioOutput.speaker, btName: ''),
      ));

      final s = _rowSemantics(tester, find.text('Bluetooth headphones'));
      expect(s.properties.enabled, isFalse);
    });

    testWidgets('BT row shows device name as subtitle when btName is provided',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const OutputSheet(current: AudioOutput.bluetooth, btName: 'AirPods Pro'),
      ));

      expect(find.text('AirPods Pro'), findsOneWidget);
      expect(
        find.text('No headphones connected — pair in system Bluetooth settings'),
        findsNothing,
      );
    });

    testWidgets('BT row is semantically enabled when btName is provided',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const OutputSheet(current: AudioOutput.bluetooth, btName: 'AirPods Pro'),
      ));

      final s = _rowSemantics(tester, find.text('Bluetooth headphones'));
      expect(s.properties.enabled, isTrue);
    });

    testWidgets('speaker and earpiece rows are always semantically enabled',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const OutputSheet(current: AudioOutput.speaker, btName: ''),
      ));

      final speakerS = _rowSemantics(tester, find.text('Phone speaker'));
      expect(speakerS.properties.enabled, isTrue);

      final earpieceS = _rowSemantics(tester, find.text('Phone earpiece'));
      expect(earpieceS.properties.enabled, isTrue);
    });

    testWidgets('check icon absent on BT row when btName is empty',
        (tester) async {
      // Even if _output == bluetooth, the check icon must not render on the
      // BT row when there is no device connected (btName is empty).
      await tester.pumpWidget(_wrap(
        const OutputSheet(current: AudioOutput.bluetooth, btName: ''),
      ));

      // The check icon uses Icons.check; earpiece/speaker rows are not
      // selected, so only the BT row could show it — but btUnavailable.
      expect(find.byIcon(Icons.check), findsNothing);
    });
  });
}
