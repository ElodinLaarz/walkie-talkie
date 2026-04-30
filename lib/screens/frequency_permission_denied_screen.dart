import 'dart:async';

import 'package:flutter/material.dart';

import '../services/onboarding_permission_gateway.dart';
import '../services/permission_watcher.dart';
import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';

/// Surfaced when [SessionPermissionDenied] is the active state — the user
/// revoked microphone or Bluetooth from system Settings while the app was
/// running. Explains which permissions were lost, offers a deep-link to
/// system settings, and a Retry button that asks the cubit to re-sample
/// permissions immediately rather than waiting for the next watcher tick.
class FrequencyPermissionDeniedScreen extends StatelessWidget {
  /// Permissions the watcher reported as denied. Order is preserved so
  /// the screen reads top-to-bottom: microphone before Bluetooth.
  final List<AppPermission> missing;

  /// Pulls the user into the system settings app for re-grant. Defaults
  /// to [DefaultOnboardingPermissionGateway.openAppSettings]; tests
  /// inject a fake to assert it was invoked without spinning up the
  /// platform channel.
  final Future<void> Function() onOpenSettings;

  /// Re-checks permissions immediately. Wired to
  /// [FrequencySessionCubit.recheckPermissions] in production so the user
  /// gets snappy feedback after toggling Settings.
  final Future<void> Function() onRetry;

  const FrequencyPermissionDeniedScreen({
    super.key,
    required this.missing,
    required this.onOpenSettings,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        // The screen lays out long-form copy plus two action buttons.
        // [LayoutBuilder] + [SingleChildScrollView] keeps Open settings /
        // Retry pinned to the bottom on tall devices (matching the original
        // [Spacer] layout) but lets the whole stack scroll on small phones
        // or with large accessibility text — without scroll, the action
        // buttons would overflow off-screen and strand the user.
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const FrequencyWordmark(),
                      const SizedBox(height: 36),
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: c.surface2,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        alignment: Alignment.center,
                        child:
                            Icon(Icons.lock_outline, size: 26, color: c.danger),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Permissions revoked',
                        style: Theme.of(context).textTheme.displayLarge,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _explainerCopy(missing),
                        style:
                            Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: c.ink2,
                                ),
                      ),
                      const SizedBox(height: 22),
                      for (final perm in missing) ...[
                        _DeniedRow(perm: perm),
                        const SizedBox(height: 8),
                      ],
                      const Spacer(),
                      PrimaryButton(
                        label: 'Open settings',
                        block: true,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        fontSize: 15,
                        onPressed: () => unawaited(onOpenSettings()),
                      ),
                      const SizedBox(height: 8),
                      FreqButton(
                        label: 'Retry',
                        block: true,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        fontSize: 15,
                        onPressed: () => unawaited(onRetry()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _explainerCopy(List<AppPermission> missing) {
    final hasMic = missing.contains(AppPermission.microphone);
    final hasBt = missing.contains(AppPermission.bluetooth);
    if (hasMic && hasBt) {
      return 'Frequency needs microphone and Bluetooth to keep you on the air. '
          'Re-grant them in Settings to come back.';
    }
    if (hasMic) {
      return 'Frequency needs the microphone to send your voice. '
          'Re-grant it in Settings to come back.';
    }
    return 'Frequency needs Bluetooth to find nearby phones. '
        'Re-grant it in Settings to come back.';
  }
}

class _DeniedRow extends StatelessWidget {
  final AppPermission perm;
  const _DeniedRow({required this.perm});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return FreqCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(_icon(perm), size: 18, color: c.danger),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title(perm),
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                Text(
                  'Blocked — re-enable in system settings',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: c.danger,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData _icon(AppPermission perm) => switch (perm) {
        AppPermission.microphone => Icons.mic_off,
        AppPermission.bluetooth => Icons.bluetooth_disabled,
      };

  static String _title(AppPermission perm) => switch (perm) {
        AppPermission.microphone => 'Microphone',
        AppPermission.bluetooth => 'Bluetooth nearby devices',
      };
}
