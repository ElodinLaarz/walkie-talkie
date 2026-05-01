import 'walkie_talkie_database.dart';

/// One persisted "recent" entry — the freq itself plus the user-curated
/// nickname and pin state added in the #125 naming/pinning sub-feature.
///
/// Pinned entries float to the top of the Discovery list and are exempt
/// from the rolling cap so a user-curated pin can't be quietly evicted by
/// hosting a few new channels. Nickname is purely a display label on the
/// row — joining behavior is unaffected (the freq is still the
/// authoritative key the room is dialed on).
class RecentFrequency {
  /// The MHz string the user hosted, e.g. `"92.4"`. PRIMARY KEY in the
  /// `recent_frequencies` table.
  final String freq;

  /// Optional user-supplied label. `null` means "no nickname set". On the
  /// read side, `null` is the only "cleared" sentinel — the store
  /// normalizes blank labels to `null` on write (see
  /// [RecentFrequenciesStore.setNickname]), so a row will never surface
  /// here with an empty string.
  final String? nickname;

  /// Whether the user has pinned this freq. Pinned rows render with a pin
  /// affordance, sort above unpinned rows, and survive the rolling cap
  /// applied during [RecentFrequenciesStore.record].
  final bool pinned;

  const RecentFrequency({
    required this.freq,
    this.nickname,
    this.pinned = false,
  });

  @override
  bool operator ==(Object other) =>
      other is RecentFrequency &&
      other.freq == freq &&
      other.nickname == nickname &&
      other.pinned == pinned;

  @override
  int get hashCode => Object.hash(freq, nickname, pinned);

  @override
  String toString() =>
      'RecentFrequency(freq: $freq, nickname: $nickname, pinned: $pinned)';
}

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
  /// Cap on retained **unpinned** entries. Pinned entries are user-curated
  /// and exempt — the cap exists so the auto-recorded list of "channels I
  /// happened to host" can't grow without bound, not to evict things the
  /// user explicitly asked us to remember. The Discovery screen renders
  /// every row inline, so the bound is a UX choice rather than a storage
  /// one.
  static const int maxEntries = 5;

  /// Returns the persisted list as bare freq strings, pinned-first then
  /// most-recent first within each group. Empty when nothing has been
  /// recorded yet. The returned list is unmodifiable; callers that need to
  /// mutate must copy.
  ///
  /// Equivalent to projecting [getRecentDetailed] onto its `freq` column —
  /// kept as the back-compat surface for callers that don't need the
  /// nickname / pinned metadata. The cubit + Discovery screen use
  /// [getRecentDetailed] instead so the row UI can render a pin affordance
  /// and a nickname label.
  Future<List<String>> getRecent();

  /// Returns the persisted list as full [RecentFrequency] records, pinned
  /// rows first (most-recent within pinned), then unpinned rows by
  /// recorded_at DESC. Empty when nothing has been recorded yet. The
  /// returned list is unmodifiable.
  Future<List<RecentFrequency>> getRecentDetailed();

  /// Records [freq] as the most-recent host frequency. Trims; an empty
  /// or whitespace-only value is ignored. Existing entries equal to the
  /// trimmed value are de-duplicated (the entry's recorded_at is bumped
  /// to "now" rather than inserting a second row), and any nickname /
  /// pinned state already on the row is preserved — re-hosting a channel
  /// you've nicknamed or pinned must not silently strip the metadata.
  /// Unpinned entries past [maxEntries] roll off; pinned entries are
  /// exempt from the cap.
  Future<void> record(String freq);

  /// Sets (or clears, when [nickname] is `null`) the display label for
  /// [freq]. No-op when [freq] hasn't been recorded yet — nicknames
  /// belong to existing rows and there's no creation side-effect (the
  /// Discovery UI surfaces this option only on rendered rows). Trims
  /// non-null nicknames; an empty / whitespace-only nickname is treated
  /// as a clear so callers don't accidentally store a blank label that
  /// would render as zero-width text.
  Future<void> setNickname(String freq, String? nickname);

  /// Pins or unpins [freq]. No-op when [freq] hasn't been recorded yet,
  /// for the same reason as [setNickname].
  Future<void> setPinned(String freq, bool pinned);

  /// Drops every persisted entry. The next [getRecent] returns empty.
  Future<void> clear();
}

/// sqflite-backed [RecentFrequenciesStore]. Schema: one row per freq with
/// a sortable `recorded_at` derived from epoch milliseconds (see
/// [_nextOrderingTimestamp] — it's `(epochMs << 16) + seqWithinMs`, not raw
/// epoch ms); ordering is pinned-first then by `recorded_at DESC`. We
/// dedupe on `freq` (PRIMARY KEY) so re-recording the same channel just
/// bumps its ordering timestamp instead of inserting a duplicate, and
/// preserves any `nickname` / `pinned` state already on the row.
class SqfliteRecentFrequenciesStore implements RecentFrequenciesStore {
  static const String _table = 'recent_frequencies';

  /// Serializes [record] / [setNickname] / [setPinned] / [clear] against
  /// each other. Each call chains onto the previous, so two concurrent
  /// writers can't both observe the same pre-write state and last-write-
  /// wins one of them. Errors on the chain are swallowed for the purpose
  /// of *chaining* only — the original future still surfaces the failure
  /// to its caller (and the cubit logs + drops it).
  Future<void> _writeChain = Future.value();

  /// Monotonic counter so two `record` calls in the same millisecond still
  /// land in the order they were submitted. The stored `recorded_at` is
  /// `(epochMs << 16) + seqWithinMs` so a tight burst of records keeps a
  /// stable order even when the wall-clock hasn't advanced between them.
  int _lastEpochMs = 0;
  int _seqWithinMs = 0;

