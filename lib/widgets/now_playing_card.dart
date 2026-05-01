import 'package:flutter/material.dart';

import '../data/frequency_models.dart';
import '../theme/app_theme.dart';
import 'frequency_atoms.dart';

class NowPlayingCard extends StatelessWidget {
  final Track track;
  final String source;
  final bool isPodcast;
  final bool playing;
  final int progress;
  final String lastActionBy;
  final String lastActionWhat;
  final String lastActionWhen;
  final VoidCallback onPlay;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final ValueChanged<double> onScrub;
  final VoidCallback onOpenQueue;

  const NowPlayingCard({
    super.key,
    required this.track,
    required this.source,
    required this.isPodcast,
    required this.playing,
    required this.progress,
    required this.lastActionBy,
    required this.lastActionWhat,
    required this.lastActionWhen,
    required this.onPlay,
    required this.onNext,
    required this.onPrev,
    required this.onScrub,
    required this.onOpenQueue,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return FreqCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'LISTENING TOGETHER · ${source.toUpperCase()}',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.0,
                    color: c.ink3,
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VuMeter(active: playing),
                  const SizedBox(width: 5),
                  Text(
                    playing ? 'Live' : 'Paused',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.0,
                      color: c.ink3,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Artwork(isPodcast: isPodcast),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.tag,
                      style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.16,
                        color: c.ink,
                      ),
                    ),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        color: c.ink2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Slider(
            value: progress.toDouble().clamp(0.0, track.durationSeconds.toDouble()).toDouble(),
            min: 0,
            max: track.durationSeconds.toDouble(),
            onChanged: onScrub,
          ),
          Row(
            children: [
              Text(formatTime(progress), style: kMonoStyle.copyWith(fontSize: 11, color: c.ink3)),
              const Spacer(),
              Text('-${formatTime(track.durationSeconds - progress)}',
                  style: kMonoStyle.copyWith(fontSize: 11, color: c.ink3)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Semantics(
                button: true,
                label: 'Previous track',
                child: GhostButton(icon: Icons.skip_previous, onPressed: onPrev),
              ),
              const SizedBox(width: 4),
              _PlayCircle(playing: playing, onTap: onPlay),
              const SizedBox(width: 4),
              Semantics(
                button: true,
                label: 'Next track',
                child: GhostButton(icon: Icons.skip_next, onPressed: onNext),
              ),
              const Spacer(),
              FreqButton(
                icon: Icons.queue_music,
                label: 'Queue',
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                fontSize: 13,
                onPressed: onOpenQueue,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
                      children: [
                        TextSpan(
                          text: lastActionBy,
                          style: TextStyle(color: c.ink2, fontWeight: FontWeight.w500),
                        ),
                        TextSpan(text: ' $lastActionWhat'),
                      ],
                    ),
                  ),
                ),
                Text(
                  lastActionWhen,
                  style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  final bool isPodcast;
  const _Artwork({required this.isPodcast});

  @override
  Widget build(BuildContext context) {
    final base = isPodcast
        ? const [Color(0xFFEFD8C3), Color(0xFFF6E6D6)]
        : const [Color(0xFFD4D5EE), Color(0xFFE2E3F4)];
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          colors: base,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          tileMode: TileMode.repeated,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        isPodcast ? Icons.podcasts : Icons.music_note,
        size: 22,
        color: isPodcast ? const Color(0xFF704D2A) : const Color(0xFF3F3F73),
      ),
    );
  }
}

class _PlayCircle extends StatelessWidget {
  final bool playing;
  final VoidCallback onTap;
  const _PlayCircle({required this.playing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      hint: 'Toggles playback for the whole frequency',
      excludeSemantics: true,
      child: Material(
        color: c.ink,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(
              playing ? Icons.pause : Icons.play_arrow,
              size: 22,
              color: c.bg,
            ),
          ),
        ),
      ),
    );
  }
}
