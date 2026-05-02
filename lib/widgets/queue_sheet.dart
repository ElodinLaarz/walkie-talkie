import 'package:flutter/material.dart';

import '../data/frequency_models.dart';
import '../theme/app_theme.dart';
import 'frequency_atoms.dart';

class QueueSheet extends StatelessWidget {
  final MediaSourceLib lib;
  final int currentIdx;
  final ValueChanged<int> onPlay;
  /// Host-only: opens the source picker to switch the shared media source.
  final VoidCallback? onChangeSource;
  /// Host-only: launches the active streaming app so the host can pick music.
  final VoidCallback? onOpenInSource;

  const QueueSheet({
    super.key,
    required this.lib,
    required this.currentIdx,
    required this.onPlay,
    this.onChangeSource,
    this.onOpenInSource,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, controller) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Column(
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
                          'Shared queue',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: c.ink,
                          ),
                        ),
                        Text(
                          'From ${lib.name} · everyone can reorder',
                          style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                        ),
                      ],
                    ),
                  ),
                  if (onChangeSource != null)
                    Semantics(
                      button: true,
                      label: 'Change source',
                      child: GhostButton(
                        icon: Icons.swap_horiz,
                        onPressed: onChangeSource,
                      ),
                    ),
                  Semantics(
                    button: true,
                    label: 'Close queue',
                    child: GhostButton(
                      icon: Icons.close,
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: lib.queue.length,
                  itemBuilder: (_, i) {
                    final t = lib.queue[i];
                    final current = i == currentIdx;
                    return Semantics(
                      button: true,
                      label: '${t.title} by ${t.artist}',
                      hint: current ? 'Currently playing' : 'Tap to play',
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: () => onPlay(i),
                        child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                        decoration: BoxDecoration(
                          border: Border(
                            top: i == 0 ? BorderSide.none : BorderSide(color: c.line),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 28,
                              child: Center(
                                child: current
                                    ? VuMeter(color: c.accent)
                                    : Text(
                                        (i + 1).toString().padLeft(2, '0'),
                                        style: kMonoStyle.copyWith(fontSize: 12, color: c.ink3),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 14,
                                      fontWeight: current ? FontWeight.w600 : FontWeight.w500,
                                      color: c.ink,
                                    ),
                                  ),
                                  Text(
                                    t.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 12,
                                      color: c.ink3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              formatTime(t.durationSeconds),
                              style: kMonoStyle.copyWith(fontSize: 12, color: c.ink3),
                            ),
                          ],
                        ),
                      ),
                      ),
                    );
                  },
                ),
              ),
              if (onOpenInSource != null) ...[
                const SizedBox(height: 10),
                FreqButton(
                  icon: Icons.open_in_new,
                  label: 'Open ${lib.name}',
                  block: true,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  onPressed: onOpenInSource,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
