import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';
import 'frequency_atoms.dart';

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

  bool get isPodcast => switch (this) {
        MediaSource.podcasts => true,
        MediaSource.pocketCasts => true,
        _ => false,
      };

  /// Deep-link URI that opens the streaming app directly (App Links on
  /// Android 12+).
  ///
  /// Deep-link URI for opening the streaming app directly, or null when no
  /// single canonical app exists for this source (e.g. the generic "Podcasts"
  /// source — Google Podcasts is discontinued and there is no standard podcast
  /// app URI on Android; use Pocket Casts explicitly for that app).
  ///
  /// On Android, [launchSourceApp] prefers
  /// [LaunchMode.externalNonBrowserApplication] (avoids browser via App Links)
  /// and falls back to [LaunchMode.externalApplication]. A true return does not
  /// guarantee the native app launched on Android — a browser may open instead
  /// if the app isn't installed.
  Uri? get appUri => switch (this) {
        MediaSource.youtubeMusic => Uri.parse('https://music.youtube.com/'),
        MediaSource.podcasts => null,
        MediaSource.spotify => Uri.parse('https://open.spotify.com/'),
        MediaSource.pocketCasts => Uri.parse('https://pca.st/'),
      };

  /// Returns null for unknown labels instead of silently defaulting to a
  /// specific source, so callers must handle the unrecognised-source case.
  static MediaSource? fromLabel(String label) {
    for (final s in MediaSource.values) {
      if (s.label == label) return s;
    }
    return null;
  }
}

/// Attempts to launch [source]'s streaming app.
///
/// Uses [LaunchMode.externalNonBrowserApplication] where supported (iOS 10+
/// universal links, avoids browser); falls back to
/// [LaunchMode.externalApplication] on platforms that don't support it.
///
/// Returns true if the OS accepted the launch; false if no handler was found.
/// Note: on Android the fallback mode may still open a browser when the app is
/// not installed — a `true` result does not guarantee the native app launched.
Future<bool> launchSourceApp(MediaSource source) async {
  final uri = source.appUri;
  if (uri == null) return false;
  if (!await canLaunchUrl(uri)) return false;
  if (await supportsLaunchMode(LaunchMode.externalNonBrowserApplication)) {
    return launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication);
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Bottom sheet for changing the shared media source.
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
