import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/data/frequency_mock_data.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/frequency_toast_host.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: FrequencyToastHost(child: child),
      ),
    );

void main() {
  group('FrequencyToastHost', () {
    testWidgets('renders nothing until something is pushed', (tester) async {
      await tester.pumpWidget(_wrap(const SizedBox()));
      await tester.pump();
      expect(find.byType(FrequencyToastHost), findsOneWidget);
      expect(find.text('hello'), findsNothing);
    });

    testWidgets('push surfaces title and optional description', (tester) async {
      late FrequencyToastController toast;
      await tester.pumpWidget(_wrap(
        Builder(builder: (context) {
          toast = FrequencyToastHost.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pump();

      toast.push(const FrequencyToastSpec(
        title: 'Maya joined',
        description: 'Right nearby',
        autoDismiss: null,
      ));
      await tester.pump();

      expect(find.text('Maya joined'), findsOneWidget);
      expect(find.text('Right nearby'), findsOneWidget);
    });

    testWidgets('auto-dismiss removes the toast after the configured duration',
        (tester) async {
      late FrequencyToastController toast;
      await tester.pumpWidget(_wrap(
        Builder(builder: (context) {
          toast = FrequencyToastHost.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pump();

      toast.push(const FrequencyToastSpec(
        title: 'Temporary',
        autoDismiss: Duration(milliseconds: 500),
      ));
      await tester.pump();
      expect(find.text('Temporary'), findsOneWidget);

      // Past auto-dismiss + entry animation.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 400)); // exit animation
      expect(find.text('Temporary'), findsNothing);
    });

    testWidgets('autoDismiss: null keeps the toast sticky', (tester) async {
      late FrequencyToastController toast;
      await tester.pumpWidget(_wrap(
        Builder(builder: (context) {
          toast = FrequencyToastHost.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pump();

      toast.push(const FrequencyToastSpec(
        title: 'Sticky',
        autoDismiss: null,
      ));
      await tester.pump();

      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Sticky'), findsOneWidget);
    });

    testWidgets('action button fires its callback and dismisses the toast',
        (tester) async {
      late FrequencyToastController toast;
      var letInTaps = 0;
      await tester.pumpWidget(_wrap(
        Builder(builder: (context) {
          toast = FrequencyToastHost.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pump();

      toast.push(FrequencyToastSpec(
        title: 'Devon wants to tune in',
        autoDismiss: null,
        actions: [
          ToastAction(label: 'Deny', onTap: () {}),
          ToastAction(label: 'Let in', primary: true, onTap: () => letInTaps++),
        ],
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Let in'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(letInTaps, 1);
      expect(find.text('Devon wants to tune in'), findsNothing);
    });

    testWidgets('manual dismiss via the close icon removes the toast',
        (tester) async {
      late FrequencyToastController toast;
      await tester.pumpWidget(_wrap(
        Builder(builder: (context) {
          toast = FrequencyToastHost.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pump();

      toast.push(const FrequencyToastSpec(
        title: 'Closeable',
        autoDismiss: null,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Closeable'), findsNothing);
    });

    testWidgets('multiple toasts stack in push order', (tester) async {
      late FrequencyToastController toast;
      await tester.pumpWidget(_wrap(
        Builder(builder: (context) {
          toast = FrequencyToastHost.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pump();

      toast.push(const FrequencyToastSpec(title: 'First', autoDismiss: null));
      toast.push(const FrequencyToastSpec(title: 'Second', autoDismiss: null));
      await tester.pump();

      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
    });

    testWidgets('person-bearing toasts render the avatar', (tester) async {
      late FrequencyToastController toast;
      await tester.pumpWidget(_wrap(
        Builder(builder: (context) {
          toast = FrequencyToastHost.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pump();

      toast.push(FrequencyToastSpec(
        title: 'Maya joined the frequency',
        person: kPeople[1], // Maya
        autoDismiss: null,
      ));
      await tester.pump();

      // Avatar paints initials; Maya's are 'MA'.
      expect(find.text('MA'), findsOneWidget);
    });
  });
}
