import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/main.dart';
import 'package:walkie_talkie/protocol/discovery.dart';
import 'package:walkie_talkie/services/bluetooth_discovery_service.dart';
import 'package:walkie_talkie/services/identity_store.dart';
import 'package:walkie_talkie/services/permission_watcher.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';

class _FakeIdentityStore implements IdentityStore {
  String? _name;
  String? _peerId;
  _FakeIdentityStore({String? initial}) : _name = initial;

  @override
  Future<String?> getDisplayName() async => _name;

  // Mirror SqfliteIdentityStore: trim, and treat empty/whitespace as a clear.
  @override
  Future<void> setDisplayName(String value) async {
    final trimmed = value.trim();
    _name = trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<String> getPeerId() async => _peerId ??= 'fake-peer-id';
}

class _FakeRecentFrequenciesStore implements RecentFrequenciesStore {
  final List<RecentFrequency> _entries;
  _FakeRecentFrequenciesStore({List<String>? initial})
      : _entries = List<RecentFrequency>.of(
          (initial ?? const []).map((f) => RecentFrequency(freq: f)),
        );

  @override
  Future<List<String>> getRecent() async {
    final detailed = await getRecentDetailed();
    return List<String>.unmodifiable(detailed.map((e) => e.freq));
  }

  @override
  Future<List<RecentFrequency>> getRecentDetailed() async {
    final pinned = _entries.where((e) => e.pinned).toList();
    final unpinned = _entries.where((e) => !e.pinned).toList();
    return List<RecentFrequency>.unmodifiable([...pinned, ...unpinned]);
  }

  @override
  Future<void> record(String freq) async {
    final trimmed = freq.trim();
    if (trimmed.isEmpty) return;
    final existingIdx = _entries.indexWhere((e) => e.freq == trimmed);
    final existing =
        existingIdx >= 0 ? _entries.removeAt(existingIdx) : null;
    _entries.insert(0, existing ?? RecentFrequency(freq: trimmed));
    // Mirror the production cap on UNPINNED entries so the fake doesn't
    // silently let tests drift past the behavior the real store enforces;
    // pinned entries are exempt from the cap (#125).
    final unpinned = _entries.where((e) => !e.pinned).toList();
    if (unpinned.length > RecentFrequenciesStore.maxEntries) {
      final toDrop = unpinned
          .skip(RecentFrequenciesStore.maxEntries)
          .map((e) => e.freq)
          .toSet();
      _entries.removeWhere((e) => toDrop.contains(e.freq));
    }
  }

  @override
  Future<void> setNickname(String freq, String? nickname) async {
    final idx = _entries.indexWhere((e) => e.freq == freq);
    if (idx < 0) return;
    final trimmed = nickname?.trim();
    final value = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    _entries[idx] = RecentFrequency(
      freq: _entries[idx].freq,
      nickname: value,
      pinned: _entries[idx].pinned,
    );
  }

  @override
  Future<void> setPinned(String freq, bool pinned) async {
    final idx = _entries.indexWhere((e) => e.freq == freq);
    if (idx < 0) return;
    _entries[idx] = RecentFrequency(
      freq: _entries[idx].freq,
      nickname: _entries[idx].nickname,
      pinned: pinned,
    );
  }

  @override
  Future<void> clear() async => _entries.clear();
}

class _FakeDiscoveryService implements DiscoveryService {
  @override
  Stream<List<DiscoveredSession>> get results => const Stream.empty();

  @override
  Future<void> startScan() async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> dispose() async {}
}

/// No-op watcher for widget tests. The production [DefaultPermissionWatcher]
/// starts a [Timer.periodic] when the cubit subscribes, which trips Flutter's
/// "A Timer is still pending after the widget tree was disposed" assertion
/// at the end of the test. The fake's stream is empty, so the cubit's
/// permission listener never fires and no transitions race the test.
class _FakePermissionWatcher implements PermissionWatcher {
  @override
  Stream<List<AppPermission>> watch() => const Stream.empty();

  @override
  Future<List<AppPermission>> checkNow() async => const [];

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('first launch routes through onboarding', (tester) async {
    await tester.pumpWidget(WalkieTalkieApp(
      identityStore: _FakeIdentityStore(),
      recentFrequenciesStore: _FakeRecentFrequenciesStore(),
      discoveryService: _FakeDiscoveryService(),
      permissionWatcher: _FakePermissionWatcher(),
    ));
    // Boot splash → microtask flush → onboarding welcome.
    await tester.pump();
    await tester.pump();

    expect(find.text('Frequency'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
  });

  testWidgets(
    'subsequent launches with a persisted name skip onboarding and land on Discovery',
    (tester) async {
      await tester.pumpWidget(
        WalkieTalkieApp(
          identityStore: _FakeIdentityStore(initial: 'Maya'),
          recentFrequenciesStore: _FakeRecentFrequenciesStore(),
          discoveryService: _FakeDiscoveryService(),
          permissionWatcher: _FakePermissionWatcher(),
        ),
      );
      // Two frames: boot splash, then Discovery after the bootstrap setState.
      // Avoid pumpAndSettle — Discovery has a perpetual PulseDot animation.
      await tester.pump();
      await tester.pump();

      expect(find.text('Phones around you,\non the same wavelength.'),
          findsOneWidget);
      expect(find.text('Get started'), findsNothing);
      expect(find.text('MA'), findsOneWidget);
    },
  );

  testWidgets(
    'persisted recent frequencies appear in the Recent section on launch',
    (tester) async {
      await tester.pumpWidget(
        WalkieTalkieApp(
          identityStore: _FakeIdentityStore(initial: 'Maya'),
          recentFrequenciesStore:
              _FakeRecentFrequenciesStore(initial: const ['100.1', '92.4']),
          discoveryService: _FakeDiscoveryService(),
          permissionWatcher: _FakePermissionWatcher(),
        ),
      );
      // bootstrap awaits two reads (display name, recent frequencies); pump
      // a few frames to clear them before asserting.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('RECENT'), findsOneWidget);
      // Each row's freq is rendered inside a Text.rich span ("Host on X
      // MHz"), so match by substring rather than exact text.
      expect(find.textContaining('100.1'), findsOneWidget);
      expect(find.textContaining('92.4'), findsOneWidget);
    },
  );
}
