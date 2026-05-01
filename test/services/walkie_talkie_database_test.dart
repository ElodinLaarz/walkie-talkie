import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';
import 'package:walkie_talkie/services/walkie_talkie_database.dart';

/// Schema-migration tests. The store-level tests run against the current
/// `_dbVersion`'s `onCreate` schema; this file pins the v2 → v3
/// `recent_frequencies` upgrade specifically (#125), since a botched
/// ALTER would silently strand users with the v2 schema and the new
/// nickname / pin actions would throw at runtime.
void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    // File-backed (not :memory:) so the same path can be re-opened by the
    // production code under a fresh `_dbVersion` and exercise the upgrade
    // path. In-memory databases are per-connection, which would defeat the
    // point of the test.
    tempDir = await Directory.systemTemp.createTemp('wt_db_v3_migration_');
    WalkieTalkieDatabase.overrideDatabaseFactoryForTesting(
      databaseFactoryFfi,
      path: p.join(tempDir.path, 'wt.db'),
    );
    await WalkieTalkieDatabase.resetForTesting();
  });

  tearDown(() async {
    await WalkieTalkieDatabase.resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('recent_frequencies v2 → v3 migration', () {
    test(
      'existing v2 rows pick up nickname=NULL + pinned=0 after upgrade',
      () async {
        // Manually stand up a v2-shaped database with a couple of rows, the
        // way an installed-on-v2 user would have it on disk.
        final dbPath = p.join(tempDir.path, 'wt.db');
        final v2 = await databaseFactoryFfi.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(version: 2, onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE recent_frequencies (
                freq TEXT PRIMARY KEY NOT NULL,
                recorded_at INTEGER NOT NULL
              )
            ''');
          }),
        );
        await v2.insert(
          'recent_frequencies',
          {'freq': '92.4', 'recorded_at': 1000},
        );
        await v2.insert(
          'recent_frequencies',
          {'freq': '100.1', 'recorded_at': 2000},
        );
        await v2.close();

        // Now open via the production path which runs `_onUpgrade` to v3.
        final detailed =
            await SqfliteRecentFrequenciesStore().getRecentDetailed();

        // Both rows survive the migration with the v3 default values.
        expect(detailed.length, 2);
        for (final row in detailed) {
          expect(row.nickname, isNull);
          expect(row.pinned, isFalse);
        }
        // Setting a nickname / pin after the migration round-trips —
        // proves the new columns are actually writable, not just present.
        await SqfliteRecentFrequenciesStore()
            .setNickname('92.4', 'Family channel');
        await SqfliteRecentFrequenciesStore().setPinned('100.1', true);
        final after =
            await SqfliteRecentFrequenciesStore().getRecentDetailed();
        final nicknamed = after.firstWhere((e) => e.freq == '92.4');
        final pinned = after.firstWhere((e) => e.freq == '100.1');
        expect(nicknamed.nickname, 'Family channel');
        expect(pinned.pinned, isTrue);
      },
    );

    test(
      're-opening a v3 database is a no-op (idempotent ALTER)',
      () async {
        // First open creates fresh at the current version.
        await SqfliteRecentFrequenciesStore().record('92.4');

        // Re-open the same file. The migration won't fire because the
        // version matches, but if it ever does (e.g. someone bumps the
        // version then later reverts), the IF NOT EXISTS guards in
        // `_addRecentFrequenciesNicknameAndPinned` keep this from
        // double-ALTERing and crashing.
        await WalkieTalkieDatabase.resetForTesting();
        await expectLater(
          SqfliteRecentFrequenciesStore().getRecentDetailed(),
          completion(hasLength(1)),
        );
      },
    );
  });
}
