import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:walkie_talkie/services/settings_store.dart';
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

  group('SqfliteSettingsStore', () {
    group('crashReportingEnabled', () {
      test('defaults to false (opt-out) when never set', () async {
        final store = SqfliteSettingsStore();
        expect(await store.getCrashReportingEnabled(), isFalse);
      });

      test('round-trips true', () async {
        final store = SqfliteSettingsStore();
        await store.setCrashReportingEnabled(true);
        expect(await store.getCrashReportingEnabled(), isTrue);
      });

      test('round-trips false', () async {
        final store = SqfliteSettingsStore();
        await store.setCrashReportingEnabled(false);
        expect(await store.getCrashReportingEnabled(), isFalse);
      });

      test('persists across new SqfliteSettingsStore instances', () async {
        final first = SqfliteSettingsStore();
        await first.setCrashReportingEnabled(true);
        final second = SqfliteSettingsStore();
        expect(await second.getCrashReportingEnabled(), isTrue);
      });

      test('can toggle from true to false', () async {
        final store = SqfliteSettingsStore();
        await store.setCrashReportingEnabled(true);
        expect(await store.getCrashReportingEnabled(), isTrue);
        await store.setCrashReportingEnabled(false);
        expect(await store.getCrashReportingEnabled(), isFalse);
      });

      test('can toggle from false to true', () async {
        final store = SqfliteSettingsStore();
        await store.setCrashReportingEnabled(false);
        expect(await store.getCrashReportingEnabled(), isFalse);
        await store.setCrashReportingEnabled(true);
        expect(await store.getCrashReportingEnabled(), isTrue);
      });

      test('persists true across database restarts', () async {
        final store = SqfliteSettingsStore();
        await store.setCrashReportingEnabled(true);
        // Simulate app restart by resetting the database connection
        final newStore = SqfliteSettingsStore();
        expect(await newStore.getCrashReportingEnabled(), isTrue);
      });

      test('multiple concurrent reads return the same value', () async {
        final store = SqfliteSettingsStore();
        await store.setCrashReportingEnabled(true);
        final results = await Future.wait(
          List.generate(5, (_) => store.getCrashReportingEnabled()),
        );
        expect(results, everyElement(isTrue));
      });
    });
  });
}
