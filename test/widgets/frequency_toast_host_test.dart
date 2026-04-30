import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../fixtures/frequency_mock_data.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/frequency_toast_host.dart';

// The host's `Stack` uses `StackFit.passthrough` so it can wrap a Navigator
// (the production placement). In tests we pass small content as the child,
// so wrap it in `SizedBox.expand` to give the host real bounds.
Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: FrequencyToastHost(child: SizedBox.expand(child: child)),
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

      // Wait past the auto-dismiss timer; the toast removes itself from the
      // tree synchronously (no exit animation). The trailing pump just lets
      // the rebuild settle.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
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

  group('FrequencyToastHost in MaterialApp.builder placement', () {
    // Regression for the production wiring in lib/main.dart: the host wraps
    // the navigator via `builder`, so toasts pushed while a modal route is
    // open must still render above the modal's barrier+content. A host
    // placed inside `home` (the previous shape) would render below the
    // modal and these tests would fail.

    Widget builderApp() => MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => FrequencyToastHost(child: child!),
          home: const Scaffold(body: SizedBox.expand()),
        );

    testWidgets('toast pushed before opening a modal sheet remains visible',
        (tester) async {
      await tester.pumpWidget(builderApp());

      // Push a sticky toast from the home route's context.
      final homeContext = tester.element(find.byType(Scaffold));
      FrequencyToastHost.of(homeContext).push(const FrequencyToastSpec(
        title: 'Floating',
        autoDismiss: null,
      ));
      await tester.pump();
      expect(find.text('Floating'), findsOneWidget);

      // Open a modal sheet; the toast must keep rendering.
      unawaited(showModalBottomSheet<void>(
        context: homeContext,
        isScrollControlled: true,
        builder: (_) => const SizedBox(
          height: 200,
          child: Center(child: Text('SheetBody')),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('SheetBody'), findsOneWidget);
      expect(find.text('Floating'), findsOneWidget);
    });

    testWidgets('toast pushed FROM inside a modal sheet renders above it',
        (tester) async {
      await tester.pumpWidget(builderApp());

      final homeContext = tester.element(find.byType(Scaffold));

      // Open a modal sheet whose body can push a toast using its own context
      // (which lives inside the modal route). The host above the navigator
      // must still be reachable via findAncestorStateOfType.
      unawaited(showModalBottomSheet<void>(
        context: homeContext,
        isScrollControlled: true,
        builder: (sheetCtx) => SizedBox(
          height: 200,
          child: Center(
            child: TextButton(
              onPressed: () => FrequencyToastHost.of(sheetCtx).push(
                const FrequencyToastSpec(
                  title: 'FromInsideSheet',
                  autoDismiss: null,
                ),
              ),
              child: const Text('Push toast'),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Push toast'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('FromInsideSheet'), findsOneWidget);

      // The toast's top edge sits above the sheet's top edge. If the host
      // were inside the route, the sheet's overlay would paint over the
      // toast and this comparison would fail.
      final toastTopY =
          tester.getTopLeft(find.text('FromInsideSheet')).dy;
      final sheetTopY = tester.getTopLeft(find.text('Push toast')).dy;
      expect(
        toastTopY,
        lessThan(sheetTopY),
        reason: 'Toast should render above the sheet content.',
      );
    });
  });
}
