import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'frequency_atoms.dart';

/// Available media sources the host can switch to.
enum MediaSource {
  youtubeMusic,
  podcasts,
  spotify,
  pocketCasts,
}

extension MediaSourceExtension on MediaSource {
  String get label => switch (this) {
        MediaSource.youtubeMusic => 'YouTube Music',
        MediaSource.podcasts => 'Podcasts',
        MediaSource.spotify => 'Spotify',
        MediaSource.pocketCasts => 'Pocket Casts',
      };

  IconData get icon => switch (this) {
        MediaSource.youtubeMusic => Icons.music_note,
        MediaSource.podcasts => Icons.podcasts,
        MediaSource.spotify => Icons.queue_music,
        MediaSource.pocketCasts => Icons.radio,
      };

  String get subtitle => switch (this) {
        MediaSource.youtubeMusic => 'Music and playlists',
        MediaSource.podcasts => 'Episodes and shows',
        MediaSource.spotify => 'Music and podcasts',
        MediaSource.pocketCasts => 'Podcast episodes',
      };

  static MediaSource fromLabel(String label) {
    for (final s in MediaSource.values) {
      if (s.label == label) return s;
    }
    return MediaSource.youtubeMusic;
  }
}

class MediaSourceSheet extends StatelessWidget {
  final String current;

  const MediaSourceSheet({
    super.key,
    required this.current,
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
                      'Choose source',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                    Text(
                      'Switch what everyone in the room hears',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                    ),
                  ],
                ),
              ),
              Semantics(
                button: true,
                label: 'Close source picker',
                child: GhostButton(
                  icon: Icons.close,
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FreqCard(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (int i = 0; i < MediaSource.values.length; i++)
                  _SourceRow(
                    source: MediaSource.values[i],
                    selected: MediaSource.values[i].label == current,
                    first: i == 0,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  final MediaSource source;
  final bool selected;
  final bool first;

  const _SourceRow({
    required this.source,
    required this.selected,
    required this.first,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Semantics(
      button: true,
      selected: selected,
      label: source.label,
      hint: source.subtitle,
      excludeSemantics: true,
      child: Material(
        color: selected ? c.surface2 : c.surface,
        child: InkWell(
          onTap: () => Navigator.pop(context, source.label),
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
                    source.icon,
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
                        source.label,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: c.ink,
                        ),
                      ),
                      Text(
                        source.subtitle,
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
      ),
    );
  }
}
