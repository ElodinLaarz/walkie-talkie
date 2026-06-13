import 'package:flutter/material.dart';

import '../data/frequency_models.dart';
import '../theme/app_theme.dart';
import 'frequency_atoms.dart';
import 'media_source_sheet.dart';

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

  /// Host-only: opens the source picker. Null for guests (chip not shown).
  final VoidCallback? onChangeSource;

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
    this.onChangeSource,
  });

  /// Returns the user-facing label for [wireKey], falling back to the raw key
  /// for unknown/future sources so no wrong source name is shown.
  static String _sourceLabel(String wireKey) {
    for (final s in MediaSource.values) {
      if (s.wireKey == wireKey) return s.label;
    }
    return wireKey;
  }

  /// Returns the [MediaSource] for [wireKey] via exact match, or null for
  /// unknown keys so callers can apply a neutral fallback instead of silently
  /// misrepresenting an unknown source as YouTube Music.
  static MediaSource? _trySource(String wireKey) {
    for (final s in MediaSource.values) {
      if (s.wireKey == wireKey) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    // Guard: durationSeconds == 0 means no track is loaded yet (emptyMediaLib).
    // Skip the slider/time row to avoid a max==0 Slider assertion and negative
    // time display; hold the VuMeter static regardless of the playing flag.
    final bool idle = track.durationSeconds <= 0;
    final bool liveActive = playing && !idle;
    return FreqCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: onChangeSource != null
                    ? _SourceChip(source: source, onTap: onChangeSource!)
                    : Text(
                        'LISTENING TOGETHER · ${_sourceLabel(source).toUpperCase()}',
                        style: TextStyle(
                          fontFamily: kSansFont,
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
                  VuMeter(active: liveActive),
                  const SizedBox(width: 5),
                  Text(
                    liveActive ? 'Live' : 'Paused',
                    style: TextStyle(
                      fontFamily: kSansFont,
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
                      style: TextStyle(
                        fontFamily: kSansFont,
                        fontSize: 11,
                        color: c.ink3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: kSansFont,
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
                        fontFamily: kSansFont,
                        fontSize: 13,
                        color: c.ink2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!idle) ...[
            const SizedBox(height: 14),
            Slider(
              value: progress.toDouble().clamp(
                0.0,
                track.durationSeconds.toDouble(),
              ),
              min: 0,
              max: track.durationSeconds.toDouble(),
              onChanged: onScrub,
            ),
            Row(
              children: [
                Text(
                  formatTime(progress),
                  style: kMonoStyle.copyWith(fontSize: 11, color: c.ink3),
                ),
                const Spacer(),
                Text(
                  '-${formatTime(track.durationSeconds - progress)}',
                  style: kMonoStyle.copyWith(fontSize: 11, color: c.ink3),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Semantics(
                button: true,
                label: 'Previous track',
                child: GhostButton(
                  icon: Icons.skip_previous,
                  onPressed: onPrev,
                ),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
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
                      style: TextStyle(
                        fontFamily: kSansFont,
                        fontSize: 11,
                        color: c.ink3,
                      ),
                      children: [
                        TextSpan(
                          text: lastActionBy,
                          style: TextStyle(
                            color: c.ink2,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        TextSpan(text: ' $lastActionWhat'),
                      ],
                    ),
                  ),
                ),
                Text(
                  lastActionWhen,
                  style: TextStyle(
                    fontFamily: kSansFont,
                    fontSize: 11,
                    color: c.ink3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Prominent chip button showing the current media source icon + name.
/// Meets the ≥48dp tap-target requirement via [_kChipHeight].
class _SourceChip extends StatelessWidget {
  final String source;
  final VoidCallback onTap;

  static const double _kChipHeight = 48.0;
  static const _kRadius = BorderRadius.all(Radius.circular(8));

  const _SourceChip({required this.source, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final ms = NowPlayingCard._trySource(source);
    final label = ms?.label ?? source;
    final icon = ms?.icon ?? Icons.music_note;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _kChipHeight),
      child: Align(
        alignment: Alignment.centerLeft,
        // Semantics wraps Material so the node's RenderObject centre sits
        // on the actual tap target, not the wider ConstrainedBox boundary.
        child: Semantics(
          button: true,
          label: 'Change source, currently $label',
          excludeSemantics: true,
          // Material sits above FreqCard's own Material so the InkWell
          // splash is painted over the chip background (not clipped by it).
          child: Material(
            color: c.surface2,
            shape: RoundedRectangleBorder(
              borderRadius: _kRadius,
              side: BorderSide(color: c.line),
            ),
            child: InkWell(
              onTap: onTap,
              borderRadius: _kRadius,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 12, color: c.ink2),
                    const SizedBox(width: 5),
                    Text(
                      label.toUpperCase(),
                      style: TextStyle(
                        fontFamily: kSansFont,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 1.0,
                        color: c.ink2,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(Icons.arrow_drop_down, size: 14, color: c.ink3),
                  ],
                ),
              ),
            ),
          ),
        ),
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
