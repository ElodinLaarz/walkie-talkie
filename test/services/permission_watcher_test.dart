import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/services/permission_watcher.dart';

/// MethodChannel handler for `permission_handler`. The plugin uses
/// `flutter.baseflow.com/permissions/methods` for queries; we reduce it to
/// the two calls our watcher makes — `checkPermissionStatus` (used by
/// `Permission.X.status`) and `requestPermissions` (unused here, but stubbed
/// to avoid `MissingPluginException` if a future contributor adds a request
/// path inside the watcher and forgets to mock it).
///
/// `permission_handler`'s [PermissionStatus] is encoded as an int across the
/// MethodChannel in the order the enum is declared. The IDs we care about
/// here:
///   * `denied` = 0
///   * `granted` = 1
///   * `permanentlyDenied` = 4
///
/// These haven't moved across major versions (and the package is pinned in
/// pubspec). If the plugin ever reorders them, the watcher tests will start
/// failing fast — far better than the alternative (silent regression).
class _FakePermissions {
  /// Status to return per [Permission] integer code (see
  /// `permission_handler_platform_interface`'s `Permission.byValue`):
  ///   * 7  = microphone
  ///   * 28 = bluetoothScan
  ///   * 29 = bluetoothAdvertise
  ///   * 30 = bluetoothConnect
  final Map<int, int> statusByPermission;

  /// MethodChannel call counter so tests can assert "watcher polled twice".
  int checkCalls = 0;

  _FakePermissions(this.statusByPermission);

  Future<dynamic> handle(MethodCall call) async {
    switch (call.method) {
      case 'checkPermissionStatus':
        checkCalls++;
        final code = call.arguments as int;
        return statusByPermission[code] ?? 0;
      case 'requestPermissions':
        // Not exercised by the watcher today; return granted for safety.
        final List<int> codes = (call.arguments as List).cast<int>();
        return {for (final c in codes) c: 1};
      default:
        return null;
    }
  }
}

const _kMicrophone = 7;
const _kBluetoothScan = 28;
const _kBluetoothAdvertise = 29;
const _kBluetoothConnect = 30;

const _kDenied = 0;
const _kGranted = 1;

void _setHandler(_FakePermissions perms) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('flutter.baseflow.com/permissions/methods'),
    perms.handle,
  );
}

