import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/onboarding_permission_gateway.dart';
import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';
import 'frequency_explainer_screen.dart';

/// Total number of steps in the onboarding flow. Surfaces in the chrome
/// indicator (e.g. "01/04"); kept here so adding a step does not require
/// updating the ARB or every locale's translation.
const int _kOnboardingTotalSteps = 4;

/// 4-step onboarding: welcome → explainer → permissions → display name.
class FrequencyOnboardingScreen extends StatefulWidget {
  final ValueChanged<String> onDone;

  /// Override for tests; defaults to the real `permission_handler` gateway.
  final OnboardingPermissionGateway? permissionGateway;

  const FrequencyOnboardingScreen({
    super.key,
    required this.onDone,
    this.permissionGateway,
  });

  @override
  State<FrequencyOnboardingScreen> createState() => _FrequencyOnboardingScreenState();
}

class _FrequencyOnboardingScreenState extends State<FrequencyOnboardingScreen> {
  int _step = 0;
  OnboardingPermissionStatus _btStatus = OnboardingPermissionStatus.denied;
  OnboardingPermissionStatus _micStatus = OnboardingPermissionStatus.denied;
  bool _btRequestInFlight = false;
  bool _micRequestInFlight = false;
  final TextEditingController _nameCtrl = TextEditingController();
  late final OnboardingPermissionGateway _gateway =
      widget.permissionGateway ?? const DefaultOnboardingPermissionGateway();

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  bool get _allGranted =>
      _btStatus == OnboardingPermissionStatus.granted &&
      _micStatus == OnboardingPermissionStatus.granted;

  Future<void> _requestBluetooth() async {
    if (_btRequestInFlight) return;
    setState(() => _btRequestInFlight = true);
    try {
      final result = await _gateway.requestBluetooth();
      if (!mounted) return;
      setState(() => _btStatus = result);
    } finally {
      if (mounted) setState(() => _btRequestInFlight = false);
    }
  }

  Future<void> _requestMicrophone() async {
    if (_micRequestInFlight) return;
    setState(() => _micRequestInFlight = true);
    try {
      final result = await _gateway.requestMicrophone();
      if (!mounted) return;
      setState(() => _micStatus = result);
    } finally {
      if (mounted) setState(() => _micRequestInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            FreqChrome(
              left: const FrequencyWordmark(),
              right: [
                Text(
                  l10n.onboardingStepIndicator(
                    (_step + 1).toString().padLeft(2, '0'),
                    _kOnboardingTotalSteps.toString().padLeft(2, '0'),
                  ),
                  style: kMonoStyle.copyWith(fontSize: 11, color: c.ink3),
                ),
              ],
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                child: KeyedSubtree(
                  key: ValueKey(_step),
                  child: _buildStep(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context) {
    switch (_step) {
      case 0:
        return _Welcome(onNext: () => setState(() => _step = 1));
      case 1:
        return FrequencyExplainerScreen(
          onDone: () => setState(() => _step = 2),
          embedded: true,
        );
      case 2:
        return _Permissions(
          btStatus: _btStatus,
          micStatus: _micStatus,
          btInFlight: _btRequestInFlight,
          micInFlight: _micRequestInFlight,
          onRequestBt: _requestBluetooth,
          onRequestMic: _requestMicrophone,
          onOpenSettings: _gateway.openAppSettings,
          onContinue: _allGranted ? () => setState(() => _step = 3) : null,
        );
      default:
        return _NamePicker(
          controller: _nameCtrl,
          onContinue: () {
            final n = _nameCtrl.text.trim();
            if (n.isNotEmpty) widget.onDone(n);
          },
        );
    }
  }
}

class _Welcome extends StatelessWidget {
  final VoidCallback onNext;
  const _Welcome({required this.onNext});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(18),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.podcasts_outlined, size: 32, color: c.accentInk),
          ),
          const SizedBox(height: 20),
          Text(
            l10n.onboardingWelcomeHeadline,
            style: Theme.of(context).textTheme.displayLarge,
          ),
          const SizedBox(height: 14),
          Text(
            l10n.onboardingWelcomeBody,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.ink2),
          ),
          const Spacer(),
          PrimaryButton(
            label: l10n.onboardingGetStarted,
            block: true,
            padding: const EdgeInsets.symmetric(vertical: 14),
            fontSize: 15,
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

class _Permissions extends StatelessWidget {
  final OnboardingPermissionStatus btStatus;
  final OnboardingPermissionStatus micStatus;
  final bool btInFlight;
  final bool micInFlight;
  final VoidCallback onRequestBt;
  final VoidCallback onRequestMic;
  final Future<void> Function() onOpenSettings;
  final VoidCallback? onContinue;

  const _Permissions({
    required this.btStatus,
    required this.micStatus,
    required this.btInFlight,
    required this.micInFlight,
    required this.onRequestBt,
    required this.onRequestMic,
    required this.onOpenSettings,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Text(
            l10n.onboardingPermissionsEyebrow,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.1,
              color: c.ink3,
            ),
          ),
          const SizedBox(height: 6),
          Text(l10n.onboardingPermissionsHeadline, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            l10n.onboardingPermissionsBody,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.ink2),
          ),
          const SizedBox(height: 24),
          _PermRow(
            icon: Icons.bluetooth,
            title: l10n.permissionBluetoothTitle,
            desc: l10n.permissionBluetoothDescription,
            status: btStatus,
            inFlight: btInFlight,
            onAllow: onRequestBt,
            onOpenSettings: onOpenSettings,
          ),
          const SizedBox(height: 10),
          _PermRow(
            icon: Icons.mic_none,
            title: l10n.permissionMicrophoneTitle,
            desc: l10n.permissionMicrophoneDescription,
            status: micStatus,
            inFlight: micInFlight,
            onAllow: onRequestMic,
            onOpenSettings: onOpenSettings,
          ),
          const Spacer(),
          PrimaryButton(
            label: l10n.onboardingContinue,
            block: true,
            padding: const EdgeInsets.symmetric(vertical: 14),
            fontSize: 15,
            onPressed: onContinue,
          ),
        ],
      ),
    );
  }
}

