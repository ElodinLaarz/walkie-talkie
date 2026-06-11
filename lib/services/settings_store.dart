import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'walkie_talkie_database.dart';

/// Persisted app settings that survive app restarts.
///
/// All settings default to sensible values (privacy-first, hands-free mode).
abstract class SettingsStore {
  /// Returns whether the user has opted in to crash reporting.
  /// Defaults to `false` (opt-out).
  Future<bool> getCrashReportingEnabled();

  /// Persists the crash reporting opt-in preference.
  Future<void> setCrashReportingEnabled(bool enabled);

  /// Returns whether push-to-talk mode is enabled.
  /// Defaults to `false` (hands-free / always-on transmit).
  Future<bool> getPttModeEnabled();

  /// Persists the push-to-talk mode preference.
  Future<void> setPttModeEnabled(bool enabled);

  /// Returns whether the screen should stay on while in a room.
  /// Defaults to `false`.
  Future<bool> getKeepScreenOn();

  /// Persists the keep-screen-on preference.
  Future<void> setKeepScreenOn(bool enabled);

  /// Removes all persisted settings. All getters return their default
  /// values until new preferences are written.
  Future<void> clear();
}

/// sqflite-backed [SettingsStore]. All keys live in the shared `kv` table
/// in [WalkieTalkieDatabase] so we don't open a second SQLite file.
class SqfliteSettingsStore implements SettingsStore {
  static const String _crashReportingKey = 'crashReportingEnabled';
  static const String _pttModeKey = 'pttModeEnabled';
  static const String _keepScreenOnKey = 'keepScreenOn';

  /// Serialises all writes (including [clear]) so a [clear] call that arrives
  /// while a [setPttModeEnabled] / [setKeepScreenOn] called via `unawaited`
  /// is still in flight never wins the race and leaves a stale key behind.
  Future<void> _writeChain = Future.value();

  Future<bool> _readBool(String key) async {
    final db = await WalkieTalkieDatabase.open();
    final rows = await db.query(
      'kv',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final raw = rows.first['value'];
    if (raw is String) return raw == '1' || raw.toLowerCase() == 'true';
    return false;
  }

  Future<void> _writeBool(String key, bool value) {
    final next = _writeChain.then((_) async {
      final db = await WalkieTalkieDatabase.open();
      await db.insert('kv', {
        'key': key,
        'value': value ? '1' : '0',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    _writeChain = next.catchError((_) {});
    return next;
  }

  @override
  Future<bool> getCrashReportingEnabled() => _readBool(_crashReportingKey);

  @override
  Future<void> setCrashReportingEnabled(bool enabled) =>
      _writeBool(_crashReportingKey, enabled);

  @override
  Future<bool> getPttModeEnabled() => _readBool(_pttModeKey);

  @override
  Future<void> setPttModeEnabled(bool enabled) =>
      _writeBool(_pttModeKey, enabled);

  @override
  Future<bool> getKeepScreenOn() => _readBool(_keepScreenOnKey);

  @override
  Future<void> setKeepScreenOn(bool enabled) =>
      _writeBool(_keepScreenOnKey, enabled);

  /// Test seam: puts an error into [_writeChain] without touching the DB,
  /// simulating a failed [_writeBool] or [clear] call.
  @visibleForTesting
  void poisonWriteChainForTesting() {
    _writeChain = Future.error(Exception('test-injected chain failure'));
  }

  @override
  Future<void> clear() {
    final next = _writeChain.then((_) async {
      final db = await WalkieTalkieDatabase.open();
      await db.delete(
        'kv',
        where: 'key IN (?, ?, ?)',
        whereArgs: [_crashReportingKey, _pttModeKey, _keepScreenOnKey],
      );
    });
    _writeChain = next.catchError((_) {});
    return next;
  }
}
