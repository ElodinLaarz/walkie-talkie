import 'package:walkie_talkie/data/frequency_models.dart';

/// Test-only fixtures. The previous `lib/data/frequency_mock_data.dart`
/// was imported by production paths and shipped placeholder strings
/// (e.g. "Sony WH-1000XM5") to real users. These now live under `test/`
/// so production code can no longer reach them.
const List<Person> kPeople = [
  Person(id: 'me', name: 'You', initials: 'YO', hue: 145, btDevice: 'Sony WH-1000XM5'),
  Person(id: 'p1', name: 'Maya', initials: 'MA', hue: 40, btDevice: 'AirPods Pro'),
  Person(id: 'p2', name: 'Devon', initials: 'DE', hue: 200, btDevice: 'Pixel Buds'),
  Person(id: 'p3', name: 'Priya', initials: 'PR', hue: 300, btDevice: 'Bose QC45'),
  Person(id: 'p4', name: 'Jules', initials: 'JU', hue: 90, btDevice: 'JBL Live'),
  Person(id: 'p5', name: 'Sam', initials: 'SA', hue: 260, btDevice: 'AirPods 3'),
  Person(id: 'p6', name: 'Rio', initials: 'RI', hue: 15, btDevice: 'Galaxy Buds'),
  Person(id: 'p7', name: 'Ash', initials: 'AS', hue: 175, btDevice: 'Sennheiser HD'),
  Person(id: 'p8', name: 'Taye', initials: 'TA', hue: 340, btDevice: 'Beats Studio'),
  Person(id: 'p9', name: 'Noor', initials: 'NO', hue: 110, btDevice: 'Soundcore'),
  Person(id: 'pA', name: 'Kai', initials: 'KA', hue: 55, btDevice: 'AirPods Max'),
  Person(id: 'pB', name: 'Remy', initials: 'RE', hue: 220, btDevice: 'Nothing Ear'),
];

final Map<String, MediaSourceLib> kMedia = {
  'YouTube Music': const MediaSourceLib(
    name: 'YouTube Music',
    kind: MediaKind.music,
    queue: [
      Track(title: 'Nightsong', artist: 'Mount Kimbie', durationSeconds: 214, tag: 'MUSIC'),
      Track(title: 'Soft Fascination', artist: 'Tycho', durationSeconds: 262, tag: 'MUSIC'),
      Track(title: 'Open', artist: 'Rhye', durationSeconds: 231, tag: 'MUSIC'),
      Track(title: 'Fade Into You', artist: 'Mazzy Star', durationSeconds: 295, tag: 'MUSIC'),
      Track(title: 'Nude', artist: 'Radiohead', durationSeconds: 255, tag: 'MUSIC'),
    ],
  ),
  'Spotify': const MediaSourceLib(
    name: 'Spotify',
    kind: MediaKind.music,
    queue: [
      Track(title: 'Midnight City', artist: 'M83', durationSeconds: 244, tag: 'MUSIC'),
      Track(title: 'Borderline', artist: 'Tame Impala', durationSeconds: 237, tag: 'MUSIC'),
      Track(title: 'Runaway', artist: 'Kanye West', durationSeconds: 549, tag: 'MUSIC'),
      Track(title: 'Electric Feel', artist: 'MGMT', durationSeconds: 229, tag: 'MUSIC'),
    ],
  ),
  'Podcasts': const MediaSourceLib(
    name: 'Podcasts',
    kind: MediaKind.podcast,
    queue: [
      Track(title: 'The Quiet Economy', artist: 'The Ezra Klein Show', durationSeconds: 3720, tag: 'EP 412'),
      Track(title: 'How Cities Remember', artist: '99% Invisible', durationSeconds: 2880, tag: 'EP 589'),
      Track(title: 'On Making Things', artist: 'The Run-Up', durationSeconds: 2540, tag: 'EP 76'),
      Track(title: 'A Year in Software', artist: 'Acquired', durationSeconds: 5400, tag: 'EP 218'),
    ],
  ),
};
