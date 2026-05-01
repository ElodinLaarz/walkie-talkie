import 'package:flutter/material.dart';

import '../data/frequency_models.dart';
import '../theme/app_theme.dart';
import 'frequency_atoms.dart';

class PeerDrawer extends StatefulWidget {
  final Person person;
  final bool isHost;
  final double initialVolume;
  final bool initialMuted;
  final void Function(double volume, bool muted) onChanged;
  final VoidCallback onRemove;

  const PeerDrawer({
    super.key,
    required this.person,
    required this.isHost,
    required this.initialVolume,
    required this.initialMuted,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<PeerDrawer> createState() => _PeerDrawerState();
}

class _PeerDrawerState extends State<PeerDrawer> {
  late double _volume = widget.initialVolume;
  late bool _muted = widget.initialMuted;

  void _emit() => widget.onChanged(_volume, _muted);

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
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
          Row(
            children: [
              FreqAvatar(person: widget.person, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.person.name,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                    Row(
                      children: [
                        Icon(Icons.bluetooth, size: 11, color: c.ink3),
                        const SizedBox(width: 4),
                        Text(
                          widget.person.btDevice,
                          style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              GhostButton(icon: Icons.close, onPressed: () => Navigator.pop(context)),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Mute from your side',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: c.ink,
                        ),
                      ),
                      Text(
                        'Only you stop hearing them',
                        style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                      ),
                    ],
                  ),
                ),
                FreqSwitch(
                  value: _muted,
                  onChanged: (v) {
                    setState(() => _muted = v);
                    _emit();
                  },
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(
                        'Their voice volume',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: c.ink,
                        ),
                      ),
                    ),
                    Text(
                      '${(_volume * 100).round()}%',
                      style: kMonoStyle.copyWith(fontSize: 12, color: c.ink3),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.volume_up, size: 16, color: c.ink3),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Slider(
                        value: _volume,
                        onChanged: (v) {
                          setState(() => _volume = v);
                          _emit();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (widget.isHost) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.only(top: 14),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
              child: Column(
                children: [
                  FreqButton(
                    label: 'Remove from frequency',
                    block: true,
                    labelColor: c.danger,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    onPressed: widget.onRemove,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'As host, only you can remove people.',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
