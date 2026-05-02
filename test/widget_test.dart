import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/main.dart';
import 'package:walkie_talkie/protocol/discovery.dart';
import 'package:walkie_talkie/services/bluetooth_discovery_service.dart';
import 'package:walkie_talkie/services/identity_store.dart';
import 'package:walkie_talkie/services/permission_watcher.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';
import 'package:walkie_talkie/services/settings_store.dart';

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

/// Internal row carrying the public [RecentFrequency] plus a synthetic
/// `recordedAt` ordering key. Mirrors the real store's recency sort so
/// flipping `pinned` doesn't change the row's recency position.
class _FakeRecentRow {
  RecentFrequency entry;
  int recordedAt;
  _FakeRecentRow(this.entry, this.recordedAt);
}

class _FakeRecentFrequenciesStore implements RecentFrequenciesStore {
  final List<_FakeRecentRow> _rows;
  int _nextRecordedAt;
  _FakeRecentFrequenciesStore({List<String>? initial})
      : _rows = [],
        _nextRecordedAt = 0 {
    final asList = (initial ?? const <String>[]).toList();
    // Seed in reverse so the first item ends up most-recent.
    for (var i = asList.length - 1; i >= 0; i--) {
      _rows.add(
        _FakeRecentRow(RecentFrequency(freq: asList[i]), _nextRecordedAt++),
      );
    }
  }

  @override
  Future<List<String>> getRecent() async {
    final detailed = await getRecentDetailed();
    return List<String>.unmodifiable(detailed.map((e) => e.freq));
  }

  @override
  Future<List<RecentFrequency>> getRecentDetailed() async {
    // Pinned-first then recordedAt DESC, mirroring the production
    // `ORDER BY pinned DESC, recorded_at DESC`. Cap unpinned at
    // maxEntries; pinned rows are exempt.
    final sorted = [..._rows]
      ..sort((a, b) {
        if (a.entry.pinned != b.entry.pinned) {
          return a.entry.pinned ? -1 : 1;
        }
        return b.recordedAt.compareTo(a.recordedAt);
      });
    final result = <RecentFrequency>[];
    var unpinnedCount = 0;
    for (final row in sorted) {
      if (!row.entry.pinned) {
        if (unpinnedCount >= RecentFrequenciesStore.maxEntries) continue;
        unpinnedCount++;
      }
      result.add(row.entry);
    }
    return List<RecentFrequency>.unmodifiable(result);
  }

  @override
  Future<void> record(String freq, {String? sessionUuid}) async {
    final trimmed = freq.trim();
    if (trimmed.isEmpty) return;
    final existing = _rows.firstWhere(
      (r) => r.entry.freq == trimmed,
      orElse: () => _FakeRecentRow(RecentFrequency(freq: trimmed), -1),
    );
    if (existing.recordedAt < 0) {
      _rows.add(_FakeRecentRow(
        RecentFrequency(freq: trimmed, sessionUuid: sessionUuid),
        _nextRecordedAt++,
      ));
    } else {
      existing.recordedAt = _nextRecordedAt++;
      if (sessionUuid != null) {
        existing.entry = RecentFrequency(
          freq: existing.entry.freq,
          nickname: existing.entry.nickname,
          pinned: existing.entry.pinned,
          sessionUuid: sessionUuid,
        );
      }
    }
    final unpinnedSorted = _rows.where((r) => !r.entry.pinned).toList()
      ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    final toDrop = unpinnedSorted
        .skip(RecentFrequenciesStore.maxEntries)
        .map((r) => r.entry.freq)
        .toSet();
    _rows.removeWhere((r) => toDrop.contains(r.entry.freq));
  }

  @override
  Future<void> setNickname(String freq, String? nickname) async {
    final idx = _rows.indexWhere((r) => r.entry.freq == freq);
    if (idx < 0) return;
    final trimmed = nickname?.trim();
    final value = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    _rows[idx].entry = RecentFrequency(
      freq: _rows[idx].entry.freq,
      nickname: value,
      pinned: _rows[idx].entry.pinned,
      // Preserve the persisted sessionUuid — production's UPDATE only
      // touches the nickname column. Without this, renaming a recent
      // would silently strip its sessionUuid in widget tests and Resume
      // would fall back to minting (#219).
      sessionUuid: _rows[idx].entry.sessionUuid,
    );
  }

  @override
  Future<void> setPinned(String freq, bool pinned) async {
    final idx = _rows.indexWhere((r) => r.entry.freq == freq);
    if (idx < 0) return;
    _rows[idx].entry = RecentFrequency(
      freq: _rows[idx].entry.freq,
      nickname: _rows[idx].entry.nickname,
      pinned: pinned,
      // Same rationale as setNickname above — pin/unpin must not strip
      // the sessionUuid (#219).
      sessionUuid: _rows[idx].entry.sessionUuid,
    );
    // Intentionally do NOT touch recordedAt — unpinning should demote a
    // row back to its real recency position relative to other unpinned
    // rows. Mirror production's cap-on-unpin so unpinning can't leave
    // the fake holding more unpinned rows than maxEntries.
    if (!pinned) {
      final unpinnedSorted = _rows.where((r) => !r.entry.pinned).toList()
        ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
      final toDrop = unpinnedSorted
          .skip(RecentFrequenciesStore.maxEntries)
          .map((r) => r.entry.freq)
          .toSet();
      _rows.removeWhere((r) => toDrop.contains(r.entry.freq));
    }
  }

  @override
  Future<void> clear() async => _rows.clear();
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

  @override
  DiscoveredSession? parseResult(ScanResult r) => null;
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

/// In-memory [SettingsStore] for widget tests — avoids hitting the sqflite
/// platform channel or requiring [databaseFactoryFfi] initialisation.
class _FakeSettingsStore implements SettingsStore {
  bool _crashReporting = false;
  bool _pttMode = false;
  bool _keepScreenOn = false;

  @override
  Future<bool> getCrashReportingEnabled() async => _crashReporting;
  @override
  Future<void> setCrashReportingEnabled(bool v) async => _crashReporting = v;

  @override
  Future<bool> getPttModeEnabled() async => _pttMode;
  @override
  Future<void> setPttModeEnabled(bool v) async => _pttMode = v;

  @override
  Future<bool> getKeepScreenOn() async => _keepScreenOn;
  @override
  Future<void> setKeepScreenOn(bool v) async => _keepScreenOn = v;
}

void main() {
  testWidgets('first launch routes through onboarding', (tester) async {
    await tester.pumpWidget(WalkieTalkieApp(
      identityStore: _FakeIdentityStore(),
      recentFrequenciesStore: _FakeRecentFrequenciesStore(),
      discoveryService: _FakeDiscoveryService(),
      permissionWatcher: _FakePermissionWatcher(),
      settingsStore: _FakeSettingsStore(),
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
          settingsStore: _FakeSettingsStore(),
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
          settingsStore: _FakeSettingsStore(),
        ),
      );
      // bootstrap awaits two reads (display name, recent frequencies); pump
      // a few frames to clear them before asserting.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('RECENT'), findsOneWidget);
      // Each row's freq is rendered inside a Text.rich span ("Host on X
      // MHz"). Match the full "Host on" prefix to distinguish from other
      // UI elements that may also display the frequency.
      expect(find.textContaining('Host on 100.1'), findsOneWidget);
      expect(find.textContaining('Host on 92.4'), findsOneWidget);
    },
  );
}
