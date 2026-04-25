import 'dart:async';

import 'package:flutter/material.dart';

import '../data/frequency_mock_data.dart';
import '../theme/app_theme.dart';
import 'frequency_atoms.dart';

/// Visual tone of a toast. Each tone selects a default leading icon and an
/// accent palette consistent with the design.
enum ToastTone { info, join, leave, warn, request }

/// One action button on a toast (e.g. *Let in* / *Deny* on a join request).
class ToastAction {
  final String label;
  final bool primary;
  final VoidCallback onTap;

  const ToastAction({
    required this.label,
    required this.onTap,
    this.primary = false,
  });
}

/// Spec for a single toast push.
class FrequencyToastSpec {
  final ToastTone tone;
  final String title;
  final String? description;

  /// Optional subject; when present, the leading slot shows their avatar
  /// instead of the tone's default icon.
  final Person? person;

  /// `null` for sticky (the user must dismiss or pick an action).
  final Duration? autoDismiss;

  /// Optional action buttons; if any are provided, the trailing close button
  /// is hidden — actions implicitly dismiss the toast on tap.
  final List<ToastAction> actions;

  const FrequencyToastSpec({
    required this.title,
    this.tone = ToastTone.info,
    this.description,
    this.person,
    this.autoDismiss = const Duration(milliseconds: 3200),
    this.actions = const [],
  });
}

class _ActiveToast {
  final int id;
  final FrequencyToastSpec spec;
  Timer? autoDismiss;
  _ActiveToast({required this.id, required this.spec});
}

/// API exposed by [FrequencyToastHost.of] to descendants.
abstract class FrequencyToastController {
  /// Pushes a toast. Returns its id so callers can dismiss it manually.
  int push(FrequencyToastSpec spec);

  /// Dismisses the toast with [id], if it's still visible. No-op otherwise.
  void dismiss(int id);
}

/// Wraps [child] in a stack that overlays toasts at the top of the frame.
///
/// Mirrors the design's in-frame toast behavior: top-of-frame placement,
/// tone-tinted icon, optional avatar, optional action buttons. Auto-dismiss
/// is the default; pass `autoDismiss: null` for a sticky toast that requires
/// explicit dismissal (the host's join-request prompt is the canonical case).
class FrequencyToastHost extends StatefulWidget {
  final Widget child;
  const FrequencyToastHost({super.key, required this.child});

  static FrequencyToastController of(BuildContext context) {
    final state = context.findAncestorStateOfType<_FrequencyToastHostState>();
    assert(
      state != null,
      'No FrequencyToastHost found in the widget tree above this context.',
    );
    return state!;
  }

  @override
  State<FrequencyToastHost> createState() => _FrequencyToastHostState();
}

class _FrequencyToastHostState extends State<FrequencyToastHost>
    implements FrequencyToastController {
  final List<_ActiveToast> _toasts = [];
  int _nextId = 1;

  @override
  int push(FrequencyToastSpec spec) {
    final id = _nextId++;
    final toast = _ActiveToast(id: id, spec: spec);
    if (spec.autoDismiss != null) {
      toast.autoDismiss = Timer(spec.autoDismiss!, () => dismiss(id));
    }
    setState(() => _toasts.add(toast));
    return id;
  }

  @override
  void dismiss(int id) {
    if (!mounted) return;
    final idx = _toasts.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    _toasts[idx].autoDismiss?.cancel();
    setState(() => _toasts.removeAt(idx));
  }

  @override
  void dispose() {
    for (final t in _toasts) {
      t.autoDismiss?.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned(
          top: 48,
          left: 12,
          right: 12,
          child: IgnorePointer(
            ignoring: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final t in _toasts)
                  Padding(
                    key: ValueKey(t.id),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ToastCard(
                      spec: t.spec,
                      onDismiss: () => dismiss(t.id),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ToastCard extends StatefulWidget {
  final FrequencyToastSpec spec;
  final VoidCallback onDismiss;
  const _ToastCard({required this.spec, required this.onDismiss});

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  )..forward();

  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
  );

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -0.15),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final spec = widget.spec;
    final tone = _toneStyle(spec.tone, c);

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Material(
          color: c.surface,
          elevation: 0,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.line),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (spec.person != null)
                  FreqAvatar(person: spec.person!, size: 32)
                else
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: tone.bg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(tone.icon, size: 15, color: tone.fg),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        spec.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.ink,
                          height: 1.25,
                        ),
                      ),
                      if (spec.description != null) ...[
                        const SizedBox(height: 1),
                        Text(
                          spec.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            color: c.ink3,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (spec.actions.isNotEmpty)
                  ..._buildActions(context, spec.actions)
                else
                  IconButton(
                    onPressed: widget.onDismiss,
                    icon: Icon(Icons.close, size: 14, color: c.ink3),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildActions(
    BuildContext context,
    List<ToastAction> actions,
  ) {
    final widgets = <Widget>[];
    for (var i = 0; i < actions.length; i++) {
      if (i > 0) widgets.add(const SizedBox(width: 6));
      final a = actions[i];
      widgets.add(
        FreqButton(
          label: a.label,
          accent: a.primary,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          fontSize: 12,
          onPressed: () {
            a.onTap();
            widget.onDismiss();
          },
        ),
      );
    }
    return widgets;
  }
}

class _ToneStyle {
  final Color bg;
  final Color fg;
  final IconData icon;
  const _ToneStyle({required this.bg, required this.fg, required this.icon});
}

_ToneStyle _toneStyle(ToastTone tone, FrequencyColors c) {
  switch (tone) {
    case ToastTone.join:
      return _ToneStyle(bg: c.accentSoft, fg: c.accentInk, icon: Icons.add);
    case ToastTone.leave:
      return _ToneStyle(bg: c.surface2, fg: c.ink2, icon: Icons.logout);
    case ToastTone.warn:
      return _ToneStyle(bg: c.warnSoft, fg: c.warn, icon: Icons.signal_cellular_alt);
    case ToastTone.request:
      return _ToneStyle(bg: c.surface, fg: c.ink, icon: Icons.people_outline);
    case ToastTone.info:
      return _ToneStyle(bg: c.surface2, fg: c.ink2, icon: Icons.radio);
  }
}
