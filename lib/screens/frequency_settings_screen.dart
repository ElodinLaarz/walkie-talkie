import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';
import 'frequency_privacy_policy_screen.dart';

/// App settings screen — voice mode, display, privacy, and about.
///
/// All toggles write through to [SettingsStore] immediately on change so
/// preferences survive app restarts without an explicit save action.
class FrequencySettingsScreen extends StatefulWidget {
  final SettingsStore settingsStore;

  const FrequencySettingsScreen({super.key, required this.settingsStore});

  @override
  State<FrequencySettingsScreen> createState() =>
      _FrequencySettingsScreenState();
}

class _FrequencySettingsScreenState extends State<FrequencySettingsScreen> {
  bool _pttMode = false;
  bool _keepScreenOn = false;
  bool _crashReporting = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final ptt = await widget.settingsStore.getPttModeEnabled();
    final keepOn = await widget.settingsStore.getKeepScreenOn();
    final crash = await widget.settingsStore.getCrashReportingEnabled();
    if (!mounted) return;
    setState(() {
      _pttMode = ptt;
      _keepScreenOn = keepOn;
      _crashReporting = crash;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bg,
        foregroundColor: c.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        title: Text(
          l10n.settingsTitle,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: c.ink,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: c.line),
        ),
      ),
      body: _loaded ? _buildBody(context, c, l10n) : const SizedBox.shrink(),
    );
  }

  Widget _buildBody(
    BuildContext context,
    FrequencyColors c,
    AppLocalizations l10n,
  ) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        // Voice
        _SectionHeader(label: l10n.settingsVoiceSection, c: c),
        _SettingsToggle(
          title: l10n.settingsPttMode,
          subtitle: l10n.settingsPttModeDescription,
          value: _pttMode,
          c: c,
          onChanged: (v) async {
            setState(() => _pttMode = v);
            await widget.settingsStore.setPttModeEnabled(v);
          },
        ),
        // Display
        _SectionHeader(label: l10n.settingsDisplaySection, c: c),
        _SettingsToggle(
          title: l10n.settingsKeepScreenOn,
          subtitle: l10n.settingsKeepScreenOnDescription,
          value: _keepScreenOn,
          c: c,
          onChanged: (v) async {
            setState(() => _keepScreenOn = v);
            await widget.settingsStore.setKeepScreenOn(v);
          },
        ),
        // Privacy
        _SectionHeader(label: l10n.settingsPrivacySection, c: c),
        _SettingsToggle(
          title: l10n.settingsCrashReporting,
          subtitle: l10n.settingsCrashReportingDescription,
          value: _crashReporting,
          c: c,
          onChanged: (v) async {
            setState(() => _crashReporting = v);
            await widget.settingsStore.setCrashReportingEnabled(v);
          },
        ),
        // About
        _SectionHeader(label: l10n.settingsAboutSection, c: c),
        _SettingsInfoRow(
          title: l10n.settingsVersion,
          value: '1.0.0',
          c: c,
        ),
        _SettingsLink(
          title: l10n.settingsPrivacyPolicy,
          c: c,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const FrequencyPrivacyPolicyScreen(),
            ),
          ),
        ),
        _SettingsLink(
          title: l10n.settingsLicenses,
          c: c,
          onTap: () => showLicensePage(
            context: context,
            applicationName: l10n.licensesPageTitle,
            applicationLegalese: l10n.licensesPageLegalese,
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final FrequencyColors c;

  const _SectionHeader({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.0,
          color: c.ink3,
        ),
      ),
    );
  }
}

class _SettingsToggle extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final FrequencyColors c;
  final ValueChanged<bool> onChanged;

  const _SettingsToggle({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.c,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      c: c,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        title: Text(
          title,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: c.ink,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            color: c.ink3,
          ),
        ),
        trailing: FreqSwitch(
          value: value,
          semanticLabel: title,
          semanticHint: subtitle,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _SettingsLink extends StatelessWidget {
  final String title;
  final FrequencyColors c;
  final VoidCallback onTap;

  const _SettingsLink({
    required this.title,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      c: c,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        title: Text(
          title,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: c.ink,
          ),
        ),
        trailing: Icon(Icons.chevron_right, color: c.ink3, size: 20),
        onTap: onTap,
      ),
    );
  }
}

class _SettingsInfoRow extends StatelessWidget {
  final String title;
  final String value;
  final FrequencyColors c;

  const _SettingsInfoRow({
    required this.title,
    required this.value,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      c: c,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        title: Text(
          title,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: c.ink,
          ),
        ),
        trailing: Text(
          value,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            color: c.ink3,
          ),
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final Widget child;
  final FrequencyColors c;

  const _SettingsCard({required this.child, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}
