import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/push_to_talk_button.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('PushToTalkButton', () {
    testWidgets('shows "Hold to talk" label when not holding', (tester) async {
      await tester.pumpWidget(
        _wrap(PushToTalkButton(holding: false, onChange: (_) {})),
      );
      expect(find.text('Hold to talk'), findsOneWidget);
      expect(find.text('On air'), findsNothing);
    });

    testWidgets('shows "On air" label when holding', (tester) async {
      await tester.pumpWidget(
        _wrap(PushToTalkButton(holding: true, onChange: (_) {})),
      );
      expect(find.text('On air'), findsOneWidget);
      expect(find.text('Hold to talk'), findsNothing);
    });

    testWidgets('onChange fires true then false on pointer down/up', (
      tester,
    ) async {
      final events = <bool>[];
      await tester.pumpWidget(
        _wrap(PushToTalkButton(holding: false, onChange: events.add)),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PushToTalkButton)),
      );
      await tester.pump();
      expect(events, [true]);

      await gesture.up();
      await tester.pump();
      expect(events, [true, false]);
    });

    testWidgets('semantics label reflects holding state', (tester) async {
      await tester.pumpWidget(
        _wrap(PushToTalkButton(holding: false, onChange: (_) {})),
      );
      expect(find.bySemanticsLabel('Push to talk'), findsOneWidget);
    });

    testWidgets('semantics onTap fires true then false', (tester) async {
      final events = <bool>[];
      await tester.pumpWidget(
        _wrap(PushToTalkButton(holding: false, onChange: events.add)),
      );

      // tester.semantics is the modern non-deprecated entry point; pair it
      // with `find.semantics.byLabel(...)` to look up the SemanticsNode by
      // its label rather than by widget type.
      tester.semantics.tap(find.semantics.byLabel('Push to talk'));
      await tester.pump();
      expect(events, [true, false]);
    });

    testWidgets('semantics onLongPress fires true then false', (tester) async {
      final events = <bool>[];
      await tester.pumpWidget(
        _wrap(PushToTalkButton(holding: false, onChange: events.add)),
      );

      tester.semantics.longPress(find.semantics.byLabel('Push to talk'));
      await tester.pump();
      expect(events, [true, false]);
    });

    testWidgets('pointer cancel fires false', (tester) async {
      final events = <bool>[];
      await tester.pumpWidget(
        _wrap(PushToTalkButton(holding: false, onChange: events.add)),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PushToTalkButton)),
      );
      await tester.pump();
      expect(events, [true]);

      await gesture.cancel();
      await tester.pump();
      expect(events, [true, false]);
    });
  });
}
