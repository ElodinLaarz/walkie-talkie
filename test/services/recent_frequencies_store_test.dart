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

    // ── Naming + pinning (#125) ──────────────────────────────────────

    test('getRecentDetailed returns RecentFrequency records', () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('100.1');
      await store.record('92.4');

      final detailed = await store.getRecentDetailed();
      expect(detailed.map((e) => e.freq).toList(), ['92.4', '100.1']);
      // Fresh records start with no nickname and unpinned.
      expect(detailed.every((e) => e.nickname == null), isTrue);
      expect(detailed.every((e) => !e.pinned), isTrue);
    });

    test('getRecentDetailed returns an unmodifiable list', () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      final detailed = await store.getRecentDetailed();
      expect(
        () => detailed.add(const RecentFrequency(freq: '100.1')),
        throwsUnsupportedError,
      );
    });

    test('setNickname trims and round-trips through getRecentDetailed',
        () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      await store.setNickname('92.4', '  Family channel  ');

      final detailed = await store.getRecentDetailed();
      expect(detailed.single.nickname, 'Family channel');
    });

    test('setNickname with null clears an existing nickname', () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      await store.setNickname('92.4', 'Family channel');
      await store.setNickname('92.4', null);

      final detailed = await store.getRecentDetailed();
      expect(detailed.single.nickname, isNull);
    });

    test('setNickname with whitespace-only collapses to null', () async {
      // Otherwise the row would render as zero-width text in the Discovery
      // UI and feel like "the nickname disappeared but isn't gone".
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      await store.setNickname('92.4', 'Family channel');
      await store.setNickname('92.4', '   ');

      final detailed = await store.getRecentDetailed();
      expect(detailed.single.nickname, isNull);
    });

    test('setNickname on an unrecorded freq is a no-op', () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.setNickname('92.4', 'Family channel');
      expect(await store.getRecentDetailed(), isEmpty);
    });

    test('record preserves an existing nickname when re-hosted', () async {
      // Re-hosting a channel must not silently strip the user-curated
      // nickname — the upsert touches only `recorded_at`.
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      await store.setNickname('92.4', 'Family channel');
      await store.record('92.4');

      final detailed = await store.getRecentDetailed();
      expect(detailed.single.nickname, 'Family channel');
    });

    test('setPinned floats a pinned row to the top of getRecentDetailed',
        () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('100.1');
      await store.record('92.4');
      await store.record('88.7');
      // Without the pin, ordering is recorded_at DESC: 88.7, 92.4, 100.1.
      await store.setPinned('100.1', true);

      final detailed = await store.getRecentDetailed();
      expect(detailed.first.freq, '100.1');
      expect(detailed.first.pinned, isTrue);
      // Unpinned rows retain their relative recorded_at DESC ordering.
      expect(detailed.skip(1).map((e) => e.freq).toList(), ['88.7', '92.4']);
    });

    test('setPinned(false) demotes a row back into the unpinned group',
        () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      await store.setPinned('92.4', true);
      await store.setPinned('92.4', false);

      final detailed = await store.getRecentDetailed();
      expect(detailed.single.pinned, isFalse);
    });

    test('record preserves an existing pinned flag when re-hosted', () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');
      await store.setPinned('92.4', true);
      await store.record('92.4');

      final detailed = await store.getRecentDetailed();
      expect(detailed.single.pinned, isTrue);
    });

    test('unpinning re-applies the cap so the unpinned bucket stays bounded',
        () async {
      // The cap is on UNPINNED rows only, so a pinned row "borrows" a
      // slot. Unpinning it can push the unpinned count past `maxEntries`
      // — `_doSetPinned(false)` must drop the oldest unpinned to stay
      // bounded, otherwise the on-disk row count drifts upward whenever
      // a user pins-then-unpins.
      final store = SqfliteRecentFrequenciesStore();
      await store.record('70.0');
      await store.setPinned('70.0', true);
      // Fill the unpinned bucket to the cap with newer records.
      for (var i = 0; i < RecentFrequenciesStore.maxEntries; i++) {
        await store.record('${88 + i}.0');
      }
      // Pre-condition: maxEntries unpinned + 1 pinned = maxEntries + 1.
      var detailed = await store.getRecentDetailed();
      expect(detailed.length, RecentFrequenciesStore.maxEntries + 1);

      // Unpin 70.0. It's the oldest unpinned now, so it itself should
      // roll off the bottom of the unpinned bucket.
      await store.setPinned('70.0', false);

      detailed = await store.getRecentDetailed();
      expect(detailed.length, RecentFrequenciesStore.maxEntries);
      expect(detailed.every((e) => !e.pinned), isTrue);
      expect(detailed.any((e) => e.freq == '70.0'), isFalse);
    });

    test('pinned entries are exempt from the rolling cap', () async {
      // Otherwise a user-curated pin would silently roll off as soon as
      // the user hosted a few new channels — pinning would be meaningless.
      final store = SqfliteRecentFrequenciesStore();
      await store.record('70.0');
      await store.setPinned('70.0', true);
      // Now record more than maxEntries fresh unpinned channels.
      for (var i = 0; i <= RecentFrequenciesStore.maxEntries; i++) {
        await store.record('${88 + i}.0');
      }

      final detailed = await store.getRecentDetailed();
      // The pin is still there even though we've crossed the cap.
      expect(detailed.any((e) => e.freq == '70.0' && e.pinned), isTrue);
      // Only `maxEntries` unpinned rows survive — the pin doesn't
      // consume one of the unpinned slots.
      final unpinned = detailed.where((e) => !e.pinned).toList();
      expect(unpinned.length, RecentFrequenciesStore.maxEntries);
    });

    test('getRecent projects getRecentDetailed onto its freq column',
        () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.record('100.1');
      await store.record('92.4');
      await store.setPinned('100.1', true);

      // Pinned-first ordering applies to both surfaces.
      expect(await store.getRecent(), ['100.1', '92.4']);
    });

    test('setPinned on an unrecorded freq is a no-op', () async {
      final store = SqfliteRecentFrequenciesStore();
      await store.setPinned('92.4', true);
      expect(await store.getRecentDetailed(), isEmpty);
    });

    // ── sessionUuid (#219) ──────────────────────────────────────────

    test('record(sessionUuid: ...) round-trips through getRecentDetailed',
        () async {
      // The Resume path on Discovery reads sessionUuid off the
      // RecentFrequency record so it can reconstitute the same room
      // instead of minting a fresh UUID.
      final store = SqfliteRecentFrequenciesStore();
      const uuid = '00000000-0000-4000-8000-0000000000a3';
      await store.record('104.3', sessionUuid: uuid);

      final detailed = await store.getRecentDetailed();
      expect(detailed.single.freq, '104.3');
      expect(detailed.single.sessionUuid, uuid);
    });

    test('record without a sessionUuid leaves the column NULL', () async {
      // Pre-#219 callers and any future caller without a uuid handy.
      // Reads back as null on the model so the cubit's "fall back to
      // minting" branch fires for legacy rows.
      final store = SqfliteRecentFrequenciesStore();
      await store.record('92.4');

      final detailed = await store.getRecentDetailed();
      expect(detailed.single.sessionUuid, isNull);
    });

    test(
        're-recording the same freq with a new uuid overwrites the stored uuid',
        () async {
      // The most-recent host's sessionUuid is what Resume should target.
      // If a user re-hosts the same freq from a different session, the
      // stored uuid must move forward; otherwise Resume would dial a stale
      // session that is no longer being advertised.
      final store = SqfliteRecentFrequenciesStore();
      const uuidA = '00000000-0000-4000-8000-0000000000a3';
      const uuidB = '11111111-1111-4111-8111-1111111111a3';
      await store.record('104.3', sessionUuid: uuidA);
      await store.record('104.3', sessionUuid: uuidB);

      final detailed = await store.getRecentDetailed();
      expect(detailed, hasLength(1));
      expect(detailed.single.sessionUuid, uuidB);
    });

    test(
        're-recording with null does NOT clobber an already-stored uuid',
        () async {
      // COALESCE rule: a null incoming uuid means "I don't have one to
      // contribute," not "clear the field." Important for migration —
      // legacy callers that pass no uuid must not silently strip a uuid
      // that a post-#219 caller already persisted.
      final store = SqfliteRecentFrequenciesStore();
      const uuid = '00000000-0000-4000-8000-0000000000a3';
      await store.record('104.3', sessionUuid: uuid);
      await store.record('104.3'); // legacy-style, no uuid

      final detailed = await store.getRecentDetailed();
      expect(detailed.single.sessionUuid, uuid);
    });

    test(
        're-recording preserves nickname + pinned alongside the uuid update',
        () async {
      // Existing #125 invariant (record preserves user-curated metadata)
      // continues to hold when the sessionUuid is being updated.
      final store = SqfliteRecentFrequenciesStore();
      const uuid = '00000000-0000-4000-8000-0000000000a3';
      await store.record('104.3');
      await store.setNickname('104.3', 'Family channel');
      await store.setPinned('104.3', true);
      await store.record('104.3', sessionUuid: uuid);

      final detailed = await store.getRecentDetailed();
      expect(detailed.single.nickname, 'Family channel');
      expect(detailed.single.pinned, isTrue);
      expect(detailed.single.sessionUuid, uuid);
    });

    test('sessionUuid persists across new store instances', () async {
      // Same persistence guarantee as nickname + pinned — a fresh store
      // instance reads the uuid back off disk so a Resume after restart
      // still targets the original session.
      const uuid = '00000000-0000-4000-8000-0000000000a3';
      final first = SqfliteRecentFrequenciesStore();
      await first.record('104.3', sessionUuid: uuid);

      final second = SqfliteRecentFrequenciesStore();
      final detailed = await second.getRecentDetailed();
      expect(detailed.single.sessionUuid, uuid);
    });

    test('nickname + pinned both persist across new store instances',
        () async {
      final first = SqfliteRecentFrequenciesStore();
      await first.record('92.4');
      await first.setNickname('92.4', 'Family channel');
      await first.setPinned('92.4', true);

      final second = SqfliteRecentFrequenciesStore();
      final detailed = await second.getRecentDetailed();
      expect(detailed.single.freq, '92.4');
      expect(detailed.single.nickname, 'Family channel');
      expect(detailed.single.pinned, isTrue);
    });
  });

  group('RecentFrequency value type', () {
    test('value equality covers freq + nickname + pinned + sessionUuid', () {
      const a = RecentFrequency(
        freq: '92.4',
        nickname: 'Family',
        pinned: true,
        sessionUuid: '00000000-0000-4000-8000-0000000000a3',
      );
      const b = RecentFrequency(
        freq: '92.4',
        nickname: 'Family',
        pinned: true,
        sessionUuid: '00000000-0000-4000-8000-0000000000a3',
      );
      const cDifferentNickname = RecentFrequency(
        freq: '92.4',
        nickname: 'Other',
        pinned: true,
        sessionUuid: '00000000-0000-4000-8000-0000000000a3',
      );
      const dDifferentPinned = RecentFrequency(
        freq: '92.4',
        nickname: 'Family',
        sessionUuid: '00000000-0000-4000-8000-0000000000a3',
      );
      const eDifferentUuid = RecentFrequency(
        freq: '92.4',
        nickname: 'Family',
        pinned: true,
        sessionUuid: '11111111-1111-4111-8111-1111111111a3',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == cDifferentNickname, isFalse);
      expect(a == dDifferentPinned, isFalse);
      expect(a == eDifferentUuid, isFalse);
    });

    test('toString surfaces every field for debug logs', () {
      const r = RecentFrequency(
        freq: '92.4',
        nickname: 'Family',
        pinned: true,
        sessionUuid: '00000000-0000-4000-8000-0000000000a3',
      );
      expect(r.toString(), contains('92.4'));
      expect(r.toString(), contains('Family'));
      expect(r.toString(), contains('true'));
      expect(r.toString(), contains('00000000-0000-4000-8000-0000000000a3'));
    });
  });
}
