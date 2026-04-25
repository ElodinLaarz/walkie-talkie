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
  });
}
