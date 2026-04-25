import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/screens/frequency_onboarding_screen.dart';
import 'package:walkie_talkie/services/onboarding_permission_gateway.dart';
import 'package:walkie_talkie/theme/app_theme.dart';

class _FakeGateway implements OnboardingPermissionGateway {
  OnboardingPermissionStatus btResult;
  OnboardingPermissionStatus micResult;
  int btRequests = 0;
  int micRequests = 0;
  int settingsOpens = 0;

  _FakeGateway({
    this.btResult = OnboardingPermissionStatus.granted,
    this.micResult = OnboardingPermissionStatus.granted,
  });

  @override
  Future<OnboardingPermissionStatus> requestBluetooth() async {
    btRequests++;
    return btResult;
  }

  @override
  Future<OnboardingPermissionStatus> requestMicrophone() async {
    micRequests++;
    return micResult;
  }

  @override
  Future<void> openAppSettings() async {
    settingsOpens++;
  }
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: child,
  );
}

void main() {
  group('FrequencyOnboardingScreen', () {
    testWidgets('happy path: welcome → grant both → name → onDone fires', (tester) async {
      final gateway = _FakeGateway();
      String? doneName;

      await tester.pumpWidget(_wrap(
        FrequencyOnboardingScreen(
          permissionGateway: gateway,
          onDone: (name) => doneName = name,
        ),
      ));

      // Welcome step
      expect(find.text('Get started'), findsOneWidget);
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();

      // Permissions step — Continue is disabled until both granted.
      expect(find.text('Continue'), findsOneWidget);
      expect(gateway.btRequests, 0);

      await tester.tap(find.text('Allow').first);
      await tester.pumpAndSettle();
      expect(gateway.btRequests, 1);
      expect(find.text('Allowed'), findsOneWidget);

      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(gateway.micRequests, 1);
      expect(find.text('Allowed'), findsNWidgets(2));

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      // Name step
      expect(find.text('Find a frequency'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '  Caleb  ');
      await tester.pump();
      await tester.tap(find.text('Find a frequency'));
      await tester.pumpAndSettle();

      expect(doneName, 'Caleb');
    });

    testWidgets('denied permission can be re-requested', (tester) async {
      final gateway = _FakeGateway(btResult: OnboardingPermissionStatus.denied);

      await tester.pumpWidget(_wrap(
        FrequencyOnboardingScreen(
          permissionGateway: gateway,
          onDone: (_) {},
        ),
      ));
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();

      // First request: denied → button should still say Allow.
      await tester.tap(find.text('Allow').first);
      await tester.pumpAndSettle();
      expect(gateway.btRequests, 1);
      expect(find.text('Allow'), findsNWidgets(2));

      // Caller flipped a setting; next attempt grants.
      gateway.btResult = OnboardingPermissionStatus.granted;
      await tester.tap(find.text('Allow').first);
      await tester.pumpAndSettle();
      expect(gateway.btRequests, 2);
      expect(find.text('Allowed'), findsOneWidget);
    });

    testWidgets('permanently-denied permission shows Open settings', (tester) async {
      final gateway = _FakeGateway(
        btResult: OnboardingPermissionStatus.permanentlyDenied,
      );

      await tester.pumpWidget(_wrap(
        FrequencyOnboardingScreen(
          permissionGateway: gateway,
          onDone: (_) {},
        ),
      ));
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Allow').first);
      await tester.pumpAndSettle();

      expect(find.text('Open settings'), findsOneWidget);
      expect(find.text('Blocked — re-enable in system settings'), findsOneWidget);

      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(gateway.settingsOpens, 1);
    });

    testWidgets('Continue stays disabled when only one permission is granted', (tester) async {
      final gateway = _FakeGateway(
        micResult: OnboardingPermissionStatus.denied,
      );
      String? doneName;

      await tester.pumpWidget(_wrap(
        FrequencyOnboardingScreen(
          permissionGateway: gateway,
          onDone: (n) => doneName = n,
        ),
      ));
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();

      // Grant only Bluetooth.
      await tester.tap(find.text('Allow').first);
      await tester.pumpAndSettle();

      // Tapping Continue should not advance.
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Find a frequency'), findsNothing);
      expect(doneName, isNull);
    });

    testWidgets('in-flight request label shows while gateway is pending', (tester) async {
      final completer = Completer<OnboardingPermissionStatus>();
      final gateway = _SlowGateway(completer);

      await tester.pumpWidget(_wrap(
        FrequencyOnboardingScreen(
          permissionGateway: gateway,
          onDone: (_) {},
        ),
      ));
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Allow').first);
      await tester.pump(); // run the future microtask but don't settle

      expect(find.text('Asking…'), findsOneWidget);

      completer.complete(OnboardingPermissionStatus.granted);
      await tester.pumpAndSettle();
      expect(find.text('Asking…'), findsNothing);
      expect(find.text('Allowed'), findsOneWidget);
    });
  });
}

class _SlowGateway implements OnboardingPermissionGateway {
  final Completer<OnboardingPermissionStatus> btCompleter;
  _SlowGateway(this.btCompleter);

  @override
  Future<OnboardingPermissionStatus> requestBluetooth() => btCompleter.future;

  @override
  Future<OnboardingPermissionStatus> requestMicrophone() async =>
      OnboardingPermissionStatus.granted;

  @override
  Future<void> openAppSettings() async {}
}
