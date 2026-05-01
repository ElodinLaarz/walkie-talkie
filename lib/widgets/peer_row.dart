import 'package:flutter/material.dart';

import '../data/frequency_models.dart';
import '../theme/app_theme.dart';
import 'frequency_atoms.dart';

class PeerRow extends StatelessWidget {
  final Person person;
  final bool first;
  final bool talking;
  final bool muted;
  final double volume;
  final VoidCallback onTap;

  const PeerRow({
    super.key,
    required this.person,
    required this.first,
    required this.talking,
    required this.muted,
    required this.volume,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Material(
      color: c.surface,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              top: first ? BorderSide.none : BorderSide(color: c.line),
            ),
          ),
          child: Row(
            children: [
              FreqAvatar(person: person, size: 36, talking: talking, muted: muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      person.name,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink,
                      ),
                    ),
                    Row(
                      children: [
                        Icon(Icons.bluetooth, size: 10, color: c.ink3),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            person.btDevice,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12,
                              color: c.ink3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (talking)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    VuMeter(color: c.accent),
                    const SizedBox(width: 5),
                    Text('talking', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.accent)),
                  ],
                )
              else if (muted)
                Text('muted', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3))
              else
                Text(
                  '${(volume * 100).round()}%',
                  style: kMonoStyle.copyWith(fontSize: 11, color: c.ink3),
                ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 16, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}
