import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:walkie_talkie/services/identity_store.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('identity_store_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('HiveIdentityStore', () {
    test('returns null before any name has been set', () async {
      final store = HiveIdentityStore();
      expect(await store.getDisplayName(), isNull);
    });

    test('round-trips a display name', () async {
      final store = HiveIdentityStore();
      await store.setDisplayName('Maya');
      expect(await store.getDisplayName(), 'Maya');
    });

    test('persists across new HiveIdentityStore instances', () async {
      final first = HiveIdentityStore();
      await first.setDisplayName('Devon');
      // Different in-memory wrapper, same Hive path → reopens the same box.
      final second = HiveIdentityStore();
      expect(await second.getDisplayName(), 'Devon');
    });

    test('overwrites the prior name', () async {
      final store = HiveIdentityStore();
      await store.setDisplayName('Maya');
      await store.setDisplayName('Maya R.');
      expect(await store.getDisplayName(), 'Maya R.');
    });

    test('trims whitespace on set and on get', () async {
      final store = HiveIdentityStore();
      await store.setDisplayName('   Priya   ');
      expect(await store.getDisplayName(), 'Priya');
    });

    test('treats empty / whitespace-only as a clear', () async {
      final store = HiveIdentityStore();
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
        final store = HiveIdentityStore();
        final id = await store.getPeerId();
        expect(id, matches(uuidV4Pattern));
      });

      test('is idempotent within a session', () async {
        final store = HiveIdentityStore();
        final a = await store.getPeerId();
        final b = await store.getPeerId();
        expect(a, b);
      });

      test('persists across HiveIdentityStore instances', () async {
        final first = HiveIdentityStore();
        final id = await first.getPeerId();
        final second = HiveIdentityStore();
        expect(await second.getPeerId(), id);
      });

      test('renaming the display name does not change peerId', () async {
        final store = HiveIdentityStore();
        await store.setDisplayName('Maya');
        final id = await store.getPeerId();
        await store.setDisplayName('Devon');
        expect(await store.getPeerId(), id);
      });

      test('clearing the display name does not clear peerId', () async {
        final store = HiveIdentityStore();
        await store.setDisplayName('Maya');
        final id = await store.getPeerId();
        await store.setDisplayName(''); // clears displayName
        expect(await store.getDisplayName(), isNull);
        expect(await store.getPeerId(), id);
      });

      test('a fresh install generates a new id (not a constant)', () async {
        // Guards against regressions like swapping `Random.secure()` for a
        // seedable `Random()` or hard-coding a constant — both would slip
        // past the round-trip and format tests above.
        final firstId = await HiveIdentityStore().getPeerId();
        // Wipe persisted state and re-init Hive at the same path.
        await Hive.deleteFromDisk();
        Hive.init(tempDir.path);
        final secondId = await HiveIdentityStore().getPeerId();
        expect(secondId, isNot(equals(firstId)));
        expect(secondId, matches(uuidV4Pattern));
      });
    });
  });
}
