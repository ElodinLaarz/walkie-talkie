import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';

/// Renders the Frequency privacy policy. The canonical text lives in
/// `docs/privacy-policy.md` and is mirrored here so the in-app copy
/// matches the public file. When you edit one, edit the other.
class FrequencyPrivacyPolicyScreen extends StatelessWidget {
  const FrequencyPrivacyPolicyScreen({super.key});

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
                _CloseButton(
                  semanticLabel: l10n.privacyPolicyClose,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                children: [
                  _Header(l10n: l10n),
                  const SizedBox(height: 18),
                  _Body(l10n: l10n),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AppLocalizations l10n;
  const _Header({required this.l10n});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.privacyPolicyEyebrow,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 1.2,
            color: c.ink3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.privacyPolicyHeadline,
          style: Theme.of(context).textTheme.displayMedium,
        ),
        const SizedBox(height: 10),
        Text(
          l10n.privacyPolicyLastUpdated,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: c.ink3),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  final AppLocalizations l10n;
  const _Body({required this.l10n});

  @override
  Widget build(BuildContext context) {
    final sections = <_Section>[
      _Section(
        title: l10n.privacyPolicySectionTldrTitle,
        paragraphs: [
          l10n.privacyPolicySectionTldrBody,
        ],
      ),
      _Section(
        title: l10n.privacyPolicySectionAudioTitle,
        paragraphs: [
          l10n.privacyPolicySectionAudioBody,
        ],
      ),
      _Section(
        title: l10n.privacyPolicySectionBluetoothTitle,
        paragraphs: [
          l10n.privacyPolicySectionBluetoothBody,
        ],
      ),
      _Section(
        title: l10n.privacyPolicySectionStorageTitle,
        paragraphs: [
          l10n.privacyPolicySectionStorageBody,
        ],
      ),
      _Section(
        title: l10n.privacyPolicySectionCrashTitle,
        paragraphs: [
          l10n.privacyPolicySectionCrashBody,
        ],
      ),
      _Section(
        title: l10n.privacyPolicySectionPermissionsTitle,
        paragraphs: [
          l10n.privacyPolicySectionPermissionsBody,
        ],
      ),
      _Section(
        title: l10n.privacyPolicySectionChildrenTitle,
        paragraphs: [
          l10n.privacyPolicySectionChildrenBody,
        ],
      ),
      _Section(
        title: l10n.privacyPolicySectionDeletionTitle,
        paragraphs: [
          l10n.privacyPolicySectionDeletionBody,
        ],
      ),
      _Section(
        title: l10n.privacyPolicySectionContactTitle,
        paragraphs: [
          l10n.privacyPolicySectionContactBody,
        ],
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in sections) ...[
          _SectionView(section: s),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

class _Section {
  final String title;
  final List<String> paragraphs;
  const _Section({required this.title, required this.paragraphs});
}

class _SectionView extends StatelessWidget {
  final _Section section;
  const _SectionView({required this.section});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return FreqCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section.title,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < section.paragraphs.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            Text(
              section.paragraphs[i],
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: c.ink2,
                    height: 1.5,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  final VoidCallback onTap;
  final String semanticLabel;
  const _CloseButton({required this.onTap, required this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Semantics(
              button: true,
              label: semanticLabel,
              child: Icon(Icons.close, size: 20, color: c.ink2),
            ),
          ),
        ),
      ),
    );
  }
}
