import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/discovery_cubit.dart';
import '../bloc/discovery_state.dart';
import '../l10n/generated/app_localizations.dart';
import '../l10n/styled_template.dart';
import '../protocol/discovery.dart';
import '../protocol/frequency_session.dart';
import '../services/recent_frequencies_store.dart';
import '../services/settings_store.dart';
import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';
import 'frequency_explainer_screen.dart';
import 'frequency_privacy_policy_screen.dart';
import 'frequency_settings_screen.dart';
import 'security_faq_screen.dart';

/// Key on the Bluetooth-state chip in the discovery chrome. Exposed so widget
/// tests can locate the chip without coupling to its private class name.
const Key discoveryBluetoothChipKey = ValueKey('bluetooth-chip');

class DiscoveryResult {
  final String freq;
  final bool isHost;

  /// BT MAC of the host the user tapped. Null when the user is creating a new
  /// frequency (host path) or resuming a recent — there's no remote host
  /// device to dial in those cases. Populated only when joining as a guest.
  final String? macAddress;

  /// Low 8 bytes of the host's session UUID (hex). Same shape as
  /// [macAddress]: null on the host / Recent paths, populated when tuning in
  /// to a discovered session so the guest can identify the host's room.
  final String? sessionUuidLow8;

  /// Full sessionUuid the user previously hosted, for the Resume path on
  /// a recent row. Plumbed through to [FrequencySessionCubit.joinRoom] as
  /// `existingSessionUuid` so the room reconstitutes the same session
  /// instead of minting a fresh one (#219). Null on the "Start a new
  /// frequency" host path (no prior session) and on the guest path
  /// (guests dial the host's advertised UUID via [sessionUuidLow8]).
  ///
  /// Resume rows recorded before #219 carry `null` here because their
  /// sessionUuid wasn't persisted; the cubit falls back to minting a
  /// fresh UUID for those, so the user gets pre-#219 behaviour for
  /// legacy rows until they re-host.
  final String? hostSessionUuid;

  const DiscoveryResult({
    required this.freq,
    required this.isHost,
    this.macAddress,
    this.sessionUuidLow8,
    this.hostSessionUuid,
  })  : assert(
          !isHost || (macAddress == null && sessionUuidLow8 == null),
          'host DiscoveryResult must have null macAddress + sessionUuidLow8 — '
          'the local user IS the host, there is no remote to dial',
        ),
        assert(
          isHost || (macAddress != null && sessionUuidLow8 != null),
          'guest DiscoveryResult must carry both macAddress and sessionUuidLow8 — '
          'the GATT-client transport reads both off the room state to dial the host',
        ),
        assert(
          hostSessionUuid == null || isHost,
          'hostSessionUuid is only meaningful on the host (Resume) path',
        );
}

/// Discovery — find & join a Frequency.
class FrequencyDiscoveryScreen extends StatefulWidget {
  final ValueChanged<DiscoveryResult> onPick;

  /// Display name shown in the chrome's identity chip. The name is sourced
  /// from the persisted identity store; tapping the chip opens an editor.
  final String myName;

  /// Persists a new display name. The screen invokes this when the user
  /// confirms an edit in the rename sheet.
  final ValueChanged<String> onRename;

  /// Pinned-first then most-recent-first list of frequencies the local
  /// user has hosted on this device. Surfaced as a "Recent" section so
  /// the user can re-host a personal channel with one tap instead of
  /// accepting whichever random frequency the create card happens to
  /// have minted this visit. Each entry carries an optional nickname
  /// and a `pinned` flag so the row can render a label and a pin
  /// affordance. Empty (the default) hides the section entirely.
  final List<RecentFrequency> recentHostedFrequencies;

  /// Persists a nickname change for a recent frequency. Pass `null` (or an
  /// empty string, which the store normalizes to null) to clear the
  /// nickname so the row falls back to the default `discoveryRecentRowTitle`
  /// label. No-op when the freq isn't already in the persisted list.
  final void Function(String freq, String? nickname)? onSetRecentNickname;

