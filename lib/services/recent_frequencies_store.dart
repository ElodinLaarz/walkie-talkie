import 'package:hive/hive.dart';

/// Persisted "frequencies the local user has hosted" list, most-recent
/// first, capped at [HiveRecentFrequenciesStore.maxEntries]. Lets the
/// Discovery screen offer one-tap resume of recent personal channels
/// without redialling a fresh random freq each visit.
///
/// Decoupled from [IdentityStore] on purpose: identity carries who the
/// user is (display name + peerId); recent frequencies are a UX
/// convenience the user can clear without losing their identity. Mixing
/// them in one box would conflate "rename me" with "forget my channel
/// history".
abstract class RecentFrequenciesStore {
  /// Returns the persisted list, most-recent first. Empty when nothing
  /// has been recorded yet. The returned list is unmodifiable; callers
  /// that need to mutate must copy.
  Future<List<String>> getRecent();

  /// Records [freq] as the most-recent host frequency. Trims; an empty
  /// or whitespace-only value is ignored. Existing entries equal to the
  /// trimmed value are de-duplicated (the entry moves to the front
  /// rather than being added a second time). The list is capped at
  /// [HiveRecentFrequenciesStore.maxEntries] — older entries roll off
  /// the end.
  Future<void> record(String freq);

  /// Drops every persisted entry. The next [getRecent] returns empty.
  Future<void> clear();
}

/// Hive-backed [RecentFrequenciesStore] keyed in a single dynamic box.
///
/// The list is stored under a single key (rather than one entry per
/// indexed key) so reordering on `record` is a single put — the cap is
/// small enough that the cost of rewriting the whole list is negligible
/// and the bounded size keeps the box compact.
class HiveRecentFrequenciesStore implements RecentFrequenciesStore {
  static const String _boxName = 'recent_frequencies';
  static const String _key = 'list';

  /// Cap on retained entries. The Discovery screen renders all of them
  /// inline, so the bound is a UX choice rather than a storage one.
  static const int maxEntries = 5;

  // `Box<dynamic>` because Hive's typed boxes don't model `List<String>`
  // cleanly without a custom adapter — the value-type parameter is the
  // *element* type, but a list value would need the box's element type
  // to be the list itself. Casting on read keeps the call sites typed.
  Box<dynamic>? _box;

  /// In-flight `Hive.openBox` call. Cached so concurrent first-callers
  /// share a single open instead of each issuing their own request to
  /// Hive's internals. Cleared after the open settles so a later cycle
  /// (e.g. a test calling `Hive.deleteFromDisk` + re-init) re-opens
  /// against the new path instead of returning the old closed box.
  Future<Box<dynamic>>? _openFuture;

  /// Serializes `record` against itself. Each call chains onto the
  /// previous, so two concurrent records can't both observe the same
  /// pre-write state and last-write-wins one of them out of the list.
  /// Errors on the chain are swallowed for the purpose of *chaining*
  /// only — the original future still surfaces the failure to its
  /// caller (and the cubit logs + drops it).
  Future<void> _writeChain = Future.value();

  Future<Box<dynamic>> _open() async {
    final existing = _box;
    if (existing != null && existing.isOpen) return existing;
    final pending = _openFuture;
    if (pending != null) return pending;
    final future = Hive.openBox<dynamic>(_boxName);
    _openFuture = future;
    try {
      final box = await future;
      _box = box;
      return box;
    } finally {
      _openFuture = null;
    }
  }

  @override
  Future<List<String>> getRecent() async {
    final box = await _open();
    final raw = box.get(_key);
    if (raw is! List) return const [];
    return List<String>.unmodifiable(raw.cast<String>());
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
    final box = await _open();
    final raw = box.get(_key);
    final current = raw is List ? raw.cast<String>() : const <String>[];
    final updated = <String>[trimmed];
    for (final entry in current) {
      if (entry == trimmed) continue;
      updated.add(entry);
      if (updated.length >= maxEntries) break;
    }
    await box.put(_key, updated);
  }

  @override
  Future<void> clear() async {
    final box = await _open();
    await box.delete(_key);
  }
}
