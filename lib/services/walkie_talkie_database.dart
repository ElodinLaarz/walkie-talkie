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
  // v2 (2026-04): added `blocked_peers` for #125 (persistent block list).
  // v3 (2026-04): added `nickname` + `pinned` to `recent_frequencies` for
  // the #125 naming/pinning sub-feature. Existing rows get `nickname=NULL`
  // and `pinned=0`, so the legacy unpinned-most-recent-first ordering is
  // unchanged for users who upgrade with no pinned entries.
  // v4 (2026-05): added `session_uuid` to `recent_frequencies` for #219 so
  // tapping Resume on a recent row reconstitutes the original
  // `FrequencySession` instead of minting a fresh UUID (and therefore a
  // fresh mhzDisplay). Existing rows get `session_uuid=NULL`; the cubit's
  // host path falls back to minting a new UUID for those, matching pre-#219
  // behaviour until the row is re-recorded.
  static const int _dbVersion = 4;

  static DatabaseFactory? _factoryOverride;
  static String? _pathOverride;

  static Database? _db;
  static Future<Database>? _opening;

  /// Returns the cached open [Database], opening (and creating tables) on
  /// first call. Callers within the same isolate can `await` this without
  /// racing — the in-flight open is shared. Note the static state isn't
  /// shared across isolates, and `package:sqflite` itself isn't generally
  /// safe to use from background isolates, so don't rely on cross-isolate
  /// sharing here.
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
          onUpgrade: _onUpgrade,
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
    // recorded_at is a sortable composite, `(epochMs << 16) + seqWithinMs`,
    // produced by SqfliteRecentFrequenciesStore — NOT raw epoch ms. We
    // order DESC and cap by deleting entries whose freq isn't in the top-N
    // by recorded_at; the intra-ms sequence is what keeps two records
    // submitted in the same millisecond ordered by submission.
    await db.execute('''
      CREATE TABLE recent_frequencies (
        freq TEXT PRIMARY KEY NOT NULL,
        recorded_at INTEGER NOT NULL,
        nickname TEXT,
        pinned INTEGER NOT NULL DEFAULT 0,
        session_uuid TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_recent_freq_time ON recent_frequencies (recorded_at)',
    );
    await _createBlockedPeersTable(db);
  }

  /// Schema migrations run when an existing install opens a newer
  /// `_dbVersion`. Each step is idempotent (CREATE TABLE IF NOT EXISTS,
  /// add-column-if-missing) so re-running a step on a partially-migrated
  /// install doesn't fail.
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createBlockedPeersTable(db);
    }
    if (oldVersion < 3) {
      await _addRecentFrequenciesNicknameAndPinned(db);
    }
    if (oldVersion < 4) {
      await _addRecentFrequenciesSessionUuid(db);
    }
  }

  /// Adds the v4 `session_uuid` (TEXT, NULL until the row is re-recorded
  /// post-upgrade) column to `recent_frequencies`. Same `PRAGMA table_info`
  /// guard pattern as [_addRecentFrequenciesNicknameAndPinned] so re-running
  /// on a partially-migrated install is a no-op rather than a duplicate-
  /// column error. Rows that pre-date this migration carry `NULL`; the
  /// cubit's Resume path treats `NULL` as "fall back to minting a fresh
  /// UUID" so users on legacy rows keep getting today's behaviour until
  /// they re-host.
  static Future<void> _addRecentFrequenciesSessionUuid(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(recent_frequencies)');
    final existing = cols.map((r) => r['name'] as String?).toSet();
    if (!existing.contains('session_uuid')) {
      await db.execute(
        'ALTER TABLE recent_frequencies ADD COLUMN session_uuid TEXT',
      );
    }
  }

  /// Adds the v3 `nickname` (TEXT, NULL for "no nickname set") and `pinned`
  /// (INTEGER, 0/1 boolean — sqlite has no native bool) columns to
  /// `recent_frequencies`. sqlite has no `ALTER TABLE … ADD COLUMN IF NOT
  /// EXISTS`, so each ALTER is gated by a `PRAGMA table_info` check that
  /// skips the statement when the column is already present — the migration
  /// stays a no-op on installs that have already been upgraded (manual
  /// migration scripts, partial upgrades) instead of throwing
  /// `duplicate column` and stranding the user.
  static Future<void> _addRecentFrequenciesNicknameAndPinned(
    Database db,
  ) async {
    final cols = await db.rawQuery('PRAGMA table_info(recent_frequencies)');
    final existing = cols.map((r) => r['name'] as String?).toSet();
    if (!existing.contains('nickname')) {
      await db.execute(
        'ALTER TABLE recent_frequencies ADD COLUMN nickname TEXT',
      );
    }
    if (!existing.contains('pinned')) {
      await db.execute(
        'ALTER TABLE recent_frequencies ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  /// Persists the per-user "I've muted this peer" set keyed by stable
  /// peerId. `blocked_at` is a DESC-sortable epoch millis kept for
  /// diagnostic ordering only — the API surface returns an unordered
  /// set, so an index on it would be wasted writes.
  static Future<void> _createBlockedPeersTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS blocked_peers (
        peer_id TEXT PRIMARY KEY NOT NULL,
        blocked_at INTEGER NOT NULL
      )
    ''');
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

  /// Test seam: drop the FFI factory + path overrides so a later test
  /// that doesn't install one falls back to the platform default. Without
  /// this, the override leaks process-wide and a later test relying on
  /// the real factory either picks up the previous test's path or fails
  /// because the FFI factory isn't available on its platform.
  @visibleForTesting
  static void clearDatabaseFactoryOverride() {
    _factoryOverride = null;
    _pathOverride = null;
  }
}