  /// Persists a pin/unpin toggle for a recent frequency. Pinned rows float
  /// to the top of the list and are exempt from the cap.
  final void Function(String freq, bool pinned)? onSetRecentPinned;

  /// Deletes a single recent frequency from the persisted list. The row
  /// disappears from the UI immediately on success.
  final void Function(String freq)? onDeleteRecent;

  const FrequencyDiscoveryScreen({
    super.key,
    required this.onPick,
    required this.myName,
    required this.onRename,
    this.recentHostedFrequencies = const [],
    this.onSetRecentNickname,
    this.onSetRecentPinned,
    this.onDeleteRecent,
  });

  @override
  State<FrequencyDiscoveryScreen> createState() => _FrequencyDiscoveryScreenState();
}

class _FrequencyDiscoveryScreenState extends State<FrequencyDiscoveryScreen> {
  String? _selectedId;
  DiscoveryCubit? _cubit;

  late final String _newFreq;

  @override
  void initState() {
    super.initState();
    _newFreq = FrequencySession.randomMhzDisplay(Random());
    
    // Start scanning automatically when entering the screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _cubit?.startDiscovery();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cubit ??= context.read<DiscoveryCubit>();
  }

  @override
  void dispose() {
    // Ensure we stop scanning when leaving the discovery screen.
    if (_cubit != null) unawaited(_cubit!.stopDiscovery());
    super.dispose();
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
                _BluetoothChip(onToggle: _toggleScan),
                _IdentityChip(
                  name: widget.myName,
                  onTap: _openRenameSheet,
                ),
                Tooltip(
                  message: l10n.settingsTooltip,
                  child: IconButton(
                    icon: Icon(Icons.settings_outlined, size: 20, color: c.ink2),
                    onPressed: _openSettings,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                ),
              ],
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                children: [
                  _buildHero(context),
                  const SizedBox(height: 24),
                  _buildCreateCard(context),
                  if (widget.recentHostedFrequencies.isNotEmpty) ...[
                    SectionLabel(text: l10n.discoverySectionRecent),
                    _buildRecentList(context),
                  ],
                  SectionLabel(
                    text: l10n.discoverySectionNearby,
                    trailing: _buildScanIndicator(context),
                  ),
                  _buildNearbyList(context),
                  const SizedBox(height: 14),
                  Center(
                    child: Text(
                      l10n.discoveryFooter,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color: c.ink3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Wrap instead of Row: three links + two separators may
                  // overflow narrow viewports in a single row.
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _FooterLink(
                        label: l10n.discoveryFooterPrivacy,
                        onPressed: _openPrivacyPolicy,
                      ),
                      // Visual separator only — TalkBack would otherwise
                      // announce "dot" between the footer buttons.
                      ExcludeSemantics(
                        child: Text(
                          '·',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            color: c.ink3,
                          ),
                        ),
                      ),
                      _FooterLink(
                        label: l10n.discoveryFooterSecurity,
                        onPressed: _openSecurityFaq,
                      ),
                      ExcludeSemantics(
                        child: Text(
                          '·',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            color: c.ink3,
                          ),
                        ),
                      ),
                      _FooterLink(
                        label: l10n.discoveryFooterLicenses,
                        onPressed: _openLicenses,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHero(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return BlocBuilder<DiscoveryCubit, DiscoveryState>(
      builder: (context, state) {
        final scanning = state is DiscoveryScanning;
        final hasResults = (state is DiscoveryScanning && state.sessions.isNotEmpty) ||
            (state is DiscoveryStopped && state.sessions.isNotEmpty);

        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                scanning
                    ? l10n.discoveryHeroEyebrowScanning
                    : (hasResults
                        ? l10n.discoveryHeroEyebrowPaused
                        : l10n.discoveryHeroEyebrowEmpty),
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
                l10n.discoveryHeroHeadline,
                style: Theme.of(context).textTheme.displayMedium,
              ),
              const SizedBox(height: 10),
              Text(
                l10n.discoveryHeroBody,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.ink2),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCreateCard(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return FreqCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          PrimaryButton(
            label: l10n.discoveryStartFrequency,
            icon: Icons.podcasts,
            block: true,
            padding: const EdgeInsets.symmetric(vertical: 14),
            fontSize: 15,
            onPressed: () => widget.onPick(DiscoveryResult(freq: _newFreq, isHost: true)),
          ),
          const SizedBox(height: 10),
          Text.rich(
            TextSpan(
              style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
              children: styledTemplate(
                template: l10n.discoveryNewFreqHint,
                value: '$_newFreq MHz',
                valueStyle: kMonoStyle.copyWith(fontSize: 12, color: c.ink2),
              ),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildScanIndicator(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return BlocBuilder<DiscoveryCubit, DiscoveryState>(
      builder: (context, state) {
        final scanning = state is DiscoveryScanning;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (scanning) const PulseDot(size: 6),
            if (scanning) const SizedBox(width: 6),
            Text(
              scanning
                  ? l10n.discoveryScanIndicatorScanning
                  : l10n.discoveryScanIndicatorIdle,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                color: scanning ? c.accent : c.ink3,
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                final cubit = context.read<DiscoveryCubit>();
                if (scanning) {
                  cubit.stopDiscovery();
                } else {
                  cubit.startDiscovery();
                }
              },
              child: Text(
                scanning
                    ? l10n.discoveryScanActionPause
                    : l10n.discoveryScanActionScan,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  color: c.ink2,
                  decoration: TextDecoration.underline,
                  decorationColor: c.line,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openRenameSheet() async {
    final c = FrequencyTheme.of(context).colors;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _RenameSheet(initial: widget.myName),
    );
    if (picked != null && picked != widget.myName) {
      widget.onRename(picked);
    }
  }

  Widget _buildRecentList(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return FreqCard(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (int i = 0; i < widget.recentHostedFrequencies.length; i++)
            _RecentRow(
              // Key on freq alone — nickname / pinned can change without
              // the row identity changing, so the framework can reuse the
              // same Element and animate the label / pin badge in place.
              key: ValueKey('recent-${widget.recentHostedFrequencies[i].freq}'),
              entry: widget.recentHostedFrequencies[i],
              first: i == 0,
              accent: c.accentSoft,
              accentInk: c.accentInk,
              onResume: () => widget.onPick(DiscoveryResult(
                freq: widget.recentHostedFrequencies[i].freq,
                isHost: true,
                // Plumb the persisted sessionUuid through so the cubit's
                // host path reuses it instead of minting a fresh one
                // (#219). Null for legacy rows recorded before v4 of the
                // db schema; cubit falls back to minting in that case.
                hostSessionUuid:
                    widget.recentHostedFrequencies[i].sessionUuid,
              )),
              onRename: widget.onSetRecentNickname == null
                  ? null
                  : () => _openRecentNicknameSheet(
                        widget.recentHostedFrequencies[i],
                      ),
              onTogglePin: widget.onSetRecentPinned == null
                  ? null
                  : () => widget.onSetRecentPinned!(
                        widget.recentHostedFrequencies[i].freq,
                        !widget.recentHostedFrequencies[i].pinned,
                      ),
              onDelete: widget.onDeleteRecent == null
                  ? null
                  : () => _confirmAndDeleteRecent(
                        widget.recentHostedFrequencies[i],
                      ),
            ),
        ],
      ),
    );
  }

  /// Bottom-sheet entry point for editing the nickname of a recent
  /// frequency. Returns through `_RecentNicknameSheet`'s pop value, which
  /// signals one of three intents: a new label to set, an explicit clear
  /// of an existing label, or a cancel (no callback fired).
  Future<void> _openRecentNicknameSheet(RecentFrequency entry) async {
    final c = FrequencyTheme.of(context).colors;
    final result = await showModalBottomSheet<_NicknameSheetResult>(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _RecentNicknameSheet(entry: entry),
    );
    if (result == null) return;
    final cb = widget.onSetRecentNickname;
    if (cb == null) return;
    cb(entry.freq, result.nickname);
  }

  /// Deletes [entry] from the persisted recents. Pinned rows show a
  /// confirmation dialog first so the user can't fat-finger away a
  /// curated entry — unpinned rows are removed immediately.
  Future<void> _confirmAndDeleteRecent(RecentFrequency entry) async {
    final cb = widget.onDeleteRecent;
    if (cb == null) return;
    if (entry.pinned) {
      final l10n = AppLocalizations.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(l10n.discoveryRecentDeletePinnedTitle),
          content: Text(l10n.discoveryRecentDeletePinnedBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.discoveryRecentDeleteCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.discoveryRecentDeleteConfirm),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    cb(entry.freq);
  }

  Widget _buildNearbyList(BuildContext context) {
    return BlocBuilder<DiscoveryCubit, DiscoveryState>(
      builder: (context, state) {
        final sessions = state is DiscoveryScanning
            ? state.sessions
            : (state is DiscoveryStopped ? state.sessions : const <DiscoveredSession>[]);

        if (sessions.isEmpty) {
          return _EmptyState(
            onShowExplainer: _openExplainer,
          );
        }

        return FreqCard(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (int i = 0; i < sessions.length; i++)
                _NearbyRow(
                  key: ValueKey(sessions[i].sessionUuidLow8),
                  s: sessions[i],
                  first: i == 0,
                  selected: _selectedId == sessions[i].sessionUuidLow8,
                  onPick: () => setState(() => _selectedId = sessions[i].sessionUuidLow8),
                  onJoin: () {
                    final session = sessions[i];
                    widget.onPick(DiscoveryResult(
                      freq: session.mhzDisplay,
                      isHost: false,
                      macAddress: session.macAddress,
                      sessionUuidLow8: session.sessionUuidLow8,
                    ));
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openExplainer() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FrequencyExplainerScreen(
          onDone: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  void _toggleScan() {
    final cubit = context.read<DiscoveryCubit>();
    if (cubit.state is DiscoveryScanning) {
      cubit.stopDiscovery();
    } else {
      cubit.startDiscovery();
    }
  }

  Future<void> _openSettings() async {
    final store = context.read<SettingsStore>();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FrequencySettingsScreen(settingsStore: store),
      ),
    );
  }

  Future<void> _openPrivacyPolicy() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const FrequencyPrivacyPolicyScreen(),
      ),
    );
  }

  Future<void> _openSecurityFaq() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const SecurityFaqScreen(),
      ),
    );
  }

  void _openLicenses() {
    final l10n = AppLocalizations.of(context);
    // `showLicensePage` builds Flutter's stock LicensePage. The page lazily
    // pulls every entry registered with `LicenseRegistry`, including the
    // native Oboe/Opus entries registered at startup in
    // [registerNativeLicenses], in addition to all dependencies that ship
    // license metadata via pub.
    showLicensePage(
      context: context,
      applicationName: l10n.licensesPageTitle,
      applicationLegalese: l10n.licensesPageLegalese,
    );
  }
}

class _BluetoothChip extends StatelessWidget {
  final VoidCallback onToggle;

  const _BluetoothChip({required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return BlocBuilder<DiscoveryCubit, DiscoveryState>(
      builder: (context, state) {
        final scanning = state is DiscoveryScanning;
        final semanticsLabel = scanning
            ? l10n.discoveryBluetoothChipSemanticsScanning
            : l10n.discoveryBluetoothChipSemanticsIdle;
        return Semantics(
          button: true,
          label: semanticsLabel,
          excludeSemantics: true,
          child: GestureDetector(
            key: discoveryBluetoothChipKey,
            onTap: onToggle,
            child: FreqChip(
              leading: scanning
                  ? PulseDot(size: 8, color: c.accent)
                  : Icon(Icons.bluetooth, size: 12, color: c.ink2),
              label: l10n.discoveryBluetoothChip,
              live: scanning,
            ),
          ),
        );
      },
    );
  }
}

class _FooterLink extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _FooterLink({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(48, 48),
        foregroundColor: c.ink2,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          color: c.ink2,
          decoration: TextDecoration.underline,
          decorationColor: c.line2,
        ),
      ),
    );
  }
}

class _NearbyRow extends StatelessWidget {
  final DiscoveredSession s;
  final bool first;
  final bool selected;
  final VoidCallback onPick;
  final VoidCallback onJoin;

  const _NearbyRow({
    super.key,
    required this.s,
    required this.first,
    required this.selected,
    required this.onPick,
    required this.onJoin,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    // Discovered sessions always have a frequency by definition in v1.
    return Material(
      color: selected ? c.surface2 : c.surface,
      child: InkWell(
        onTap: onPick,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border(
              top: first ? BorderSide.none : BorderSide(color: c.line),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.radio,
                  size: 16,
                  color: c.accentInk,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.hostName.isEmpty ? l10n.discoveryUnknownHost : s.hostName,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink,
                      ),
                    ),
                    Text.rich(
                      TextSpan(
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: c.ink3,
                        ),
                        children: styledTemplate(
                          template: l10n.discoveryNearbyRowSubtitle,
                          value: s.mhzDisplay,
                          valueStyle: kMonoStyle.copyWith(fontSize: 12),
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              SignalBars(rssi: s.rssi),
              if (selected) ...[
                const SizedBox(width: 8),
                FreqButton(
                  accent: true,
                  label: l10n.discoveryTuneIn,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  fontSize: 13,
                  onPressed: onJoin,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}


/// One row in the "Recent" card — a single tappable hit-target that
/// re-hosts the freq when activated. Mirrors `_NearbyRow`'s visual
/// language (icon disc + title + freq mono), but the trailing affordance
/// is a "Resume" hint instead of signal bars + selection state since
/// recents are a one-tap action with no per-row sub-selection.
///
/// When [onRename] / [onTogglePin] are provided, an overflow menu
/// appears between the title and the Resume button so the user can
/// name or pin the recent without leaving Discovery. Both callbacks
/// are nullable so test fixtures (and any embedding that doesn't wire
/// up persistence) can render the row without inventing no-op handlers.
class _RecentRow extends StatelessWidget {
  final RecentFrequency entry;
  final bool first;
  final Color accent;
  final Color accentInk;
  final VoidCallback onResume;
  final VoidCallback? onRename;
  final VoidCallback? onTogglePin;
  final VoidCallback? onDelete;

  const _RecentRow({
    super.key,
    required this.entry,
    required this.first,
    required this.accent,
    required this.accentInk,
    required this.onResume,
    this.onRename,
    this.onTogglePin,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    final hasMenu = onRename != null || onTogglePin != null || onDelete != null;
    final title = entry.nickname ?? l10n.discoveryRecentRowTitle;
    return Material(
      color: c.surface,
      child: InkWell(
        onTap: onResume,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border(
              top: first ? BorderSide.none : BorderSide(color: c.line),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                // Pinned rows trade the generic history glyph for a pin
                // so the user can tell at a glance which recents are
                // user-curated vs auto-recorded.
                child: Icon(
                  entry.pinned ? Icons.push_pin : Icons.history,
                  size: 16,
                  color: accentInk,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: c.ink,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (entry.pinned) ...[
                          const SizedBox(width: 6),
                          _PinnedBadge(),
                        ],
                      ],
                    ),
                    // Text.rich (rather than a Row of Texts) so the
                    // freq + unit string can ellipsize gracefully when
                    // the row is squeezed by a wide Resume button on
                    // narrower phones — a Row would overflow instead.
                    Text.rich(
                      TextSpan(
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: c.ink3,
                        ),
                        children: styledTemplate(
                          template: l10n.discoveryRecentRowHostFreq,
                          value: entry.freq,
                          valueStyle: kMonoStyle.copyWith(fontSize: 12),
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (hasMenu) ...[
                const SizedBox(width: 4),
                _RecentRowMenu(
                  pinned: entry.pinned,
                  onRename: onRename,
                  onTogglePin: onTogglePin,
                  onDelete: onDelete,
                ),
              ],
              const SizedBox(width: 4),
              FreqButton(
                accent: true,
                label: l10n.discoveryRecentRowResume,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                fontSize: 13,
                onPressed: onResume,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact "PINNED" eyebrow shown next to the title of a pinned recent
/// row. Pinned items already lead with a pin icon in the disc, so this
/// is a redundant cue rather than the only one — it exists for users
/// who skim row titles rather than glyphs.
class _PinnedBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        l10n.discoveryRecentPinnedBadge,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: c.accentInk,
        ),
      ),
    );
  }
}

/// Overflow menu attached to a recent row. Renders a `PopupMenuButton`
/// whose items are conditionally included based on which callbacks the
/// parent supplied — a row that opts into rename only (or pin only)
/// doesn't get a stub "no-op" entry.
class _RecentRowMenu extends StatelessWidget {
  final bool pinned;
  final VoidCallback? onRename;
  final VoidCallback? onTogglePin;
  final VoidCallback? onDelete;

  const _RecentRowMenu({
    required this.pinned,
    required this.onRename,
    required this.onTogglePin,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return PopupMenuButton<_RecentRowMenuAction>(
      tooltip: l10n.discoveryRecentRowMenuTooltip,
      icon: Icon(Icons.more_vert, size: 18, color: c.ink2),
      itemBuilder: (_) => [
        if (onRename != null)
          PopupMenuItem<_RecentRowMenuAction>(
            value: _RecentRowMenuAction.rename,
            child: Text(l10n.discoveryRecentMenuRename),
          ),
        if (onTogglePin != null)
          PopupMenuItem<_RecentRowMenuAction>(
            value: _RecentRowMenuAction.togglePin,
            child: Text(
              pinned
                  ? l10n.discoveryRecentMenuUnpin
                  : l10n.discoveryRecentMenuPin,
            ),
          ),
        if (onDelete != null)
          PopupMenuItem<_RecentRowMenuAction>(
            value: _RecentRowMenuAction.delete,
            child: Text(l10n.discoveryRecentMenuDelete),
          ),
      ],
      onSelected: (action) {
        switch (action) {
          case _RecentRowMenuAction.rename:
            onRename?.call();
          case _RecentRowMenuAction.togglePin:
            onTogglePin?.call();
          case _RecentRowMenuAction.delete:
            onDelete?.call();
        }
      },
    );
  }
}

enum _RecentRowMenuAction { rename, togglePin, delete }

/// Result of [_RecentNicknameSheet]'s submission. Wrapped in a class
/// rather than passing a bare `String?` because a null pop value already
/// means "user dismissed without saving" — we need a third state to
/// distinguish "user cleared the existing nickname" from "user closed
/// the sheet."
class _NicknameSheetResult {
  /// New nickname to persist, or `null` to clear an existing one. The
  /// store treats `null` and empty/whitespace-only equivalently, but the
  /// sheet sends `null` explicitly so the intent is unambiguous.
  final String? nickname;

  const _NicknameSheetResult(this.nickname);
}

/// Bottom sheet for editing the nickname of a recent frequency. Same
/// visual language as [_RenameSheet] (the identity rename), but with a
/// secondary "Clear" affordance so a user with an existing nickname can
/// remove it without typing in an empty string and tapping Save.
class _RecentNicknameSheet extends StatefulWidget {
  final RecentFrequency entry;
  const _RecentNicknameSheet({required this.entry});

  @override
  State<_RecentNicknameSheet> createState() => _RecentNicknameSheetState();
}

class _RecentNicknameSheetState extends State<_RecentNicknameSheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.entry.nickname ?? '');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final n = _ctrl.text.trim();
    // An empty submission collapses to "clear the nickname" — the same
    // intent as tapping the Clear button. Pop with an explicit null so
    // the parent's "user closed the sheet" branch (also null) doesn't
    // fire instead.
    Navigator.pop(
      context,
      n.isEmpty ? const _NicknameSheetResult(null) : _NicknameSheetResult(n),
    );
  }

  void _clear() {
    Navigator.pop(context, const _NicknameSheetResult(null));
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    final hasExistingNickname = widget.entry.nickname != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        MediaQuery.of(context).viewInsets.bottom + 28,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 14),
              decoration: BoxDecoration(
                color: c.line2,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Text(
            l10n.discoveryRecentNicknameSheetTitle,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          Text.rich(
            TextSpan(
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                color: c.ink3,
              ),
              children: styledTemplate(
                template: l10n.discoveryRecentNicknameSheetSubtitle,
                value: widget.entry.freq,
                valueStyle: kMonoStyle.copyWith(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 18),
          FreqCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              maxLength: 24,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
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
                hintText: l10n.discoveryRecentNicknameHint,
              ),
            ),
          ),
          const SizedBox(height: 16),
          PrimaryButton(
            label: l10n.discoveryRecentNicknameSheetSave,
            block: true,
            padding: const EdgeInsets.symmetric(vertical: 14),
            fontSize: 15,
            onPressed: _submit,
          ),
          if (hasExistingNickname) ...[
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: _clear,
                style: TextButton.styleFrom(
                  foregroundColor: c.ink2,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                child: Text(
                  l10n.discoveryRecentNicknameSheetClear,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    color: c.ink2,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Tappable circular chip in the chrome that shows the user's initials and
/// opens the rename sheet when tapped.
class _IdentityChip extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  const _IdentityChip({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    final initials = _initialsOf(name, l10n.initialsPlaceholder);
    // Visible chip is 28dp to match the chrome's other affordances; the
    // tappable hit area is 48dp (Material's recommended minimum) via a
    // transparent outer Material+InkWell wrapper.
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
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: c.accentSoft,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                initials,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: c.accentInk,
                  letterSpacing: -0.1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _initialsOf(String name, String emptyPlaceholder) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return emptyPlaceholder;
    return trimmed.substring(0, trimmed.length >= 2 ? 2 : 1).toUpperCase();
  }
}

/// Bottom sheet for editing the persisted display name. Returns the trimmed,
/// non-empty new value via `Navigator.pop`, or null if the user dismisses
/// without saving.
class _RenameSheet extends StatefulWidget {
  final String initial;
  const _RenameSheet({required this.initial});

  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final n = _ctrl.text.trim();
    if (n.isEmpty) return;
    Navigator.pop(context, n);
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    final hasName = _ctrl.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        MediaQuery.of(context).viewInsets.bottom + 28,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 14),
              decoration: BoxDecoration(
                color: c.line2,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Text(
            l10n.renameSheetTitle,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          Text(
            l10n.renameSheetSubtitle,
            style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
          ),
          const SizedBox(height: 18),
          FreqCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              maxLength: 20,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
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
          const SizedBox(height: 16),
          PrimaryButton(
            label: l10n.renameSheetSave,
            block: true,
            padding: const EdgeInsets.symmetric(vertical: 14),
            fontSize: 15,
            onPressed: hasName ? _submit : null,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onShowExplainer;
  const _EmptyState({required this.onShowExplainer});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
    return FreqCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(16),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.search_off,
              size: 28,
              color: c.ink3,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.discoveryEmptyHeadline,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.discoveryEmptyBody,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              color: c.ink2,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: onShowExplainer,
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              foregroundColor: c.accent,
            ),
            child: Text(
              l10n.discoveryEmptyHowItWorks,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: c.accent,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.underline,
                decorationColor: c.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
