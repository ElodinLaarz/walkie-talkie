import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:walkie_talkie/services/blocked_peers_store.dart';
import 'package:walkie_talkie/services/walkie_talkie_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    WalkieTalkieDatabase.overrideDatabaseFactoryForTesting(
      databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    await WalkieTalkieDatabase.resetForTesting();
  });

  tearDown(() async {
    await WalkieTalkieDatabase.resetForTesting();
  });

  group('SqfliteBlockedPeersStore', () {
    test('returns an empty set before any block', () async {
      final store = SqfliteBlockedPeersStore();
      expect(await store.getAll(), isEmpty);
    });

    test('block + getAll round-trips a single entry', () async {
      final store = SqfliteBlockedPeersStore();
      await store.block('peer-A');
      expect(await store.getAll(), {'peer-A'});
    });

    test('block tracks multiple distinct peers', () async {
      final store = SqfliteBlockedPeersStore();
      await store.block('peer-A');
      await store.block('peer-B');
      await store.block('peer-C');
      expect(await store.getAll(), {'peer-A', 'peer-B', 'peer-C'});
    });

    test('blocking the same peer twice is idempotent', () async {
      // The PRIMARY KEY on peer_id + ConflictAlgorithm.replace means a
      // duplicate block bumps the timestamp without inserting a second row.
      // The user-visible `getAll` should still report exactly one entry.
      final store = SqfliteBlockedPeersStore();
      await store.block('peer-A');
      await store.block('peer-A');
      expect(await store.getAll(), {'peer-A'});
    });

    test('unblock removes a previously-blocked peer', () async {
      final store = SqfliteBlockedPeersStore();
      await store.block('peer-A');
      await store.block('peer-B');
      await store.unblock('peer-A');
      expect(await store.getAll(), {'peer-B'});
    });

    test('unblocking a peer that was never blocked is a no-op', () async {
      final store = SqfliteBlockedPeersStore();
      await store.block('peer-A');
      await store.unblock('peer-Z'); // not in the table
      expect(await store.getAll(), {'peer-A'});
    });

    test('block trims whitespace', () async {
      final store = SqfliteBlockedPeersStore();
      await store.block('  peer-A  ');
      expect(await store.getAll(), {'peer-A'});
    });

    test('block with empty / whitespace-only is a no-op', () async {
      final store = SqfliteBlockedPeersStore();
      await store.block('peer-A');
      await store.block('');
      await store.block('   ');
      expect(await store.getAll(), {'peer-A'});
    });

    test('unblock with empty / whitespace-only is a no-op', () async {
      // Symmetric with `block`: a malformed unblock can't accidentally
      // wipe a peer whose id happens to start with whitespace and got
      // through some upstream bug.
      final store = SqfliteBlockedPeersStore();
      await store.block('peer-A');
      await store.unblock('');
      await store.unblock('   ');
      expect(await store.getAll(), {'peer-A'});
    });

    test('persists across new SqfliteBlockedPeersStore instances', () async {
      // Acceptance criterion from #125: "Block a peer in one session;
      // restart app; rejoin same room → peer is still blocked." Two
      // independent store instances against the same DB connection
      // simulate the cross-launch hop.
      final first = SqfliteBlockedPeersStore();
      await first.block('peer-A');
      await first.block('peer-B');

      final second = SqfliteBlockedPeersStore();
      expect(await second.getAll(), {'peer-A', 'peer-B'});
    });

    test('clear empties the set', () async {
      final store = SqfliteBlockedPeersStore();
      await store.block('peer-A');
      await store.block('peer-B');
      await store.clear();
      expect(await store.getAll(), isEmpty);
    });

    test('concurrent block calls do not lose entries', () async {
      // Without serialization in the store, two concurrent block calls
      // can both observe the same pre-write state and last-write-wins
      // one of them out of the table. Fire several in parallel — every
      // peerId should survive.
      final store = SqfliteBlockedPeersStore();
      await Future.wait([
        store.block('peer-A'),
        store.block('peer-B'),
        store.block('peer-C'),
        store.block('peer-D'),
      ]);
      expect(await store.getAll(), {'peer-A', 'peer-B', 'peer-C', 'peer-D'});
    });

    test('getAll trims whitespace already stored by any pre-trim path', () async {
      // Symmetry guarantee: block() normalizes before writing, so rows
      // stored via a pre-normalization path (direct DB write or an old
      // schema migration) are still returned trimmed by getAll().
      final store = SqfliteBlockedPeersStore();
      final db = await WalkieTalkieDatabase.open();
      await db.insert('blocked_peers', {
        'peer_id': '  peer-legacy  ',
        'blocked_at': 0,
      });
      expect(await store.getAll(), {'peer-legacy'});
    });

    test('getAll result is membership-compatible with untrimmed caller input', () async {
      // A caller that holds the raw peerId '  peer-A  ' (untrimmed) can
      // check membership by trimming before the contains() call — the
      // getAll() set contains only trimmed keys.
      final store = SqfliteBlockedPeersStore();
      await store.block('  peer-A  ');
      final blocked = await store.getAll();
      expect(blocked.contains('peer-A'), isTrue);
      expect(blocked.contains('  peer-A  '), isFalse);
    });

    test('concurrent block / unblock of the same peer leaves a deterministic '
        'final state (last write wins on the chain)', () async {
      // The store serializes writes per-instance via _writeChain, so
      // back-to-back calls land in submission order. The final state
      // must reflect the last call (an unblock) regardless of how the
      // sqflite event loop schedules them.
      final store = SqfliteBlockedPeersStore();
      final futures = <Future<void>>[];
      futures.add(store.block('peer-A'));
      futures.add(store.unblock('peer-A'));
      futures.add(store.block('peer-A'));
      futures.add(store.unblock('peer-A'));
      await Future.wait(futures);
      expect(await store.getAll(), isEmpty);
    });
  });
}
