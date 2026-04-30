import 'package:flutter/material.dart';

/// UI-side presentation model for someone in a frequency. Distinct from
/// [ProtocolPeer] in `lib/protocol/peer.dart`, which carries wire-format
/// identity; `Person` adds presentation-only fields like [hue] (avatar tint)
/// and short [initials] used by [FreqAvatar].
class Person {
  final String id;
  final String name;
  final String initials;
  final double hue;
  final String btDevice;

  const Person({
    required this.id,
    required this.name,
    required this.initials,
    required this.hue,
    required this.btDevice,
  });
}

enum MediaKind { music, podcast }

class Track {
  final String title;
  final String artist;
  final int durationSeconds;
  final String tag;

  const Track({
    required this.title,
    required this.artist,
    required this.durationSeconds,
    required this.tag,
  });
}

class MediaSourceLib {
  final String name;
  final MediaKind kind;
  final List<Track> queue;

  const MediaSourceLib({
    required this.name,
    required this.kind,
    required this.queue,
  });
}

/// Empty-queue placeholder used by the room screen before any host
/// `mediaState` snapshot lands. Surfaced as the initial `_lib` so the player
/// chrome has something to render without depending on a hard-coded catalog.
const MediaSourceLib emptyMediaLib = MediaSourceLib(
  name: '',
  kind: MediaKind.music,
  queue: [
    Track(title: 'Nothing playing', artist: '—', durationSeconds: 1, tag: ''),
  ],
);

String formatTime(int s) {
  if (s >= 3600) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    return '$h:${m.toString().padLeft(2, '0')}:00';
  }
  final m = s ~/ 60;
  final sec = s % 60;
  return '$m:${sec.toString().padLeft(2, '0')}';
}

/// Map a "hue" 0..360 plus lightness/chroma to a Flutter Color via HSL.
/// Used to mirror oklch(0.92 0.06 hue) avatar tints.
Color hueColor(double hue, {double lightness = 0.88, double saturation = 0.32}) {
  return HSLColor.fromAHSL(1.0, hue, saturation, lightness).toColor();
}

Color hueInk(double hue) {
  return HSLColor.fromAHSL(1.0, hue, 0.55, 0.32).toColor();
}
