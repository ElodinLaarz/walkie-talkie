import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/discovery_cubit.dart';
import '../bloc/discovery_state.dart';
import '../protocol/discovery.dart';
import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';

class DiscoveryResult {
  final String freq;
  final bool isHost;
  const DiscoveryResult({required this.freq, required this.isHost});
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

  const FrequencyDiscoveryScreen({
    super.key,
    required this.onPick,
    required this.myName,
    required this.onRename,
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
                  label: 'On',
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
                  SectionLabel(
                    text: 'Nearby',
                    trailing: _buildScanIndicator(context),
                  ),
                  _buildNearbyList(context),
                  const SizedBox(height: 14),
                  Center(
                    child: Text(
                      'Using Bluetooth LE Audio · No internet required for voice',
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
                scanning ? 'TUNING THE DIAL' : (hasResults ? 'DISCOVERY PAUSED' : 'NOTHING NEARBY'),
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
                'Phones around you,\non the same wavelength.',
                style: Theme.of(context).textTheme.displayMedium,
              ),
              const SizedBox(height: 10),
              Text(
                'Make a Frequency to chat & listen together, or tune in to one nearby.',
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
    return FreqCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          PrimaryButton(
            label: 'Start a new Frequency',
            icon: Icons.podcasts,
            block: true,
            padding: const EdgeInsets.symmetric(vertical: 14),
            fontSize: 15,
            onPressed: () => widget.onPick(DiscoveryResult(freq: _newFreq, isHost: true)),
          ),
          const SizedBox(height: 10),
          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
              children: [
                const TextSpan(text: 'A fresh channel will be broadcast at '),
                TextSpan(
                  text: '$_newFreq MHz',
                  style: kMonoStyle.copyWith(fontSize: 12, color: c.ink2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanIndicator(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return BlocBuilder<DiscoveryCubit, DiscoveryState>(
      builder: (context, state) {
        final scanning = state is DiscoveryScanning;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (scanning) const PulseDot(size: 6),
            if (scanning) const SizedBox(width: 6),
            Text(
              scanning ? 'Scanning' : 'Idle',
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
                scanning ? 'Pause' : 'Scan',
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

  Widget _buildNearbyList(BuildContext context) {
    return BlocBuilder<DiscoveryCubit, DiscoveryState>(
      builder: (context, state) {
        final sessions = state is DiscoveryScanning 
            ? state.sessions 
            : (state is DiscoveryStopped ? state.sessions : const <DiscoveredSession>[]);
        
        if (sessions.isEmpty) {
          return const SizedBox.shrink();
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
                    ));
                  },
                ),
            ],
          ),
        );
      },
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
                      s.hostName.isEmpty ? 'Unknown Host' : s.hostName,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink,
                      ),
                    ),
                    DefaultTextStyle.merge(
                      style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                      child: Row(
                        children: [
                          const Flexible(
                            child: Text(
                              'Frequency Session',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Text('  ·  '),
                          const Text('On '),
                          Text(s.mhzDisplay, style: kMonoStyle.copyWith(fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SignalBars(rssi: s.rssi),
              if (selected) ...[
                const SizedBox(width: 8),
                FreqButton(
                  accent: true,
                  label: 'Tune in',
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


/// Tappable circular chip in the chrome that shows the user's initials and
/// opens the rename sheet when tapped.
class _IdentityChip extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  const _IdentityChip({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final initials = _initialsOf(name);
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

  static String _initialsOf(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '—';
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
            'Your handle',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          Text(
            'Shows up to everyone on the same frequency.',
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
              decoration: const InputDecoration(
                isDense: true,
                counterText: '',
                border: InputBorder.none,
                hintText: 'Your name',
              ),
            ),
          ),
          const SizedBox(height: 16),
          PrimaryButton(
            label: 'Save',
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
