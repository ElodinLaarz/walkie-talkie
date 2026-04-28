import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('recent_freqs_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('HiveRecentFrequenciesStore', () {
    test('returns an empty list before any record', () async {
      final store = HiveRecentFrequenciesStore();
      expect(await store.getRecent(), isEmpty);
    });

    test('record + getRecent round-trips a single entry', () async {
      final store = HiveRecentFrequenciesStore();
      await store.record('92.4');
      expect(await store.getRecent(), ['92.4']);
    });

    test('most recent entry comes first', () async {
      final store = HiveRecentFrequenciesStore();
      await store.record('92.4');
      await store.record('100.1');
      await store.record('88.7');
      expect(await store.getRecent(), ['88.7', '100.1', '92.4']);
    });

    test('re-recording an existing freq de-dupes and moves it to the front',
        () async {
      // Without dedupe, hosting the same channel twice would crowd out
      // older entries with copies of itself.
      final store = HiveRecentFrequenciesStore();
      await store.record('92.4');
      await store.record('100.1');
      await store.record('92.4');
      expect(await store.getRecent(), ['92.4', '100.1']);
    });

    test('caps the list at maxEntries (older entries roll off)', () async {
      final store = HiveRecentFrequenciesStore();
      // Record one more than the cap.
      for (var i = 0; i <= HiveRecentFrequenciesStore.maxEntries; i++) {
        await store.record('${88 + i}.0');
      }
      final recent = await store.getRecent();
      expect(recent, hasLength(HiveRecentFrequenciesStore.maxEntries));
      // The very first record (88.0) should have rolled off.
      expect(recent, isNot(contains('88.0')));
      // Most recent is at the front.
      expect(recent.first,
          '${88 + HiveRecentFrequenciesStore.maxEntries}.0');
    });

    test('record trims whitespace', () async {
      final store = HiveRecentFrequenciesStore();
      await store.record('   92.4   ');
      expect(await store.getRecent(), ['92.4']);
    });

    test('record with empty / whitespace-only is a no-op', () async {
      final store = HiveRecentFrequenciesStore();
      await store.record('92.4');
      await store.record('');
      await store.record('   ');
      expect(await store.getRecent(), ['92.4']);
    });

    test('persists across new HiveRecentFrequenciesStore instances', () async {
      final first = HiveRecentFrequenciesStore();
      await first.record('92.4');
      await first.record('100.1');

      final second = HiveRecentFrequenciesStore();
      expect(await second.getRecent(), ['100.1', '92.4']);
    });

    test('clear empties the list', () async {
      final store = HiveRecentFrequenciesStore();
      await store.record('92.4');
      await store.record('100.1');
      await store.clear();
      expect(await store.getRecent(), isEmpty);
    });

    test('getRecent returns an unmodifiable list', () async {
      // Callers shouldn't be able to mutate the returned list and have
      // their changes observed by anyone else (or, worse, accidentally
      // mutate cached state inside Hive's box).
      final store = HiveRecentFrequenciesStore();
      await store.record('92.4');
      final recent = await store.getRecent();
      expect(() => recent.add('100.1'), throwsUnsupportedError);
    });
  });
}
