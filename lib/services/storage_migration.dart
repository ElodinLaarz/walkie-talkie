import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:sqflite/sqflite.dart';

import 'walkie_talkie_database.dart';

/// One-shot migration from Hive (v0 storage) to sqflite. The marker
/// `migrated_from_hive_v1` in `kv` records that we've run; subsequent
/// launches skip the Hive code path entirely so we don't pay
/// `Hive.initFlutter()` for installs that were never on Hive.
///
/// Best-effort, but with a deliberate split:
///   * **Per-box errors are caught and the marker is still written.**
///     Box corruption is permanent — retry-looping on it would just brick
///     bootstrap. We log the failure and move on; whatever data made it
///     through is what the user has.
///   * **sqflite-side errors propagate.** If we can't write the marker
///     because SQLite itself is sick, the call throws and the next
///     bootstrap retries the whole migration — which is what addresses
///     transient (DB-locked, disk-full) failures naturally.
Future<void> migrateHiveToSqliteIfNeeded({
  Future<void> Function()? hiveInit,
}) async {
  final db = await WalkieTalkieDatabase.open();
  final marker = await db.query(
    'kv',
    columns: ['value'],
    where: 'key = ?',
    whereArgs: [_markerKey],
    limit: 1,
  );
  if (marker.isNotEmpty) return;

  // hiveInit override exists so unit tests can stub the Flutter-only
  // `Hive.initFlutter()` (it pulls the app documents dir via path_provider,
  // which the Dart-side suite doesn't have access to). If init itself fails
  // there's no legacy data we can read anyway — write the marker and stop.
  try {
    await (hiveInit ?? Hive.initFlutter)();
  } catch (e, st) {
    debugPrint(
      'Hive→sqflite: Hive init failed; nothing to migrate: $e\n$st',
    );
    await _writeMarker(db);
    return;
  }

  // Each box's migration is independent — one corrupt box must not stop
  // the other from migrating.
  try {
    await _migrateIdentity(db);
  } catch (e, st) {
    debugPrint(
      'Hive→sqflite: identity box migration failed (best effort): $e\n$st',
    );
  }
  try {
    await _migrateRecents(db);
  } catch (e, st) {
    debugPrint(
      'Hive→sqflite: recents box migration failed (best effort): $e\n$st',
    );
  }

  // The marker write is intentionally NOT in a try/catch: if SQLite itself
  // throws here, the call throws out and the next bootstrap retries — which
  // is the right behavior for transient sqflite failures.
  await _writeMarker(db);
}

Future<void> _writeMarker(Database db) {
  return db.insert(
    'kv',
    {'key': _markerKey, 'value': 'done'},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

const String _markerKey = 'migrated_from_hive_v1';

Future<void> _migrateIdentity(Database db) async {
  if (!await Hive.boxExists(_identityBox)) return;
  final box = await Hive.openBox<String>(_identityBox);
  try {
    final displayName = box.get(_displayNameKey);
    final peerId = box.get(_peerIdKey);
    if (displayName != null && displayName.trim().isNotEmpty) {
      await db.insert(
        'kv',
        {'key': 'displayName', 'value': displayName.trim()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (peerId != null && peerId.isNotEmpty) {
      await db.insert(
        'kv',
        {'key': 'peerId', 'value': peerId},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  } finally {
    await box.close();
  }
  await Hive.deleteBoxFromDisk(_identityBox);
}

Future<void> _migrateRecents(Database db) async {
  if (!await Hive.boxExists(_recentsBox)) return;
  final box = await Hive.openBox<dynamic>(_recentsBox);
  try {
    final raw = box.get(_recentsListKey);
    if (raw is List) {
      // Hive stored entries most-recent-first under a single list key; the
      // sqflite schema orders by recorded_at DESC, so we walk the list in
      // reverse and let each successive insert get a larger timestamp.
      final entries = raw
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      var ts = DateTime.now().millisecondsSinceEpoch << 16;
      await db.transaction((txn) async {
        for (final freq in entries.reversed) {
          ts += 1;
          await txn.insert(
            'recent_frequencies',
            {'freq': freq, 'recorded_at': ts},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    }
  } finally {
    await box.close();
  }
  await Hive.deleteBoxFromDisk(_recentsBox);
}

const String _identityBox = 'identity';
const String _displayNameKey = 'displayName';
const String _peerIdKey = 'peerId';

const String _recentsBox = 'recent_frequencies';
const String _recentsListKey = 'list';
