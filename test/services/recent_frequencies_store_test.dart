import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';
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

  group('SqfliteRecentFrequenciesStore', () {
    test('returns an empty list before any record', () async {
      final store = SqfliteRecentFrequenciesStore();
      expect(await store.getRecent(), isEmpty);
    });

    test('record + getRecent round-trips a single entry', () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      expect(await store.getRecent(), ['92.4']);
    });

    test('most recent entry comes first', () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      await store.record('100.1');
      await store.record('88.7');
      expect(await store.getRecent(), ['88.7', '100.1', '92.4']);
    });

    test('re-recording an existing freq de-dupes and moves it to the front',
        () async {
      // Without dedupe, hosting the same channel twice would crowd out
      // older entries with copies of itself.
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      await store.record('100.1');
      await store.record('92.4');
      expect(await store.getRecent(), ['92.4', '100.1']);
    });

    test('caps the list at maxEntries (older entries roll off)', () async {
      final store = SqfliteRecentFrequenciesStore();
      // Record one more than the cap.
      for (var i = 0; i <= RecentFrequenciesStore.maxEntries; i++) {
        await store.record('${88 + i}.0');
      }
      final recent = await store.getRecent();
      expect(recent, hasLength(RecentFrequenciesStore.maxEntries));
      // The very first record (88.0) should have rolled off.
      expect(recent, isNot(contains('88.0')));
      // Most recent is at the front.
      expect(recent.first, '${88 + RecentFrequenciesStore.maxEntries}.0');
    });

    test('record trims whitespace', () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('   92.4   ');
      expect(await store.getRecent(), ['92.4']);
    });

    test('record with empty / whitespace-only is a no-op', () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      await store.record('');
      await store.record('   ');
      expect(await store.getRecent(), ['92.4']);
    });

    test('persists across new SqfliteRecentFrequenciesStore instances',
        () async {
      final first = SqfliteRecentFrequenciesStore();
      await first.record('92.4');
      await first.record('100.1');

      final second = SqfliteRecentFrequenciesStore();
      expect(await second.getRecent(), ['100.1', '92.4']);
    });

    test('clear empties the list', () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      await store.record('100.1');
      await store.clear();
      expect(await store.getRecent(), isEmpty);
    });

    test('concurrent record calls do not lose entries', () async {
      // Without serialization, the read-modify-write inside `record`
      // races: two callers can both read the same pre-write state and
      // last-write-wins one of them out of the list. Fire several in
      // parallel — every freq should survive.
      final store = SqfliteRecentFrequenciesStore();
      await Future.wait([
        store.record('92.4'),
        store.record('100.1'),
        store.record('88.7'),
        store.record('104.3'),
      ]);
      final recent = await store.getRecent();
      expect(recent.toSet(), {'92.4', '100.1', '88.7', '104.3'});
    });

    test('getRecent returns an unmodifiable list', () async {
      // Callers shouldn't be able to mutate the returned list and have
      // their changes observed by anyone else (or, worse, accidentally
      // mutate cached state inside the store).
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      final recent = await store.getRecent();
      expect(() => recent.add('100.1'), throwsUnsupportedError);
    });
  });
}
