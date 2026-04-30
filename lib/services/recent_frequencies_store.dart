import 'package:sqflite/sqflite.dart';

import 'walkie_talkie_database.dart';

/// Persisted "frequencies the local user has hosted" list, most-recent
/// first, capped at [RecentFrequenciesStore.maxEntries]. Lets the
/// Discovery screen offer one-tap resume of recent personal channels
/// without redialling a fresh random freq each visit.
///
/// Decoupled from [IdentityStore] on purpose: identity carries who the
/// user is (display name + peerId); recent frequencies are a UX
/// convenience the user can clear without losing their identity. Mixing
/// them in one box would conflate "rename me" with "forget my channel
/// history".
abstract class RecentFrequenciesStore {
  /// Cap on retained entries. The Discovery screen renders all of them
  /// inline, so the bound is a UX choice rather than a storage one.
  static const int maxEntries = 5;

  /// Returns the persisted list, most-recent first. Empty when nothing
  /// has been recorded yet. The returned list is unmodifiable; callers
  /// that need to mutate must copy.
  Future<List<String>> getRecent();

  /// Records [freq] as the most-recent host frequency. Trims; an empty
  /// or whitespace-only value is ignored. Existing entries equal to the
  /// trimmed value are de-duplicated (the entry moves to the front
  /// rather than being added a second time). The list is capped at
  /// [maxEntries] — older entries roll off the end.
  Future<void> record(String freq);

  /// Drops every persisted entry. The next [getRecent] returns empty.
  Future<void> clear();
}

/// sqflite-backed [RecentFrequenciesStore]. Schema: one row per freq with
/// a millisecond `recorded_at`; ordering is by `recorded_at DESC`. We
/// dedupe on `freq` (PRIMARY KEY) so re-recording the same channel just
/// bumps its timestamp instead of inserting a duplicate.
class SqfliteRecentFrequenciesStore implements RecentFrequenciesStore {
  static const String _table = 'recent_frequencies';

  /// Serializes [record] against itself. Each call chains onto the
  /// previous, so two concurrent records can't both observe the same
  /// pre-write state and last-write-wins one of them out of the list.
  /// Errors on the chain are swallowed for the purpose of *chaining*
  /// only — the original future still surfaces the failure to its
  /// caller (and the cubit logs + drops it).
  Future<void> _writeChain = Future.value();

  /// Monotonic counter so two `record` calls in the same millisecond still
  /// land in the order they were submitted. The stored `recorded_at` is
  /// `(epochMs << 16) + seqWithinMs` so a tight burst of records keeps a
  /// stable order even when the wall-clock hasn't advanced between them.
  int _lastEpochMs = 0;
  int _seqWithinMs = 0;

  @override
  Future<List<String>> getRecent() async {
    final db = await WalkieTalkieDatabase.open();
    final rows = await db.query(
      _table,
      columns: ['freq'],
      orderBy: 'recorded_at DESC',
      limit: RecentFrequenciesStore.maxEntries,
    );
    return List<String>.unmodifiable(
      rows.map((r) => r['freq']).whereType<String>(),
    );
  }

  @override
  Future<void> record(String freq) {
    final next = _writeChain.then((_) => _doRecord(freq));
    _writeChain = next.catchError((_) {});
    return next;
  }

  Future<void> _doRecord(String freq) async {
    final trimmed = freq.trim();
    if (trimmed.isEmpty) return;
    final db = await WalkieTalkieDatabase.open();
    final orderingTimestamp = _nextOrderingTimestamp();
    await db.transaction((txn) async {
      // Upsert keyed on freq: same freq → bump recorded_at (move to front);
      // new freq → insert. ConflictAlgorithm.replace preserves the row's
      // primary key (freq) so the in-place bump is visible to the next
      // ORDER BY recorded_at DESC.
      await txn.insert(
        _table,
        {'freq': trimmed, 'recorded_at': orderingTimestamp},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      // Cap: keep only the top-N by recorded_at. NOT IN with a top-N
      // sub-select is one round-trip and the table is bounded to ~maxEntries
      // so the scan cost is trivial.
      await txn.execute(
        '''
        DELETE FROM $_table
        WHERE freq NOT IN (
          SELECT freq FROM $_table
          ORDER BY recorded_at DESC
          LIMIT ?
        )
        ''',
        [RecentFrequenciesStore.maxEntries],
      );
    });
  }

  @override
  Future<void> clear() async {
    final db = await WalkieTalkieDatabase.open();
    await db.delete(_table);
  }

  int _nextOrderingTimestamp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now == _lastEpochMs) {
      _seqWithinMs += 1;
    } else {
      _lastEpochMs = now;
      _seqWithinMs = 0;
    }
    // 16 bits of intra-ms sequence is far more than we'll ever need; the
    // total still fits comfortably in INTEGER (2^63).
    return (now << 16) + _seqWithinMs;
  }
}
