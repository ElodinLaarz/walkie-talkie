import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/discovery_cubit.dart';
import '../bloc/discovery_state.dart';
import '../l10n/generated/app_localizations.dart';
import '../l10n/styled_template.dart';
import '../protocol/discovery.dart';
import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';
import 'frequency_explainer_screen.dart';

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

  const DiscoveryResult({
    required this.freq,
    required this.isHost,
    this.macAddress,
    this.sessionUuidLow8,
  })  : assert(
          !isHost || (macAddress == null && sessionUuidLow8 == null),
          'host DiscoveryResult must have null macAddress + sessionUuidLow8 — '
          'the local user IS the host, there is no remote to dial',
        ),
        assert(
          isHost || (macAddress != null && sessionUuidLow8 != null),
          'guest DiscoveryResult must carry both macAddress and sessionUuidLow8 — '
          'the GATT-client transport reads both off the room state to dial the host',
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

  /// Most-recent-first list of frequencies the local user has hosted on
  /// this device. Surfaced as a "Recent" section so the user can re-host
  /// a personal channel with one tap instead of accepting whichever
  /// random frequency the create card happens to have minted this visit.
  /// Empty (the default) hides the section entirely.
  final List<String> recentHostedFrequencies;

  const FrequencyDiscoveryScreen({
    super.key,
    required this.onPick,
    required this.myName,
    required this.onRename,
    this.recentHostedFrequencies = const [],
  });

  @override
  State<FrequencyDiscoveryScreen> createState() => _FrequencyDiscoveryScreenState();
}

class _FrequencyDiscoveryScreenState extends State<FrequencyDiscoveryScreen> {
  String? _selectedId;
  DiscoveryCubit? _cubit;

  late final String _newFreq;
  static const _freqRng = 20;

  @override
  void initState() {
    super.initState();
    final rnd = Random();
    _newFreq = (88 + rnd.nextInt(_freqRng) + 0.1).toStringAsFixed(1);
    
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
                FreqChip(
                  leading: Icon(Icons.bluetooth, size: 12, color: c.ink2),
                  label: l10n.discoveryBluetoothChip,
                ),
                _IdentityChip(
                  name: widget.myName,
                  onTap: _openRenameSheet,
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
              key: ValueKey('recent-${widget.recentHostedFrequencies[i]}'),
              freq: widget.recentHostedFrequencies[i],
              first: i == 0,
              accent: c.accentSoft,
              accentInk: c.accentInk,
              onResume: () => widget.onPick(DiscoveryResult(
                freq: widget.recentHostedFrequencies[i],
                isHost: true,
              )),
            ),
        ],
      ),
    );
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
class _RecentRow extends StatelessWidget {
  final String freq;
  final bool first;
  final Color accent;
  final Color accentInk;
  final VoidCallback onResume;

  const _RecentRow({
    super.key,
    required this.freq,
    required this.first,
    required this.accent,
    required this.accentInk,
    required this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final l10n = AppLocalizations.of(context);
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
                child: Icon(Icons.history, size: 16, color: accentInk),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.discoveryRecentRowTitle,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink,
                      ),
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
                          value: freq,
                          valueStyle: kMonoStyle.copyWith(fontSize: 12),
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
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
          GestureDetector(
            onTap: onShowExplainer,
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
