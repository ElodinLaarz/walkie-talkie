import 'package:sqflite/sqflite.dart';

import 'walkie_talkie_database.dart';

/// Persisted set of peerIds the local user has muted, so the choice
/// survives app restarts and re-joins of the same frequency. Without
/// this, `_peerMuted` in [`FrequencyRoomScreen`] is session-local and
/// the user has to re-mute the same person every time they walk back
/// into the room (#125).
///
/// Keyed by stable peerId (the BLE-advertised UUID, not a session-local
/// id) so the persisted mute matches the same physical peer across
/// sessions even when displayName / btDevice change.
abstract class BlockedPeersStore {
  /// Returns every currently-blocked peerId. Order is unspecified — the
  /// caller's expected use is membership checks, not iteration order.
  Future<Set<String>> getAll();

  /// Records [peerId] as blocked. Re-blocking an already-blocked peer
  /// is a no-op (idempotent). Whitespace-only inputs are ignored so a
  /// caller that hands us a malformed peerId can't pollute the table.
  Future<void> block(String peerId);

  /// Removes [peerId] from the blocked set. Unblocking a peer that
  /// isn't blocked is a no-op.
  Future<void> unblock(String peerId);

  /// Drops every persisted entry. The next [getAll] returns empty.
  Future<void> clear();
}

/// sqflite-backed [BlockedPeersStore]. Schema: one row per blocked
/// peerId with `blocked_at` for diagnostic ordering only — the API
/// surface returns an unordered set.
class SqfliteBlockedPeersStore implements BlockedPeersStore {
  static const String _table = 'blocked_peers';

  /// Serializes writes against themselves the same way
  /// [`SqfliteRecentFrequenciesStore`] does: two concurrent block /
  /// unblock calls otherwise race the read-modify-write inside the
  /// upsert and last-write-wins one of them out of the table.
  Future<void> _writeChain = Future.value();

  @override
  Future<Set<String>> getAll() async {
    final db = await WalkieTalkieDatabase.open();
    final rows = await db.query(_table, columns: ['peer_id']);
    return rows.map((r) => r['peer_id']).whereType<String>().toSet();
  }

  @override
  Future<void> block(String peerId) {
    final next = _writeChain.then((_) => _doBlock(peerId));
    _writeChain = next.catchError((_) {});
    return next;
  }

  Future<void> _doBlock(String peerId) async {
    final trimmed = peerId.trim();
    if (trimmed.isEmpty) return;
    final db = await WalkieTalkieDatabase.open();
    await db.insert(
      _table,
      {
        'peer_id': trimmed,
        'blocked_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> unblock(String peerId) {
    final next = _writeChain.then((_) => _doUnblock(peerId));
    _writeChain = next.catchError((_) {});
    return next;
  }

  Future<void> _doUnblock(String peerId) async {
    final trimmed = peerId.trim();
    if (trimmed.isEmpty) return;
    final db = await WalkieTalkieDatabase.open();
    await db.delete(_table, where: 'peer_id = ?', whereArgs: [trimmed]);
  }

  @override
  Future<void> clear() async {
    final db = await WalkieTalkieDatabase.open();
    await db.delete(_table);
  }
}
