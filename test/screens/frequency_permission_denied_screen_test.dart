import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/screens/frequency_permission_denied_screen.dart';
import 'package:walkie_talkie/services/permission_watcher.dart';
import 'package:walkie_talkie/theme/app_theme.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: child,
  );
}

void main() {
  group('FrequencyPermissionDeniedScreen', () {
    testWidgets('renders both denied perms when both are missing',
        (tester) async {
      await tester.pumpWidget(_wrap(FrequencyPermissionDeniedScreen(
        missing: const [AppPermission.microphone, AppPermission.bluetooth],
        onOpenSettings: () async {},
        onRetry: () async {},
      )));

      expect(find.text('Permissions revoked'), findsOneWidget);
      expect(find.text('Microphone'), findsOneWidget);
      expect(find.text('Bluetooth nearby devices'), findsOneWidget);
      // Both rows show the "blocked" hint.
      expect(
        find.text('Blocked — re-enable in system settings'),
        findsNWidgets(2),
      );
      expect(find.text('Open settings'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('shows mic-only copy when only microphone is denied',
        (tester) async {
      await tester.pumpWidget(_wrap(FrequencyPermissionDeniedScreen(
        missing: const [AppPermission.microphone],
        onOpenSettings: () async {},
        onRetry: () async {},
      )));
      expect(find.text('Microphone'), findsOneWidget);
      expect(find.text('Bluetooth nearby devices'), findsNothing);
      expect(
        find.textContaining('needs the microphone'),
        findsOneWidget,
      );
    });

    testWidgets('shows bluetooth-only copy when only bluetooth is denied',
        (tester) async {
      await tester.pumpWidget(_wrap(FrequencyPermissionDeniedScreen(
        missing: const [AppPermission.bluetooth],
        onOpenSettings: () async {},
        onRetry: () async {},
      )));
      expect(find.text('Bluetooth nearby devices'), findsOneWidget);
      expect(find.text('Microphone'), findsNothing);
      expect(
        find.textContaining('needs Bluetooth'),
        findsOneWidget,
      );
    });

    testWidgets('Open settings button invokes the callback', (tester) async {
      var openCalls = 0;
      await tester.pumpWidget(_wrap(FrequencyPermissionDeniedScreen(
        missing: const [AppPermission.microphone],
        onOpenSettings: () async {
          openCalls++;
        },
        onRetry: () async {},
      )));

      await tester.tap(find.text('Open settings'));
      await tester.pump();
      expect(openCalls, 1);
    });

    testWidgets('Retry button invokes the callback', (tester) async {
      var retryCalls = 0;
      await tester.pumpWidget(_wrap(FrequencyPermissionDeniedScreen(
        missing: const [AppPermission.microphone],
        onOpenSettings: () async {},
        onRetry: () async {
          retryCalls++;
        },
      )));

      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(retryCalls, 1);
    });
  });
}
