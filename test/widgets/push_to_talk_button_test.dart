import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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

      final handle = tester.ensureSemantics();
      final id = tester.getSemantics(find.byType(PushToTalkButton)).id;
      tester.binding.pipelineOwner.semanticsOwner!
          .performAction(id, SemanticsAction.tap);
      await tester.pump();
      expect(events, [true, false]);
      handle.dispose();
    });

    testWidgets('semantics onLongPress fires true then false', (tester) async {
      final events = <bool>[];
      await tester.pumpWidget(
        _wrap(PushToTalkButton(holding: false, onChange: events.add)),
      );

      final handle = tester.ensureSemantics();
      final id = tester.getSemantics(find.byType(PushToTalkButton)).id;
      tester.binding.pipelineOwner.semanticsOwner!
          .performAction(id, SemanticsAction.longPress);
      await tester.pump();
      expect(events, [true, false]);
      handle.dispose();
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
