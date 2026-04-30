import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:walkie_talkie/services/identity_store.dart';
import 'package:walkie_talkie/services/walkie_talkie_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    WalkieTalkieDatabase.overrideDatabaseFactoryForTesting(
      databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    await WalkieTalkieDatabase.resetForTesting();
  });

  tearDown(() async {
    await WalkieTalkieDatabase.resetForTesting();
  });

  group('SqfliteIdentityStore', () {
    test('returns null before any name has been set', () async {
      final store = SqfliteIdentityStore();
      expect(await store.getDisplayName(), isNull);
    });

    test('round-trips a display name', () async {
      final store = SqfliteIdentityStore();
      await store.setDisplayName('Maya');
      expect(await store.getDisplayName(), 'Maya');
    });

    test('persists across new SqfliteIdentityStore instances', () async {
      final first = SqfliteIdentityStore();
      await first.setDisplayName('Devon');
      // Different in-memory wrapper, same database connection → same row.
      final second = SqfliteIdentityStore();
      expect(await second.getDisplayName(), 'Devon');
    });

    test('overwrites the prior name', () async {
      final store = SqfliteIdentityStore();
      await store.setDisplayName('Maya');
      await store.setDisplayName('Maya R.');
      expect(await store.getDisplayName(), 'Maya R.');
    });

    test('trims whitespace on set and on get', () async {
      final store = SqfliteIdentityStore();
      await store.setDisplayName('   Priya   ');
      expect(await store.getDisplayName(), 'Priya');
    });

    test('treats empty / whitespace-only as a clear', () async {
      final store = SqfliteIdentityStore();
      await store.setDisplayName('Sam');
      await store.setDisplayName('   ');
      expect(await store.getDisplayName(), isNull);
    });

    group('getPeerId', () {
      // Canonical UUID v4: 8-4-4-4-12 hex with the version nibble pinned
      // to `4` and the variant top bits to `10` (so the 4-segment starts
      // with `4` and the 5-segment starts with 8/9/a/b).
      final uuidV4Pattern = RegExp(
        r'^[0-9a-f]{8}-'
        r'[0-9a-f]{4}-'
        r'4[0-9a-f]{3}-'
        r'[89ab][0-9a-f]{3}-'
        r'[0-9a-f]{12}$',
      );

      test('returns a UUID v4 string', () async {
        final store = SqfliteIdentityStore();
        final id = await store.getPeerId();
        expect(id, matches(uuidV4Pattern));
      });

      test('is idempotent within a session', () async {
        final store = SqfliteIdentityStore();
        final a = await store.getPeerId();
        final b = await store.getPeerId();
        expect(a, b);
      });

      test('persists across SqfliteIdentityStore instances', () async {
        final first = SqfliteIdentityStore();
        final id = await first.getPeerId();
        final second = SqfliteIdentityStore();
        expect(await second.getPeerId(), id);
      });

      test('renaming the display name does not change peerId', () async {
        final store = SqfliteIdentityStore();
        await store.setDisplayName('Maya');
        final id = await store.getPeerId();
        await store.setDisplayName('Devon');
        expect(await store.getPeerId(), id);
      });

      test('clearing the display name does not clear peerId', () async {
        final store = SqfliteIdentityStore();
        await store.setDisplayName('Maya');
        final id = await store.getPeerId();
        await store.setDisplayName(''); // clears displayName
        expect(await store.getDisplayName(), isNull);
        expect(await store.getPeerId(), id);
      });

      test('concurrent first calls return the same id (no race)', () async {
        // Without the single-flight cache, multiple callers on a fresh
        // install can each observe a missing row, generate different
        // UUIDs, and last-write-wins on the kv table — leaving callers
        // holding ids that don't match what got persisted.
        final store = SqfliteIdentityStore();
        final ids = await Future.wait(
          List.generate(8, (_) => store.getPeerId()),
        );
        expect(ids.toSet(), hasLength(1));
        // And the persisted value matches what callers received.
        expect(await SqfliteIdentityStore().getPeerId(), ids.first);
      });

      test('a fresh install generates a new id (not a constant)', () async {
        // Guards against regressions like swapping `Random.secure()` for a
        // seedable `Random()` or hard-coding a constant — both would slip
        // past the round-trip and format tests above.
        final firstId = await SqfliteIdentityStore().getPeerId();
        // Wipe persisted state and re-init the database at the same path.
        await WalkieTalkieDatabase.resetForTesting();
        WalkieTalkieDatabase.overrideDatabaseFactoryForTesting(
          databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        final secondId = await SqfliteIdentityStore().getPeerId();
        expect(secondId, isNot(equals(firstId)));
        expect(secondId, matches(uuidV4Pattern));
      });
    });
  });
}