class _PermRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;
  final OnboardingPermissionStatus status;
  final bool inFlight;
  final VoidCallback onAllow;
  final Future<void> Function() onOpenSettings;
  const _PermRow({
    required this.icon,
    required this.title,
    required this.desc,
    required this.status,
    required this.inFlight,
    required this.onAllow,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    final granted = status == OnboardingPermissionStatus.granted;
    final permanentlyDenied = status == OnboardingPermissionStatus.permanentlyDenied;
    final effectiveDesc = permanentlyDenied
        ? l10n.permissionBlockedDescription
        : desc;
    return FreqCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: granted ? c.accentSoft : c.surface2,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(
              granted ? Icons.check : icon,
              size: 18,
              color: granted
                  ? c.accentInk
                  : permanentlyDenied
                      ? c.danger
                      : c.ink2,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                Text(
                  effectiveDesc,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: permanentlyDenied ? c.danger : c.ink3,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (granted)
            Text(
              l10n.permissionStatusAllowed,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                color: c.accent,
                fontWeight: FontWeight.w500,
              ),
            )
          else if (permanentlyDenied)
            FreqButton(
              label: l10n.permissionOpenSettings,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              fontSize: 13,
              onPressed: () => unawaited(onOpenSettings()),
            )
          else
            FreqButton(
              label: inFlight ? l10n.permissionAsking : l10n.permissionAllow,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              fontSize: 13,
              onPressed: inFlight ? null : onAllow,
            ),
        ],
      ),
    );
  }
}

class _NamePicker extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onContinue;
  const _NamePicker({required this.controller, required this.onContinue});

  @override
  State<_NamePicker> createState() => _NamePickerState();
}

class _NamePickerState extends State<_NamePicker> {
  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    final name = widget.controller.text.trim();
    final initials = name.isEmpty
        ? l10n.initialsPlaceholder
        : name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
    final hasName = name.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Text(
            l10n.onboardingHandleEyebrow,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.1,
              color: c.ink3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.onboardingHandleHeadline,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.onboardingHandleBody,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.ink2),
          ),
          const SizedBox(height: 28),
          FreqCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: c.accentSoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    initials,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.accentInk,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    autofocus: true,
                    maxLength: 20,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      if (hasName) widget.onContinue();
                    },
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: c.ink,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      counterText: '',
                      border: InputBorder.none,
                      hintText: l10n.onboardingHandleHint,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              l10n.onboardingHandleFootnote,
              style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
            ),
          ),
          const Spacer(),
          PrimaryButton(
            label: l10n.onboardingFindFrequency,
            block: true,
            padding: const EdgeInsets.symmetric(vertical: 14),
            fontSize: 15,
            onPressed: hasName ? widget.onContinue : null,
          ),
        ],
      ),
    );
  }
}
