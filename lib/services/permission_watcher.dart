import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Coarse-grained permission categories the app tracks at runtime.
///
/// Android's three Bluetooth runtime permissions ([ph.Permission.bluetoothScan],
/// [ph.Permission.bluetoothConnect], [ph.Permission.bluetoothAdvertise]) are
/// surfaced together in the system's user-facing toggle, so we collapse them
/// into a single [bluetooth] entry. The user sees one switch in Settings; the
/// UI should mirror that.
enum AppPermission { microphone, bluetooth }

/// Watches the runtime permissions the app needs to keep a room alive
/// ([AppPermission.microphone] for the mic, [AppPermission.bluetooth] for
/// the BLE control + L2CAP voice planes).
///
/// Emits a [List] of currently-missing permissions on the [watch] stream.
/// The list is ordered (microphone before bluetooth) and de-duplicated, so
/// listeners can compare with `==` (via [ListEquality]-style semantics) to
/// detect a real change. The first event after subscription is the current
/// snapshot — listeners don't need to seed state separately.
///
/// The default implementation re-checks on app resume (via
/// [WidgetsBindingObserver]) and on a 5-second timer while the app is
/// foregrounded. The timer keeps the watcher honest even if the user toggles
/// the permission via the notification shade rather than the system Settings
/// screen (which wouldn't always trigger an `AppLifecycleState.resumed`).
abstract class PermissionWatcher {
  /// Stream of currently-missing permissions. The first event is the initial
  /// snapshot at subscription time; subsequent events fire only when the set
  /// changes. Empty list means all permissions are granted.
  Stream<List<AppPermission>> watch();

  /// Re-check permissions immediately. Returns the current missing list and
  /// also pushes it through [watch] if it differs from the last sample.
  /// Useful after the user returns from app settings — call this from a
  /// "Retry" button so the UI can react without waiting on the 5 s tick.
  Future<List<AppPermission>> checkNow();

  /// Releases timers, observers, and the underlying broadcast controller.
  /// Safe to call more than once.
  Future<void> dispose();
}

/// Production implementation backed by the `permission_handler` package and
/// the Flutter [WidgetsBinding] lifecycle.
class DefaultPermissionWatcher
    with WidgetsBindingObserver
    implements PermissionWatcher {
  /// Foreground re-check cadence. Five seconds matches the issue's spec
  /// (issue #57): short enough that toggling a permission feels responsive,
  /// long enough that the OS doesn't notice the polling.
  static const Duration pollInterval = Duration(seconds: 5);

  final StreamController<List<AppPermission>> _controller =
      StreamController<List<AppPermission>>.broadcast();
  Timer? _timer;
  bool _observerAdded = false;
  bool _disposed = false;

  /// Last emitted set, used to suppress duplicate events. Stored as an
  /// unmodifiable list so subscribers can hold the reference safely.
  List<AppPermission> _last = const [];
  bool _hasEmitted = false;

  /// Re-entrancy guard for *background* ticks (poll timer + lifecycle
  /// resume). The poll timer and lifecycle hook can both fire while a
  /// previous check is still awaiting platform calls; we drop overlapping
  /// ticks rather than queueing them so a slow platform call doesn't fan
  /// out into concurrent queries. The guard does **not** apply to
  /// [checkNow] — that's a user-driven path (the Retry button) which must
  /// always reflect a fresh sample, even if a background tick is in flight.
  bool _backgroundCheckInFlight = false;

  @override
  Stream<List<AppPermission>> watch() {
    if (_disposed) {
      throw StateError('PermissionWatcher was disposed');
    }
    if (!_observerAdded) {
      _observerAdded = true;
      WidgetsBinding.instance.addObserver(this);
      _timer ??= Timer.periodic(pollInterval, (_) => _backgroundCheck());
      // Kick off the first check so subscribers get an initial snapshot
      // shortly after subscribing rather than waiting up to pollInterval.
      // Fire-and-forget — emission lands on the broadcast stream.
      _backgroundCheck();
    }
    return _controller.stream;
  }

  @override
  Future<List<AppPermission>> checkNow() async {
    if (_disposed) {
      throw StateError('PermissionWatcher was disposed');
    }
    return _sampleAndEmit();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      _backgroundCheck();
    }
  }

  /// Background-tick entry point: drops the call if a previous background
  /// check is still awaiting platform answers. Lifecycle / poll timer use
  /// this; user-driven [checkNow] does not.
  void _backgroundCheck() {
    if (_disposed) return;
    if (_backgroundCheckInFlight) return;
    _backgroundCheckInFlight = true;
    unawaited(_sampleAndEmit().whenComplete(() {
      _backgroundCheckInFlight = false;
    }));
  }

  /// Read the current platform-side permission state, de-dup against the
  /// last emission, and push a new event onto the broadcast stream when it
  /// changed. Returns the freshly-sampled missing list (or [_last] when
  /// the platform read threw — see catch block).
  Future<List<AppPermission>> _sampleAndEmit() async {
    if (_disposed) return _last;
    final missing = <AppPermission>[];
    try {
      if (!await _isMicrophoneGranted()) {
        missing.add(AppPermission.microphone);
      }
      if (!await _isBluetoothGranted()) {
        missing.add(AppPermission.bluetooth);
      }
    } catch (error, stackTrace) {
      // permission_handler throws MissingPluginException on platforms
      // without a native bridge (web, desktop). Treat as "no answer" —
      // don't emit a spurious denial, and don't crash the watcher.
      debugPrint('PermissionWatcher check failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return _last;
    }
    final snapshot = List<AppPermission>.unmodifiable(missing);
    if (!_hasEmitted || !_listEqual(_last, snapshot)) {
      _hasEmitted = true;
      _last = snapshot;
      if (!_controller.isClosed) {
        _controller.add(snapshot);
      }
    }
    return snapshot;
  }

  /// Hook for tests; production calls [ph.Permission.microphone.isGranted].
  @visibleForTesting
  Future<bool> isMicrophoneGranted() => _isMicrophoneGranted();

  /// Hook for tests; production aggregates the three BT runtime permissions.
  @visibleForTesting
  Future<bool> isBluetoothGranted() => _isBluetoothGranted();

  Future<bool> _isMicrophoneGranted() async {
    final status = await ph.Permission.microphone.status;
    return status.isGranted || status.isLimited;
  }

  Future<bool> _isBluetoothGranted() async {
    // The three runtime perms must all be granted for BLE host + L2CAP voice
    // to work; missing any of them collapses to a single "bluetooth denied"
    // event for the UI.
    final results = await Future.wait(<Future<ph.PermissionStatus>>[
      ph.Permission.bluetoothScan.status,
      ph.Permission.bluetoothConnect.status,
      ph.Permission.bluetoothAdvertise.status,
    ]);
    return results.every((s) => s.isGranted || s.isLimited);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    if (_observerAdded) {
      WidgetsBinding.instance.removeObserver(this);
      _observerAdded = false;
    }
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  static bool _listEqual(List<AppPermission> a, List<AppPermission> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
