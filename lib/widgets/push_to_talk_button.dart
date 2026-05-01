import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class PushToTalkButton extends StatelessWidget {
  final bool holding;
  final ValueChanged<bool> onChange;

  const PushToTalkButton({
    super.key,
    required this.holding,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Semantics(
      button: true,
      label: holding ? 'On air' : 'Push to talk',
      hint: 'Press and hold to transmit',
      // Bridge tap-style assistive activation onto the press-and-hold
      // semantics of the visual control. Without these, screen-reader
      // users can focus the button but can't actually transmit.
      onTap: () {
        onChange(true);
        onChange(false);
      },
      onLongPress: () {
        onChange(true);
        onChange(false);
      },
      excludeSemantics: true,
      child: Listener(
        onPointerDown: (_) => onChange(true),
        onPointerUp: (_) => onChange(false),
        onPointerCancel: (_) => onChange(false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: holding ? c.accent : c.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: holding ? Colors.transparent : c.line),
          ),
          constraints: const BoxConstraints(minWidth: 104),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.mic, size: 14, color: holding ? c.accentInk : c.ink),
              const SizedBox(width: 6),
              Text(
                holding ? 'On air' : 'Hold to talk',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: holding ? c.accentInk : c.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
