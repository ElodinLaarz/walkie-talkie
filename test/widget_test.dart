import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  @override
  Future<void> clear() async {
    _name = null;
    _peerId = null;
  }
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
      _rows.add(
        _FakeRecentRow(
          RecentFrequency(freq: trimmed, sessionUuid: sessionUuid),
          _nextRecordedAt++,
        ),
      );
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
  Future<void> delete(String freq) async {
    final trimmed = freq.trim();
    _rows.removeWhere((r) => r.entry.freq == trimmed);
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

  @override
  void handleScanResults(List<ScanResult> results) {}
}

/// No-op watcher for widget tests. The production [DefaultPermissionWatcher]
/// starts a [Timer.periodic] when the cubit subscribes, which trips Flutter's
/// "A Timer is still pending after the widget tree was disposed" assertion
/// at the end of the test. The fake's stream is empty, so the cubit's
/// permission listener never fires and no transitions race the test.
class _FakePermissionWatcher implements PermissionWatcher {
  static int createdInstances = 0;
  bool disposed = false;

  _FakePermissionWatcher() {
    createdInstances++;
  }

  @override
  Stream<List<AppPermission>> watch() => const Stream.empty();

  @override
  Future<List<AppPermission>> checkNow() async => const [];

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _DenyingPermissionWatcher implements PermissionWatcher {
  final List<AppPermission> missing;

  _DenyingPermissionWatcher(this.missing);

  @override
  Stream<List<AppPermission>> watch() async* {
    yield missing;
  }

  @override
  Future<List<AppPermission>> checkNow() async => missing;

  @override
  Future<void> dispose() async {}
}

/// In-memory [SettingsStore] for widget tests — avoids hitting the sqflite
/// platform channel or requiring [databaseFactoryFfi] initialisation.
class _FakeSettingsStore implements SettingsStore {
  bool _crashReporting = false;
  bool _pttMode = false;
  bool _keepScreenOn = false;
  int pttReadCalls = 0;

  @override
  Future<bool> getCrashReportingEnabled() async => _crashReporting;
  @override
  Future<void> setCrashReportingEnabled(bool v) async => _crashReporting = v;

  @override
  Future<bool> getPttModeEnabled() async {
    pttReadCalls++;
    return _pttMode;
  }

  @override
  Future<void> setPttModeEnabled(bool v) async => _pttMode = v;

  @override
  Future<bool> getKeepScreenOn() async => _keepScreenOn;
  @override
  Future<void> setKeepScreenOn(bool v) async => _keepScreenOn = v;

