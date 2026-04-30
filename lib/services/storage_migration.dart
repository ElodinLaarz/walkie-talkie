import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:sqflite/sqflite.dart';

import 'walkie_talkie_database.dart';

/// One-shot migration from Hive (v0 storage) to sqflite. The marker
/// `migrated_from_hive_v1` in `kv` records that we've run; subsequent
/// launches skip the Hive code path entirely so we don't pay
/// `Hive.initFlutter()` for installs that were never on Hive.
///
/// Best-effort: if Hive can't open a box (corruption, missing files,
/// concurrent access), we log and continue with whatever data made it
/// through. The marker is still written so we don't loop on a corrupt box.
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

  try {
    // hiveInit override exists so unit tests can stub the Flutter-only
    // `Hive.initFlutter()` (it pulls the app documents dir via
    // path_provider, which the Dart-side suite doesn't have access to).
    await (hiveInit ?? Hive.initFlutter)();
    await _migrateIdentity(db);
    await _migrateRecents(db);
  } catch (e, st) {
    // Don't crash app startup on a migration failure. Surface to logs and
    // mark migrated anyway so we don't retry in a loop on a corrupt box.
    debugPrint('Hive→sqflite migration: failed best-effort path: $e\n$st');
  } finally {
    await db.insert(
      'kv',
      {'key': _markerKey, 'value': 'done'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
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