void _clearHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('flutter.baseflow.com/permissions/methods'),
    null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DefaultPermissionWatcher', () {
    tearDown(_clearHandler);

    test('emits empty list when all permissions granted', () async {
      final perms = _FakePermissions({
        _kMicrophone: _kGranted,
        _kBluetoothScan: _kGranted,
        _kBluetoothConnect: _kGranted,
        _kBluetoothAdvertise: _kGranted,
      });
      _setHandler(perms);

      final watcher = DefaultPermissionWatcher();
      addTearDown(watcher.dispose);

      final firstEvent = await watcher.watch().first;
      expect(firstEvent, isEmpty);
    });

    test('emits microphone when microphone is denied', () async {
      _setHandler(_FakePermissions({
        _kMicrophone: _kDenied,
        _kBluetoothScan: _kGranted,
        _kBluetoothConnect: _kGranted,
        _kBluetoothAdvertise: _kGranted,
      }));

      final watcher = DefaultPermissionWatcher();
      addTearDown(watcher.dispose);

      final event = await watcher.watch().first;
      expect(event, [AppPermission.microphone]);
    });

    test('emits bluetooth when any of the three BT perms is denied',
        () async {
      _setHandler(_FakePermissions({
        _kMicrophone: _kGranted,
        _kBluetoothScan: _kGranted,
        _kBluetoothConnect: _kDenied, // only one denied
        _kBluetoothAdvertise: _kGranted,
      }));

      final watcher = DefaultPermissionWatcher();
      addTearDown(watcher.dispose);

      final event = await watcher.watch().first;
      expect(event, [AppPermission.bluetooth]);
    });

    test('emits both in order when both are denied', () async {
      _setHandler(_FakePermissions({
        _kMicrophone: _kDenied,
        _kBluetoothScan: _kDenied,
        _kBluetoothConnect: _kDenied,
        _kBluetoothAdvertise: _kDenied,
      }));

      final watcher = DefaultPermissionWatcher();
      addTearDown(watcher.dispose);

      final event = await watcher.watch().first;
      expect(event, [AppPermission.microphone, AppPermission.bluetooth]);
    });

    test('checkNow reflects an updated platform answer', () async {
      final perms = _FakePermissions({
        _kMicrophone: _kGranted,
        _kBluetoothScan: _kGranted,
        _kBluetoothConnect: _kGranted,
        _kBluetoothAdvertise: _kGranted,
      });
      _setHandler(perms);

      final watcher = DefaultPermissionWatcher();
      addTearDown(watcher.dispose);

      // Initial: all granted. Take the first stream event as an explicit
      // signal that the kickoff sample completed; raw microtask flushes
      // were flaky on slower CI workers (the platform-channel mock takes
      // a few microtasks per call to round-trip).
      final events = <List<AppPermission>>[];
      final sub = watcher.watch().listen(events.add);
      await watcher.watch().first;
      expect(events, [const <AppPermission>[]]);

      // Flip the mic to denied and trigger an immediate re-check.
      perms.statusByPermission[_kMicrophone] = _kDenied;
      final missing = await watcher.checkNow();
      expect(missing, [AppPermission.microphone]);
      // The new sample should also have been pushed through the stream.
      // Broadcast-stream listeners fire on a later microtask than the
      // [_controller.add] call inside `_sampleAndEmit`; yield once so the
      // second emit lands in `events` before we read its last element.
      await Future<void>.delayed(Duration.zero);
      expect(events.last, [AppPermission.microphone]);

      await sub.cancel();
    });

    test('does not re-emit when the missing set is unchanged', () async {
      final perms = _FakePermissions({
        _kMicrophone: _kDenied,
        _kBluetoothScan: _kGranted,
        _kBluetoothConnect: _kGranted,
        _kBluetoothAdvertise: _kGranted,
      });
      _setHandler(perms);

      final watcher = DefaultPermissionWatcher();
      addTearDown(watcher.dispose);

      final events = <List<AppPermission>>[];
      final sub = watcher.watch().listen(events.add);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        [AppPermission.microphone],
      ]);

      // Same answer — should not fire a duplicate event.
      await watcher.checkNow();
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        [AppPermission.microphone],
      ]);

      await sub.cancel();
    });

    test('lifecycle resume triggers an immediate re-check', () async {
      final perms = _FakePermissions({
        _kMicrophone: _kGranted,
        _kBluetoothScan: _kGranted,
        _kBluetoothConnect: _kGranted,
        _kBluetoothAdvertise: _kGranted,
      });
      _setHandler(perms);

      final watcher = DefaultPermissionWatcher();
      addTearDown(watcher.dispose);

      final events = <List<AppPermission>>[];
      final sub = watcher.watch().listen(events.add);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final initialCalls = perms.checkCalls;
      expect(initialCalls, greaterThan(0));

      // Flip a permission and synthesize a resume — the watcher must
      // re-sample on resume rather than waiting for the 5 s tick.
      perms.statusByPermission[_kMicrophone] = _kDenied;
      watcher.didChangeAppLifecycleState(AppLifecycleState.resumed);

      // Allow the awaited platform calls to land.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(perms.checkCalls, greaterThan(initialCalls));
      expect(events.last, [AppPermission.microphone]);

      await sub.cancel();
    });

    test(
      'a slow background sample does not overwrite a newer checkNow result',
      () async {
        // Reproduces the race CodeRabbit flagged on PR #85: a background
        // tick that started first finishes last. Without generation tagging
        // its stale read would overwrite the newer Retry sample, yanking
        // the UI back to the prior state and bouncing the user.
        final perms = _FakePermissions({
          _kMicrophone: _kDenied,
          _kBluetoothScan: _kGranted,
          _kBluetoothConnect: _kGranted,
          _kBluetoothAdvertise: _kGranted,
        });

        // Only the very first platform call blocks; everything after it
        // returns immediately. That wedges the kickoff (background) sample
        // partway through its reads while the subsequent checkNow sample
        // can run to completion against the freshly-granted map.
        final firstCallGate = Completer<void>();
        var consumedGate = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/permissions/methods'),
          (MethodCall call) async {
            if (call.method != 'checkPermissionStatus') return null;
            final code = call.arguments as int;
            if (!consumedGate) {
              consumedGate = true;
              await firstCallGate.future;
            }
            return perms.statusByPermission[code] ?? 0;
          },
        );

        final watcher = DefaultPermissionWatcher();
        addTearDown(watcher.dispose);

        final events = <List<AppPermission>>[];
        final sub = watcher.watch().listen(events.add);
        // Flush microtasks so the kickoff sample queues its first read
        // and gets wedged on the gate.
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(events, isEmpty);

        // Flip the answer to all-granted and run checkNow. Sample 2 goes
        // through the unblocked handler and returns [].
        perms.statusByPermission[_kMicrophone] = _kGranted;
        final fresh = await watcher.checkNow();
        expect(fresh, isEmpty);
        await Future<void>.delayed(Duration.zero);
        expect(events.last, isEmpty);

        // Flip the answer back to denied right before releasing sample 1
        // so its delayed read sees the stale value when it resumes —
        // models "permissions changed underneath a slow read."
        perms.statusByPermission[_kMicrophone] = _kDenied;
        firstCallGate.complete();
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        // Sample 1 (gen=1) is older than sample 2 (gen=2). Its emit must
        // be suppressed even though it observed a [microphone]-denied
        // reading — the newer sample's empty reading stands.
        expect(events.last, isEmpty);

        await sub.cancel();
      },
    );

    test('watch() throws after dispose', () async {
      _setHandler(_FakePermissions({
        _kMicrophone: _kGranted,
        _kBluetoothScan: _kGranted,
        _kBluetoothConnect: _kGranted,
        _kBluetoothAdvertise: _kGranted,
      }));

      final watcher = DefaultPermissionWatcher();
      await watcher.dispose();
      expect(
        () => watcher.watch(),
        throwsA(isA<StateError>()),
      );
    });

    test('checkNow throws after dispose', () async {
      _setHandler(_FakePermissions({
        _kMicrophone: _kGranted,
        _kBluetoothScan: _kGranted,
        _kBluetoothConnect: _kGranted,
        _kBluetoothAdvertise: _kGranted,
      }));

      final watcher = DefaultPermissionWatcher();
      await watcher.dispose();
      expect(
        () => watcher.checkNow(),
        throwsA(isA<StateError>()),
      );
    });

    test('dispose is idempotent', () async {
      _setHandler(_FakePermissions({
        _kMicrophone: _kGranted,
        _kBluetoothScan: _kGranted,
        _kBluetoothConnect: _kGranted,
        _kBluetoothAdvertise: _kGranted,
      }));

      final watcher = DefaultPermissionWatcher();
      await watcher.dispose();
      await watcher.dispose(); // must not throw
    });

    test('platform error during check does not crash the stream', () async {
      // Handler that throws — simulate a malformed platform response.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (MethodCall call) async {
          throw PlatformException(code: 'boom');
        },
      );

      final watcher = DefaultPermissionWatcher();
      addTearDown(watcher.dispose);

      // Even though the platform throws, watch() should not error out;
      // the watcher logs and stays subscribed.
      final stream = watcher.watch();
      bool sawError = false;
      final sub = stream.listen((_) {}, onError: (_) {
        sawError = true;
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(sawError, isFalse);
      await sub.cancel();
    });
  });
}
