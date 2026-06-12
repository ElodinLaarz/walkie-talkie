import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show Sqflite;
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

    test(
      'copies displayName + peerId from a legacy Hive identity box',
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
      },
    );

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

    test(
      'caps migrated recents at maxEntries even when legacy list is longer',
      () async {
        Hive.init(hiveDir.path);
        final box = await Hive.openBox<dynamic>('recent_frequencies');
        // Seed 8 entries (> maxEntries=5), most-recent-first.
        await box.put('list', <dynamic>[
          'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8',
        ]);
        await box.close();
        await Hive.close();

        await migrateHiveToSqliteIfNeeded(hiveInit: initHiveAtTempDir);

        final store = SqfliteRecentFrequenciesStore();
        final recents = await store.getRecent();
        // Only the 5 most-recent entries survive; on-disk row count must also
        // be 5 (the store's invariant holds at migration time, not just in
        // the display-layer truncation).
        expect(recents.length, RecentFrequenciesStore.maxEntries);
        expect(recents, ['f1', 'f2', 'f3', 'f4', 'f5']);

        final db = await WalkieTalkieDatabase.open();
        final count = Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM recent_frequencies',
          ),
        );
        expect(count, RecentFrequenciesStore.maxEntries);
      },
    );

    test(
      'synthesized recorded_at stays within the JS safe-integer range',
      () async {
        // Regression for the `epochMs << 16` form, which (* 65536 ~= 1.1e17)
        // overflows the 53-bit safe-integer range on the Dart-web backend and
        // silently corrupts recents ordering. The `* 1000` form must keep
        // every synthesized timestamp <= 2^53 - 1.
        Hive.init(hiveDir.path);
        final box = await Hive.openBox<dynamic>('recent_frequencies');
        await box.put('list', <dynamic>['100.1', '92.4', '88.7']);
        await box.close();
        await Hive.close();

        await migrateHiveToSqliteIfNeeded(hiveInit: initHiveAtTempDir);

        final db = await WalkieTalkieDatabase.open();
        final maxTs = Sqflite.firstIntValue(
          await db.rawQuery('SELECT MAX(recorded_at) FROM recent_frequencies'),
        );
        const maxSafeInt = 0x1FFFFFFFFFFFFF; // 2^53 - 1
        expect(maxTs, isNotNull);
        expect(maxTs! <= maxSafeInt, isTrue,
            reason: 'recorded_at $maxTs exceeds the JS safe-integer range');
      },
    );

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
