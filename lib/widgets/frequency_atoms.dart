import 'package:flutter/material.dart';

import '../data/frequency_mock_data.dart';
import '../theme/app_theme.dart';

/// "Frequency • dot" wordmark.
class FrequencyWordmark extends StatelessWidget {
  const FrequencyWordmark({super.key});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: c.accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'Frequency',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.15,
            color: c.ink,
          ),
        ),
      ],
    );
  }
}

/// Pill chip used in the chrome bar.
class FreqChip extends StatelessWidget {
  final Widget? leading;
  final String label;
  final bool live;
  const FreqChip({super.key, this.leading, required this.label, this.live = false});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final bg = live ? c.accentSoft : c.surface2;
    final fg = live ? c.accentInk : c.ink2;
    final border = live ? Colors.transparent : c.line;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 6)],
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              color: fg,
              letterSpacing: 0.22,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// A pulsing dot that radiates outward — used for "On air" and "Scanning".
class PulseDot extends StatefulWidget {
  final Color? color;
  final double size;
  const PulseDot({super.key, this.color, this.size = 6});

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final color = widget.color ?? c.accent;
    return SizedBox(
      width: widget.size + 16,
      height: widget.size + 16,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final t = _ctrl.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: (1 - t).clamp(0.0, 1.0) * 0.6,
                child: Container(
                  width: widget.size + 16 * t,
                  height: widget.size + 16 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.4),
                  ),
                ),
              ),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Avatar — initials on a hue-tinted square.
class FreqAvatar extends StatelessWidget {
  final Person person;
  final double size;
  final bool talking;
  final bool muted;

  const FreqAvatar({
    super.key,
    required this.person,
    this.size = 40,
    this.talking = false,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final radius = size < 32 ? 8.0 : 12.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: hueColor(person.hue),
              borderRadius: BorderRadius.circular(radius),
            ),
            alignment: Alignment.center,
            child: Text(
              person.initials,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: size * 0.36,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: hueInk(person.hue),
              ),
            ),
          ),
          if (talking)
            Positioned.fill(
              child: IgnorePointer(
                child: _TalkRing(radius: radius + 2, color: c.accent),
              ),
            ),
          if (muted)
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                width: size * 0.45,
                height: size * 0.45,
                decoration: BoxDecoration(
                  color: c.ink,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.bg, width: 2),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.mic_off, size: size * 0.26, color: c.bg),
              ),
            ),
        ],
      ),
    );
  }
}

class _TalkRing extends StatefulWidget {
  final double radius;
  final Color color;
  const _TalkRing({required this.radius, required this.color});

  @override
  State<_TalkRing> createState() => _TalkRingState();
}

class _TalkRingState extends State<_TalkRing> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        final t = _ctrl.value;
        final scale = 0.96 + 0.16 * t;
        final double opacity = ((1 - t).clamp(0.0, 1.0) * 0.9).toDouble();
        return Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.radius),
                border: Border.all(color: widget.color, width: 2),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// VU meter — four bouncing bars.
class VuMeter extends StatefulWidget {
  final Color? color;
  final bool active;
  const VuMeter({super.key, this.color, this.active = true});

  @override
  State<VuMeter> createState() => _VuMeterState();
}

class _VuMeterState extends State<VuMeter> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  static const _heights = [0.40, 0.90, 0.55, 0.75];
  static const _delays = [0.0, 0.167, 0.333, 0.5];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final color = widget.color ?? c.accent;

    if (!widget.active) {
      return SizedBox(
        height: 14,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(4, (i) => _bar(0.30, c.ink3, i)),
        ),
      );
    }

    return SizedBox(
      height: 14,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(4, (i) {
              final phase = (_ctrl.value + _delays[i]) % 1.0;
              final s = 0.5 + 0.5 * (1 - (2 * phase - 1).abs());
              return _bar(_heights[i] * s, color, i);
            }),
          );
        },
      ),
    );
  }

  Widget _bar(double heightFraction, Color color, int i) {
    final double h = 14.0 * heightFraction.clamp(0.15, 1.0).toDouble();
    return Padding(
      padding: EdgeInsets.only(left: i == 0 ? 0 : 2),
      child: Container(
        width: 2.5,
        height: h,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

/// 4-bar signal-strength indicator (driven from RSSI).
class SignalBars extends StatelessWidget {
  final int rssi;
  const SignalBars({super.key, required this.rssi});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final strength = (4 - (rssi.abs() - 40) / 12).round().clamp(0, 4);
    return SizedBox(
      height: 12,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(4, (i) {
          final on = (i + 1) <= strength;
          return Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : 2),
            child: Container(
              width: 3,
              height: 3.0 + (i + 1) * 2,
              decoration: BoxDecoration(
                color: on ? c.ink : c.line2,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Compact pill toggle — same shape as the design's `.switch`.
class FreqSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const FreqSwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 36,
        height: 20,
        decoration: BoxDecoration(
          color: value ? c.accent : c.line2,
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bordered card surface used throughout.
class FreqCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Clip clipBehavior;
  const FreqCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(0),
    this.clipBehavior = Clip.none,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Container(
      padding: padding,
      clipBehavior: clipBehavior,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.line),
      ),
      child: child,
    );
  }
}

/// Section label (uppercase, tracked).
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel({super.key, required this.text, this.trailing});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.88,
                color: c.ink3,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Primary button (filled with --ink).
class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final EdgeInsets padding;
  final double fontSize;
  final bool block;
  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.fontSize = 14,
    this.block = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final disabled = onPressed == null;
    final child = Row(
      mainAxisSize: block ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: c.bg),
          const SizedBox(width: 8),
        ],
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w500,
            fontSize: fontSize,
            color: c.bg,
          ),
        ),
      ],
    );
    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: Material(
        color: c.ink,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Outlined "ghost" button.
class GhostButton extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final EdgeInsets padding;
  final Color? color;
  const GhostButton({
    super.key,
    this.label,
    this.icon,
    this.onPressed,
    this.padding = const EdgeInsets.all(8),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final fg = color ?? c.ink2;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: padding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) Icon(icon, size: 16, color: fg),
              if (icon != null && label != null) const SizedBox(width: 6),
              if (label != null)
                Text(
                  label!,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Outlined button with surface fill.
class FreqButton extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final EdgeInsets padding;
  final double fontSize;
  final bool block;
  final Color? labelColor;
  final bool accent;

  const FreqButton({
    super.key,
    this.label,
    this.icon,
    this.onPressed,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.fontSize = 14,
    this.block = false,
    this.labelColor,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final bg = accent ? c.accent : c.surface;
    final fg = accent ? c.accentInk : (labelColor ?? c.ink);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accent ? Colors.transparent : c.line),
          ),
          child: Row(
            mainAxisSize: block ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: fg),
                if (label != null) const SizedBox(width: 8),
              ],
              if (label != null)
                Text(
                  label!,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: accent ? FontWeight.w600 : FontWeight.w500,
                    fontSize: fontSize,
                    color: fg,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Top "chrome" row: wordmark on the left, optional trailing widgets on the right.
class FreqChrome extends StatelessWidget {
  final Widget left;
  final List<Widget> right;
  const FreqChrome({super.key, required this.left, this.right = const []});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          left,
          const Spacer(),
          for (int i = 0; i < right.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            right[i],
          ],
        ],
      ),
    );
  }
}
