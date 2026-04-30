import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:walkie_talkie/services/identity_store.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';
import 'package:walkie_talkie/services/storage_migration.dart';
import 'package:walkie_talkie/services/walkie_talkie_database.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    // Stand up a clean Hive home for each test so legacy boxes from one
    // case don't leak into the next via Hive's process-wide path state.
    hiveDir = await Directory.systemTemp.createTemp('hive_migration_test_');

    WalkieTalkieDatabase.overrideDatabaseFactoryForTesting(
      databaseFactoryFfi,
      // Use a file-backed sqlite path under hiveDir so multiple stores in
      // the same test still share a connection through the database opener.
      // (in-memory databases are per-connection, which would make the
      // store↔store sharing test invisible.)
      path: p.join(hiveDir.path, 'wt.db'),
    );
    await WalkieTalkieDatabase.resetForTesting();
  });

  tearDown(() async {
    await WalkieTalkieDatabase.resetForTesting();
    if (Hive.isBoxOpen('identity')) await Hive.box('identity').close();
    if (Hive.isBoxOpen('recent_frequencies')) {
      await Hive.box('recent_frequencies').close();
    }
    try {
      await Hive.deleteFromDisk();
    } catch (_) {
      // best-effort
    }
    await Hive.close();
    if (await hiveDir.exists()) {
      await hiveDir.delete(recursive: true);
    }
  });

  Future<void> initHiveAtTempDir() async {
    Hive.init(hiveDir.path);
  }

  group('migrateHiveToSqliteIfNeeded', () {
    test('no-op on a fresh install (no Hive boxes present)', () async {
      await migrateHiveToSqliteIfNeeded(hiveInit: initHiveAtTempDir);

      // Stores read fresh — no rows in either table.
      expect(await SqfliteIdentityStore().getDisplayName(), isNull);
      expect(await SqfliteRecentFrequenciesStore().getRecent(), isEmpty);
    });

    test('copies displayName + peerId from a legacy Hive identity box',
        () async {
      // Seed a legacy Hive box.
      Hive.init(hiveDir.path);
      final box = await Hive.openBox<String>('identity');
      await box.put('displayName', 'Maya');
      await box.put('peerId', 'fake-peer-id-1234');
      await box.close();
      await Hive.close();

      await migrateHiveToSqliteIfNeeded(hiveInit: initHiveAtTempDir);

      final identity = SqfliteIdentityStore();
      expect(await identity.getDisplayName(), 'Maya');
      expect(await identity.getPeerId(), 'fake-peer-id-1234');
    });

    test('copies recents preserving most-recent-first order', () async {
      Hive.init(hiveDir.path);
      final box = await Hive.openBox<dynamic>('recent_frequencies');
      // Hive stored entries head=most-recent.
      await box.put('list', <dynamic>['100.1', '92.4', '88.7']);
      await box.close();
      await Hive.close();

      await migrateHiveToSqliteIfNeeded(hiveInit: initHiveAtTempDir);

      final recents = await SqfliteRecentFrequenciesStore().getRecent();
      expect(recents, ['100.1', '92.4', '88.7']);
    });

    test('drops malformed entries silently (mixed-type list)', () async {
      Hive.init(hiveDir.path);
      final box = await Hive.openBox<dynamic>('recent_frequencies');
      await box.put('list', <dynamic>['100.1', 42, '92.4', null, '   ']);
      await box.close();
      await Hive.close();

      await migrateHiveToSqliteIfNeeded(hiveInit: initHiveAtTempDir);

      final recents = await SqfliteRecentFrequenciesStore().getRecent();
      expect(recents, ['100.1', '92.4']);
    });

    test('is idempotent: second call is a no-op', () async {
      Hive.init(hiveDir.path);
      final box = await Hive.openBox<String>('identity');
      await box.put('displayName', 'Maya');
      await box.close();
      await Hive.close();

      await migrateHiveToSqliteIfNeeded(hiveInit: initHiveAtTempDir);
      // Mutate the SQLite-side state so we can detect if a second call
      // re-runs the import (which would clobber our change).
      await SqfliteIdentityStore().setDisplayName('Devon');

      await migrateHiveToSqliteIfNeeded(hiveInit: initHiveAtTempDir);

      expect(await SqfliteIdentityStore().getDisplayName(), 'Devon');
    });

    test('marks the migration done even when there are no boxes', () async {
      // First call sees nothing, sets the marker.
      await migrateHiveToSqliteIfNeeded(hiveInit: initHiveAtTempDir);

      // Now seed a Hive box. A correctly-marked install should NOT migrate
      // it on the next call.
      Hive.init(hiveDir.path);
      final box = await Hive.openBox<String>('identity');
      await box.put('displayName', 'Maya');
      await box.close();
      await Hive.close();

      await migrateHiveToSqliteIfNeeded(hiveInit: initHiveAtTempDir);

      expect(await SqfliteIdentityStore().getDisplayName(), isNull);
    });
  });
}
