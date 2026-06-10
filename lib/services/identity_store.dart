import 'package:sqflite/sqflite.dart';

import '../protocol/uuid.dart';
import 'walkie_talkie_database.dart';

/// Persisted user identity that survives app restarts.
///
/// Carries two independent things:
///   * `displayName` — what other people on a frequency see, picked during
///     onboarding, editable via the rename sheet.
///   * `peerId` — a stable per-install UUID v4 used by the wire protocol
///     to route messages and tag voice frames. Generated lazily on first
///     read, never changes once created, completely decoupled from the
///     display name (renames don't perturb it).
abstract class IdentityStore {
  /// Returns the persisted display name, or `null` if onboarding has not
  /// completed.
  Future<String?> getDisplayName();

  /// Persists the display name. The value is trimmed; an empty string is
  /// treated as a clear and removes the persisted name.
  Future<void> setDisplayName(String value);

  /// Returns the persisted peerId, generating a fresh UUID v4 on first
  /// call and persisting it before returning. Idempotent for the install
  /// lifetime — the same id is returned on every subsequent call across
  /// app restarts.
  Future<String> getPeerId();

  /// Removes all persisted identity data (display name and peer ID).
  /// The next [getPeerId] call after [clear] generates a fresh UUID.
  Future<void> clear();
}

/// sqflite-backed [IdentityStore]. Both keys live in the shared `kv` table
/// in [WalkieTalkieDatabase] so we don't open a second SQLite file just for
/// identity.
class SqfliteIdentityStore implements IdentityStore {
  static const String _displayNameKey = 'displayName';
  static const String _peerIdKey = 'peerId';

  /// Single-flight cache for [getPeerId]. The first caller starts the
  /// get-or-create; every concurrent caller awaits the same future, so all
  /// callers in the same session see the same id even on a fresh install.
  Future<String>? _peerIdFuture;

  @override
  Future<String?> getDisplayName() async {
    final db = await WalkieTalkieDatabase.open();
    final rows = await db.query(
      'kv',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_displayNameKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['value'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<void> setDisplayName(String value) async {
    final db = await WalkieTalkieDatabase.open();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await db.delete('kv', where: 'key = ?', whereArgs: [_displayNameKey]);
    } else {
      await db.insert('kv', {
        'key': _displayNameKey,
        'value': trimmed,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  @override
  Future<String> getPeerId() => _peerIdFuture ??= _readOrCreatePeerId();

  Future<String> _readOrCreatePeerId() async {
    final db = await WalkieTalkieDatabase.open();
    final rows = await db.query(
      'kv',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_peerIdKey],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final raw = rows.first['value'];
      if (raw is String && raw.isNotEmpty) return raw;
    }
    final fresh = generateUuidV4();
    await db.insert('kv', {
      'key': _peerIdKey,
      'value': fresh,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return fresh;
  }

  @override
  Future<void> clear() async {
    // Await any in-flight _readOrCreatePeerId so its db.insert completes
    // before we delete — otherwise the insert wins the race and leaves the
    // old peer ID in kv after clear() returns.
    try {
      await _peerIdFuture;
    } catch (_) {}
    // Delete rows before nulling the cache. If we null first, a concurrent
    // getPeerId() can start a new _readOrCreatePeerId, read the not-yet-deleted
    // row, and cache the stale ID — leaving it cached after the delete.
    final db = await WalkieTalkieDatabase.open();
    await db.delete(
      'kv',
      where: 'key = ? OR key = ?',
      whereArgs: [_displayNameKey, _peerIdKey],
    );
    _peerIdFuture = null;
  }
}
