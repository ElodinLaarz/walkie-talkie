import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'frequency_atoms.dart';

class InviteSheet extends StatefulWidget {
  final String freq;

  const InviteSheet({
    super.key,
    required this.freq,
  });

  @override
  State<InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<InviteSheet> {
  bool _copied = false;
  Timer? _copiedReset;

  @override
  void dispose() {
    _copiedReset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 8, bottom: 14),
            decoration: BoxDecoration(
              color: c.line2,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          Text(
            'INVITE NEARBY',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.1,
              color: c.ink3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.freq,
            style: kMonoStyle.copyWith(
              fontSize: 48,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.96,
              color: c.ink,
              height: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'MHz · your Frequency',
            style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
          ),
          const SizedBox(height: 20),
          Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.line),
            ),
            padding: const EdgeInsets.all(10),
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 9,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: 81,
              itemBuilder: (_, i) {
                final on = ((i * 37 + 7) % 3) == 0 ||
                    [0, 1, 7, 8, 9, 17, 63, 64, 65, 71, 72].contains(i);
                return Container(
                  decoration: BoxDecoration(
                    color: on ? c.ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          FreqButton(
            block: true,
            icon: _copied ? Icons.check : Icons.copy,
            label: _copied ? 'Copied invite' : 'Copy invite link',
            padding: const EdgeInsets.symmetric(vertical: 12),
            onPressed: () {
              setState(() => _copied = true);
              _copiedReset?.cancel();
              _copiedReset = Timer(const Duration(milliseconds: 1600), () {
                if (mounted) setState(() => _copied = false);
              });
            },
          ),
          const SizedBox(height: 12),
          Text(
            'Anyone within ~30m can tune in.',
            style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
          ),
        ],
      ),
    );
  }
}
