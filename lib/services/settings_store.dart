import 'package:sqflite/sqflite.dart';

import 'walkie_talkie_database.dart';

/// Persisted app settings that survive app restarts.
///
/// Settings include user preferences for crash reporting, analytics,
/// and other opt-in features. All settings default to privacy-first
/// (opt-out) behavior.
abstract class SettingsStore {
  /// Returns whether the user has opted in to crash reporting.
  /// Defaults to `false` (opt-out) if never set.
  Future<bool> getCrashReportingEnabled();

  /// Persists the crash reporting opt-in preference.
  Future<void> setCrashReportingEnabled(bool enabled);
}

/// sqflite-backed [SettingsStore]. All keys live in the shared `kv` table
/// in [WalkieTalkieDatabase] so we don't open a second SQLite file.
class SqfliteSettingsStore implements SettingsStore {
  static const String _crashReportingKey = 'crashReportingEnabled';

  @override
  Future<bool> getCrashReportingEnabled() async {
    final db = await WalkieTalkieDatabase.open();
    final rows = await db.query(
      'kv',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_crashReportingKey],
      limit: 1,
    );
    if (rows.isEmpty) return false; // Default to opt-out
    final raw = rows.first['value'];
    // Accept 1, "1", "true", true
    if (raw is int) return raw == 1;
    if (raw is String) return raw == '1' || raw.toLowerCase() == 'true';
    if (raw is bool) return raw;
    return false;
  }

  @override
  Future<void> setCrashReportingEnabled(bool enabled) async {
    final db = await WalkieTalkieDatabase.open();
    await db.insert(
      'kv',
      {'key': _crashReportingKey, 'value': enabled ? 1 : 0},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
