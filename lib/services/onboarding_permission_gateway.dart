import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:permission_handler/permission_handler.dart' as ph;

/// Tri-state result of a permission request, surfaced to the onboarding UI.
///
/// We collapse `permission_handler`'s richer enum to the three states the UI
/// actually needs — granted, denied (can re-prompt), or permanently denied
/// (must send the user to system settings).
enum OnboardingPermissionStatus { denied, granted, permanentlyDenied }

/// Thin abstraction so the onboarding screen can be tested without spinning
/// up `permission_handler`'s platform channels.
abstract class OnboardingPermissionGateway {
  Future<OnboardingPermissionStatus> requestBluetooth();
  Future<OnboardingPermissionStatus> requestMicrophone();

  /// Query current status without showing a system permission dialog.
  /// Used on screen mount and app-resume to reflect revoked permissions
  /// immediately (e.g. show "Open settings" without requiring a tap first).
  Future<OnboardingPermissionStatus> checkBluetooth();
  Future<OnboardingPermissionStatus> checkMicrophone();

  Future<void> openAppSettings();
}

/// Default implementation backed by the `permission_handler` package.
///
/// Bluetooth on Android 12+ requires three runtime permissions; we ask for
/// all of them together and only report `granted` when every one is granted.
class DefaultOnboardingPermissionGateway
    implements OnboardingPermissionGateway {
  const DefaultOnboardingPermissionGateway();

  static const _bluetoothPermissions = <ph.Permission>[
    ph.Permission.bluetoothScan,
    ph.Permission.bluetoothConnect,
    ph.Permission.bluetoothAdvertise,
  ];

  @override
  Future<OnboardingPermissionStatus> requestBluetooth() async {
    final results = await _bluetoothPermissions.request();
    return reduce(results.values);
  }

  @override
  Future<OnboardingPermissionStatus> requestMicrophone() async {
    final status = await ph.Permission.microphone.request();
    return reduce([status]);
  }

  @override
  Future<OnboardingPermissionStatus> checkBluetooth() async {
    final results = await Future.wait(
      _bluetoothPermissions.map((p) => p.status),
    );
    return reduce(results);
  }

  @override
  Future<OnboardingPermissionStatus> checkMicrophone() async {
    final status = await ph.Permission.microphone.status;
    return reduce([status]);
  }

  @override
  Future<void> openAppSettings() async {
    await ph.openAppSettings();
  }

  @visibleForTesting
  static OnboardingPermissionStatus reduce(
    Iterable<ph.PermissionStatus> values,
  ) {
    if (values.any((s) => s.isPermanentlyDenied)) {
      return OnboardingPermissionStatus.permanentlyDenied;
    }
    if (values.every((s) => s.isGranted || s.isLimited)) {
      return OnboardingPermissionStatus.granted;
    }
    return OnboardingPermissionStatus.denied;
  }
}