  @override
  Future<List<String>> getRecent() async {
    final detailed = await getRecentDetailed();
    return List<String>.unmodifiable(detailed.map((e) => e.freq));
  }

  @override
  Future<List<RecentFrequency>> getRecentDetailed() async {
    final db = await WalkieTalkieDatabase.open();
    // Single snapshot query: pinned rows sit above unpinned rows
    // (`pinned DESC` puts the 1s before the 0s); within each group the
    // most-recent host wins. The unpinned cap is applied in-memory
    // because sqlite has no `LIMIT` that's conditional on a column —
    // splitting into two queries would race with concurrent
    // [record] / [setPinned] calls and let a row disappear from the
    // combined list (or land in the wrong half) if a flag flipped
    // between the reads.
    final rows = await db.query(
      _table,
      columns: ['freq', 'nickname', 'pinned'],
      orderBy: 'pinned DESC, recorded_at DESC',
    );
    final result = <RecentFrequency>[];
    var unpinnedCount = 0;
    for (final row in rows) {
      final recent = _rowToRecent(row);
      if (!recent.pinned) {
        if (unpinnedCount >= RecentFrequenciesStore.maxEntries) continue;
        unpinnedCount++;
      }
      result.add(recent);
    }
    return List<RecentFrequency>.unmodifiable(result);
  }

  RecentFrequency _rowToRecent(Map<String, Object?> r) {
    final rawNickname = r['nickname'] as String?;
    return RecentFrequency(
      freq: r['freq']! as String,
      // NULL stays null; an empty string in storage (shouldn't happen via
      // [setNickname], but defend against legacy data) is normalized to
      // null so the UI's "render label or fall back" branch lines up with
      // "no nickname set" semantics.
      nickname: (rawNickname == null || rawNickname.isEmpty)
          ? null
          : rawNickname,
      pinned: (r['pinned'] as int? ?? 0) != 0,
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
      // Upsert keyed on freq: same freq → bump recorded_at (move to front
      // of its group), preserving any nickname / pinned the user has
      // already set; new freq → insert with no nickname and unpinned.
      // ConflictAlgorithm.replace would wipe nickname + pinned, so use a
      // sqlite UPSERT (INSERT ... ON CONFLICT DO UPDATE) that touches
      // only `recorded_at` on conflict.
      await txn.rawInsert(
        '''
        INSERT INTO $_table (freq, recorded_at, nickname, pinned)
        VALUES (?, ?, NULL, 0)
        ON CONFLICT(freq) DO UPDATE SET recorded_at = excluded.recorded_at
        ''',
        [trimmed, orderingTimestamp],
      );
      // Cap: keep only the top-N UNPINNED by recorded_at. NOT IN with a
      // top-N sub-select is one round-trip and the table is bounded to
      // ~maxEntries + however many pins the user has set, so the scan
      // cost is trivial. Pinned rows are excluded from both the keep set
      // and the delete predicate so they stick around regardless of how
      // many fresh records arrive.
      await txn.execute(
        '''
        DELETE FROM $_table
        WHERE pinned = 0
          AND freq NOT IN (
            SELECT freq FROM $_table
            WHERE pinned = 0
            ORDER BY recorded_at DESC
            LIMIT ?
          )
        ''',
        [RecentFrequenciesStore.maxEntries],
      );
    });
  }

  @override
  Future<void> setNickname(String freq, String? nickname) {
    final next = _writeChain.then((_) => _doSetNickname(freq, nickname));
    _writeChain = next.catchError((_) {});
    return next;
  }

  Future<void> _doSetNickname(String freq, String? nickname) async {
    final trimmedFreq = freq.trim();
    if (trimmedFreq.isEmpty) return;
    // Trim a non-null nickname; an empty/whitespace-only nickname collapses
    // to null so the UI's "fall back to default label" branch fires
    // instead of rendering a zero-width nickname.
    final normalized = nickname?.trim();
    final value = (normalized == null || normalized.isEmpty)
        ? null
        : normalized;
    final db = await WalkieTalkieDatabase.open();
    await db.update(
      _table,
      {'nickname': value},
      where: 'freq = ?',
      whereArgs: [trimmedFreq],
    );
  }

  @override
  Future<void> setPinned(String freq, bool pinned) {
    final next = _writeChain.then((_) => _doSetPinned(freq, pinned));
    _writeChain = next.catchError((_) {});
    return next;
  }

  Future<void> _doSetPinned(String freq, bool pinned) async {
    final trimmedFreq = freq.trim();
    if (trimmedFreq.isEmpty) return;
    final db = await WalkieTalkieDatabase.open();
    await db.update(
      _table,
      {'pinned': pinned ? 1 : 0},
      where: 'freq = ?',
      whereArgs: [trimmedFreq],
    );
  }

  @override
  Future<void> clear() async {
    final next = _writeChain.then((_) => _doClear());
    _writeChain = next.catchError((_) {});
    return next;
  }

  Future<void> _doClear() async {
    final db = await WalkieTalkieDatabase.open();
    await db.delete(_table);
  }

  int _nextOrderingTimestamp() {
    var now = DateTime.now().millisecondsSinceEpoch;
    // Clock skew (NTP step, daylight-saving rollback, manual clock change)
    // can make `now < _lastEpochMs`. Without the `<=` branch a record taken
    // a few ms after a backward jump would land *before* prior records and
    // re-shuffle the recents order. Pin to the last seen epoch and bump
    // the sequence so the wall-clock tick is irrelevant to ordering.
    if (now <= _lastEpochMs) {
      now = _lastEpochMs;
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
