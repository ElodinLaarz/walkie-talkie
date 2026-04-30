import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Single shared sqflite [Database] for the app's small key-value /
/// recent-frequencies storage. `IdentityStore` and `RecentFrequenciesStore`
/// both go through this so we open one connection per process and share it,
/// rather than juggling two boxes the way the Hive setup did.
///
/// Tests inject [databaseFactoryFfi] via [overrideDatabaseFactoryForTesting]
/// so the Dart-side unit suite doesn't depend on the platform channel.
class WalkieTalkieDatabase {
  WalkieTalkieDatabase._();

  static const String _dbName = 'walkie_talkie.db';
  static const int _dbVersion = 1;

  static DatabaseFactory? _factoryOverride;
  static String? _pathOverride;

  static Database? _db;
  static Future<Database>? _opening;

  /// Returns the cached open [Database], opening (and creating tables) on
  /// first call. Callers from any isolate can `await` this without racing —
  /// the in-flight open is shared.
  static Future<Database> open() {
    final existing = _db;
    if (existing != null && existing.isOpen) return Future.value(existing);
    return _opening ??= _openInternal();
  }

  static Future<Database> _openInternal() async {
    try {
      final factory = _factoryOverride ?? databaseFactory;
      final dbPath = _pathOverride ??
          p.join(await factory.getDatabasesPath(), _dbName);
      final db = await factory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: _dbVersion,
          onCreate: _onCreate,
        ),
      );
      _db = db;
      return db;
    } finally {
      _opening = null;
    }
  }

  static Future<void> _onCreate(Database db, int version) async {
    // `kv` carries singletons that don't need their own table:
    //   * displayName  — user-facing nickname (nullable: deleted on clear)
    //   * peerId       — stable per-install UUID v4
    //   * migration markers (e.g. 'migrated_from_hive_v1')
    await db.execute('''
      CREATE TABLE kv (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      )
    ''');
    // recorded_at is millisSinceEpoch; we order DESC and cap by deleting
    // entries whose freq isn't in the top-N by recorded_at.
    await db.execute('''
      CREATE TABLE recent_frequencies (
        freq TEXT PRIMARY KEY NOT NULL,
        recorded_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_recent_freq_time ON recent_frequencies (recorded_at)',
    );
  }

  /// Test seam: swap in `databaseFactoryFfi` (and an in-memory path) so unit
  /// tests don't touch the platform channel.
  @visibleForTesting
  static void overrideDatabaseFactoryForTesting(
    DatabaseFactory factory, {
    String? path,
  }) {
    _factoryOverride = factory;
    _pathOverride = path;
  }

  /// Test seam: drop the cached connection so the next [open] re-opens
  /// against the (possibly newly-overridden) factory + path.
  @visibleForTesting
  static Future<void> resetForTesting() async {
    final db = _db;
    _db = null;
    _opening = null;
    if (db != null && db.isOpen) {
      await db.close();
    }
  }
}