  @override
  Future<void> clear() async {
    _crashReporting = false;
    _pttMode = false;
    _keepScreenOn = false;
  }
}

void main() {
  testWidgets('first launch routes through onboarding', (tester) async {
    await tester.pumpWidget(
      WalkieTalkieApp(
        identityStore: _FakeIdentityStore(),
        recentFrequenciesStore: _FakeRecentFrequenciesStore(),
        discoveryService: _FakeDiscoveryService(),
        permissionWatcher: _FakePermissionWatcher(),
        settingsStore: _FakeSettingsStore(),
      ),
    );
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

      expect(
        find.text('Phones around you,\non the same wavelength.'),
        findsOneWidget,
      );
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
          recentFrequenciesStore: _FakeRecentFrequenciesStore(
            initial: const ['100.1', '92.4'],
          ),
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

  testWidgets(
    'didUpdateWidget keeps caller-supplied watcher alive across pumps',
    (tester) async {
      // First pump: no permissionWatcher → app owns a default one (a real
      // DefaultPermissionWatcher, not directly observable from a unit test).
      await tester.pumpWidget(
        WalkieTalkieApp(
          identityStore: _FakeIdentityStore(initial: 'Maya'),
          recentFrequenciesStore: _FakeRecentFrequenciesStore(),
          discoveryService: _FakeDiscoveryService(),
          settingsStore: _FakeSettingsStore(),
        ),
      );
      await tester.pump();

      // Re-pump with a supplied watcher — exercises wasOwning && !stillOwning.
      // We can't directly assert that the previously-owned default watcher
      // was disposed (it's a production singleton), but we *can* assert
      // that the now-supplied watcher is NOT disposed by us (caller owns it).
      final supplied = _FakePermissionWatcher();
      expect(supplied.disposed, isFalse);
      await tester.pumpWidget(
        WalkieTalkieApp(
          identityStore: _FakeIdentityStore(initial: 'Maya'),
          recentFrequenciesStore: _FakeRecentFrequenciesStore(),
          discoveryService: _FakeDiscoveryService(),
          permissionWatcher: supplied,
          settingsStore: _FakeSettingsStore(),
        ),
      );
      await tester.pump();

      // The widget must not have disposed the caller-supplied watcher,
      // either as part of didUpdateWidget reconciliation or as the cubit
      // teardown for the discarded prior cubit instance.
      expect(supplied.disposed, isFalse);
      expect(find.byType(WalkieTalkieApp), findsOneWidget);
    },
  );

  testWidgets(
    'didUpdateWidget mints a fresh owned watcher when caller drops the supplied one',
    (tester) async {
      // Snapshot the test-fake constructor counter so we can verify the
      // supplied watcher counts as a creation. The owned default watcher
      // (DefaultPermissionWatcher) is a production class and isn't tracked
      // here; the indirect signal is that the widget keeps building
      // without throwing in build(), which would happen if the
      // null-coalesce on `widget.permissionWatcher ?? _ownedWatcher!`
      // tripped on a null owned watcher.
      final beforeSupplied = _FakePermissionWatcher.createdInstances;
      final supplied = _FakePermissionWatcher();
      expect(
        _FakePermissionWatcher.createdInstances,
        beforeSupplied + 1,
        reason: 'supplied watcher should bump the constructor counter',
      );

      await tester.pumpWidget(
        WalkieTalkieApp(
          identityStore: _FakeIdentityStore(initial: 'Maya'),
          recentFrequenciesStore: _FakeRecentFrequenciesStore(),
          discoveryService: _FakeDiscoveryService(),
          permissionWatcher: supplied,
          settingsStore: _FakeSettingsStore(),
        ),
      );
      await tester.pump();
      expect(supplied.disposed, isFalse);

      // Re-pump with no watcher — exercises !wasOwning && stillOwning.
      // The caller is now no longer supplying their watcher; it's the
      // *caller's* responsibility to dispose it (matches the `dispose()`
      // doc on _WalkieTalkieAppState). We assert the widget didn't
      // erroneously dispose the previously-supplied watcher.
      await tester.pumpWidget(
        WalkieTalkieApp(
          identityStore: _FakeIdentityStore(initial: 'Maya'),
          recentFrequenciesStore: _FakeRecentFrequenciesStore(),
          discoveryService: _FakeDiscoveryService(),
          settingsStore: _FakeSettingsStore(),
        ),
      );
      await tester.pump();

      expect(supplied.disposed, isFalse);
      // No new fake watcher should have been minted — the replacement is
      // a real DefaultPermissionWatcher, not our test fake.
      expect(
        _FakePermissionWatcher.createdInstances,
        beforeSupplied + 1,
        reason: 'owned-watcher mint must not pull in a test fake',
      );
      // The widget must remain mounted — if the new owned-watcher branch
      // failed to mint a default, the build() null-coalesce would throw.
      expect(find.byType(WalkieTalkieApp), findsOneWidget);
    },
  );

  testWidgets(
    'permission watcher reporting missing perms routes to permission denied screen',
    (tester) async {
      final watcher = _DenyingPermissionWatcher(const [
        AppPermission.bluetooth,
      ]);
      await tester.pumpWidget(
        WalkieTalkieApp(
          identityStore: _FakeIdentityStore(initial: 'Maya'),
          recentFrequenciesStore: _FakeRecentFrequenciesStore(),
          discoveryService: _FakeDiscoveryService(),
          permissionWatcher: watcher,
          settingsStore: _FakeSettingsStore(),
        ),
      );
      // Bootstrap, then watcher.checkNow returns missing perms; the
      // post-bootstrap _onPermissionsChanged routes us to denied.
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      // The denied screen renders the localised "Permissions revoked"
      // headline.
      expect(find.text('Permissions revoked'), findsOneWidget);
    },
  );

  testWidgets(
    'completing onboarding hands the name to the cubit and shows Discovery',
    (tester) async {
      // The onboarding flow's step 2 hits permission_handler's platform
      // channel via `DefaultOnboardingPermissionGateway`. Stub the channel
      // so all three Bluetooth perms + microphone resolve to "granted"
      // without involving the OS.
      const permsChannel = MethodChannel(
        'flutter.baseflow.com/permissions/methods',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(permsChannel, (call) async {
            switch (call.method) {
              case 'requestPermissions':
                final ids = (call.arguments as List).cast<int>();
                return <int, int>{for (final id in ids) id: 1}; // granted
              case 'checkPermissionStatus':
                return 1; // granted
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(permsChannel, null),
      );

      final identity = _FakeIdentityStore();
      await tester.pumpWidget(
        WalkieTalkieApp(
          identityStore: identity,
          recentFrequenciesStore: _FakeRecentFrequenciesStore(),
          discoveryService: _FakeDiscoveryService(),
          permissionWatcher: _FakePermissionWatcher(),
          settingsStore: _FakeSettingsStore(),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Step 0 — Welcome. Tap "Get started".
      expect(find.text('Get started'), findsOneWidget);
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle(const Duration(milliseconds: 600));

      // Step 1 — Explainer (3 pages). Tap Next twice, then "Get started".
      for (var i = 0; i < 5; i++) {
        if (find.text('Continue').evaluate().isNotEmpty ||
            find.byType(TextField).evaluate().isNotEmpty) {
          break;
        }
        for (final label in ['Next', 'Get started']) {
          final btn = find.text(label);
          if (btn.evaluate().isNotEmpty) {
            await tester.tap(btn.first);
            await tester.pumpAndSettle(const Duration(milliseconds: 400));
            break;
          }
        }
      }

      // Step 2 — Permissions. Tap the per-permission "Allow" buttons until
      // both perms are granted, then Continue.
      for (var i = 0; i < 6; i++) {
        if (find.byType(TextField).evaluate().isNotEmpty) break;
        final allow = find.text('Allow');
        if (allow.evaluate().isNotEmpty) {
          await tester.tap(allow.first);
          await tester.pumpAndSettle(const Duration(milliseconds: 400));
          continue;
        }
        final cont = find.text('Continue');
        if (cont.evaluate().isNotEmpty) {
          await tester.tap(cont.first);
          await tester.pumpAndSettle(const Duration(milliseconds: 400));
          continue;
        }
        break;
      }

      // Step 3 — Name picker. Enter the name and tap the continue button.
      final nameField = find.byType(TextField);
      if (nameField.evaluate().isEmpty) {
        fail('Onboarding name TextField not found — layout changed');
      }
      await tester.enterText(nameField.first, 'Maya');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      for (final label in [
        'Find a frequency',
        "I'm in",
        'Done',
        'Continue',
        'Get started',
      ]) {
        final btn = find.text(label);
        if (btn.evaluate().isNotEmpty) {
          await tester.tap(btn.first);
          break;
        }
      }
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Postcondition: cubit persisted the name to the identity store.
      expect(await identity.getDisplayName(), 'Maya');
    },
  );

  testWidgets(
    'tapping a recent frequency triggers joinRoom routing into SessionRoom',
    (tester) async {
      await tester.pumpWidget(
        WalkieTalkieApp(
          identityStore: _FakeIdentityStore(initial: 'Maya'),
          recentFrequenciesStore: _FakeRecentFrequenciesStore(
            initial: const ['100.1'],
          ),
          discoveryService: _FakeDiscoveryService(),
          permissionWatcher: _FakePermissionWatcher(),
          settingsStore: _FakeSettingsStore(),
        ),
      );
      // Bootstrap → Discovery.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Pre-condition: Discovery is showing (RECENT label is unique to it).
      expect(find.text('RECENT'), findsOneWidget);

      // Find a recent row and tap. The row text "Host on 100.1" identifies it.
      final freqRow = find.textContaining('Host on 100.1');
      expect(freqRow, findsOneWidget);
      await tester.tap(freqRow);
      // Don't pumpAndSettle — the room screen has perpetual animations.
      // A few frames are enough for the SessionRoom emission to commit.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Postcondition: cubit transitioned out of Discovery — the unique
      // RECENT label is gone, proving that the onPick callback fired
      // joinRoom on the cubit and the state machine has moved off
      // SessionDiscovery (the screen no longer renders).
      expect(find.text('RECENT'), findsNothing);
    },
  );

  testWidgets('app lifecycle resumed re-reads PTT mode setting', (
    tester,
  ) async {
    final settings = _FakeSettingsStore();
    await tester.pumpWidget(
      WalkieTalkieApp(
        identityStore: _FakeIdentityStore(initial: 'Maya'),
        recentFrequenciesStore: _FakeRecentFrequenciesStore(),
        discoveryService: _FakeDiscoveryService(),
        permissionWatcher: _FakePermissionWatcher(),
        settingsStore: settings,
      ),
    );
    await tester.pump();
    await tester.pump();

    // Snapshot read count after bootstrap settles.
    final readsAfterBoot = settings.pttReadCalls;
    expect(readsAfterBoot, greaterThanOrEqualTo(1));

    // Toggle the underlying setting then dispatch resumed lifecycle —
    // the FrequencyApp's didChangeAppLifecycleState handler should
    // re-read the value from the store.
    await settings.setPttModeEnabled(true);
    // Send AppLifecycleState.resumed via the platform message channel.
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/lifecycle',
      const StringCodec().encodeMessage(AppLifecycleState.resumed.toString()),
      (_) {},
    );
    await tester.pump();
    await tester.pump();

    // The lifecycle handler must have triggered an additional read.
    expect(settings.pttReadCalls, greaterThan(readsAfterBoot));
  });
}
