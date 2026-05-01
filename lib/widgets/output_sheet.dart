import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'frequency_atoms.dart';

enum AudioOutput { bluetooth, earpiece, speaker }

extension AudioOutputExtension on AudioOutput {
  String get label => switch (this) {
        AudioOutput.bluetooth => 'Bluetooth headphones',
        AudioOutput.earpiece => 'Phone earpiece',
        AudioOutput.speaker => 'Phone speaker',
      };

  IconData get icon => switch (this) {
        AudioOutput.bluetooth => Icons.bluetooth,
        AudioOutput.earpiece => Icons.mic_none,
        AudioOutput.speaker => Icons.volume_up,
      };

  String subFor(String bt) => switch (this) {
        AudioOutput.bluetooth => bt.isEmpty ? 'Paired headphones' : bt,
        AudioOutput.earpiece => 'Private, held to ear',
        AudioOutput.speaker => 'Loud · everyone nearby hears',
      };
}

class OutputSheet extends StatelessWidget {
  final AudioOutput current;
  final String btName;

  const OutputSheet({
    super.key,
    required this.current,
    required this.btName,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Play sound on',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                    Text(
                      'Where voice and media come out',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                    ),
                  ],
                ),
              ),
              GhostButton(icon: Icons.close, onPressed: () => Navigator.pop(context)),
            ],
          ),
          const SizedBox(height: 14),
          FreqCard(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (int i = 0; i < AudioOutput.values.length; i++)
                  _OutputRow(
                    output: AudioOutput.values[i],
                    selected: AudioOutput.values[i] == current,
                    first: i == 0,
                    btName: btName,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              "Pair new headphones in your phone's Bluetooth settings.",
              style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
            ),
          ),
        ],
      ),
    );
  }
}

class _OutputRow extends StatelessWidget {
  final AudioOutput output;
  final bool selected;
  final bool first;
  final String btName;

  const _OutputRow({
    required this.output,
    required this.selected,
    required this.first,
    required this.btName,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Material(
      color: selected ? c.surface2 : c.surface,
      child: InkWell(
        onTap: () => Navigator.pop(context, output),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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
                  color: selected ? c.accentSoft : c.surface2,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(
                  output.icon,
                  size: 16,
                  color: selected ? c.accentInk : c.ink2,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      output.label,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink,
                      ),
                    ),
                    Text(
                      output.subFor(btName),
                      style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                    ),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check, size: 16, color: c.accent),
            ],
          ),
        ),
      ),
    );
  }
}
