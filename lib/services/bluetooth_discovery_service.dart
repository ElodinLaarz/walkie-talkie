import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../protocol/discovery.dart';

/// DiscoveryService scans for nearby Frequency hosts using Bluetooth LE.
class DiscoveryService {
  /// How long a host can go un-advertised before it's considered out of range
  /// and pruned from the emitted list. Hosts advertise on the order of
  /// 100-1000 ms, so 10 s tolerates a couple of dropped windows without
  /// blanking a still-present session.
  static const Duration freshnessWindow = Duration(seconds: 10);

  final StreamController<List<DiscoveredSession>> _resultsController =
      StreamController<List<DiscoveredSession>>.broadcast();

  Stream<List<DiscoveredSession>> get results => _resultsController.stream;

  final Map<String, ({DiscoveredSession session, DateTime lastSeen})>
  _discovered = {};
  StreamSubscription? _scanSubscription;

  /// Fires [_emit] on a fixed cadence so stale entries are pruned even when
  /// no BLE advertisements arrive (e.g. every host went silent simultaneously).
  Timer? _pruneTimer;

  /// Starts scanning for Frequency advertisements.
  Future<void> startScan() async {
    // 1. Check if Bluetooth is available and on.
    if (await FlutterBluePlus.isSupported == false) {
      throw Exception('Bluetooth LE is not supported on this device');
    }

    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      throw Exception('Bluetooth adapter is not on');
    }

    // Check runtime permissions.
    final scanStatus = await Permission.bluetoothScan.request();
    final connectStatus = await Permission.bluetoothConnect.request();
    if (!scanStatus.isGranted || !connectStatus.isGranted) {
      throw Exception('Bluetooth permissions denied');
    }

    _discovered.clear();
    _emit();

    // 2. Listen for scan results.
    // onScanResults is preferred over scanResults: it does not replay stale
    // results after scanning stops, avoiding a spurious re-emission on the
    // next startScan() call before the new results arrive.
    await _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
      for (ScanResult r in results) {
        final session = parseResult(r);
        if (session != null) {
          final existing = _discovered[session.sessionUuidLow8];
          final resolvedHostName =
              (session.hostName.isEmpty && existing != null)
              ? existing.session.hostName
              : session.hostName;

          final resolvedSession = resolvedHostName == session.hostName
              ? session
              : DiscoveredSession(
                  protocolVersion: session.protocolVersion,
                  isHost: session.isHost,
                  sessionUuidLow8: session.sessionUuidLow8,
                  flags: session.flags,
                  hostName: resolvedHostName,
                  rssi: session.rssi,
                  macAddress: session.macAddress,
                );

          _discovered[session.sessionUuidLow8] = (
            session: resolvedSession,
            lastSeen: DateTime.now(),
          );
        }
      }
      // Emit unconditionally so the freshness window prunes stale entries
      // even when this tick has no new sessions (e.g. every host went out
      // of range — the listener still needs to see the empty list).
      _emit();
    });
    // Auto-cancel the subscription if the OS stops the scan unexpectedly
    // (e.g. adapter turned off, or platform scan timeout).
    FlutterBluePlus.cancelWhenScanComplete(_scanSubscription!);

    // 3. Start scanning without a hardware service-UUID filter.
    //
    // Some OEM BLE stacks (notably MediaTek-based Motorola devices) advertise
    // 128-bit UUIDs in non-standard byte order or do not honour hardware UUID
    // scan filters from other vendors' chipsets. A withServices filter here
    // silently drops those advertisements before parseResult ever sees them.
    //
    // parseResult already performs software filtering — it only accepts payloads
    // whose first byte is protocol version 0x01 and second byte is role 0x01
    // (see DiscoveredSession.fromManufacturerData). Content-based filtering is
    // more reliable than UUID-based filtering because it checks the actual
    // payload regardless of how the advertising metadata is encoded by the
    // host's BLE stack.
    await FlutterBluePlus.startScan(
      // No timeout — user controls start/stop; avoids silent timeout failures.
    );

    // Start prune timer only after scan starts successfully. This prevents a
    // resource leak where a failed startScan leaves the timer firing into a
    // scan-less void.
    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(freshnessWindow ~/ 2, (_) => _emit());
  }

  /// Stops the active scan.
  Future<void> stopScan() async {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    await FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
  }

  void _emit() {
    final cutoff = DateTime.now().subtract(freshnessWindow);
    _discovered.removeWhere((_, entry) => entry.lastSeen.isBefore(cutoff));
    _resultsController.add(_discovered.values.map((e) => e.session).toList());
  }

  @visibleForTesting
  DiscoveredSession? parseResult(ScanResult r) {
    // Manufacturer data is a Map<int, List<int>>.
    for (final entry in r.advertisementData.manufacturerData.entries) {
      final data = Uint8List.fromList(entry.value);
      final session = DiscoveredSession.fromManufacturerData(
        data,
        hostName: r.advertisementData.advName,
        rssi: r.rssi,
        macAddress: r.device.remoteId.str,
      );
      if (session != null) return session;
    }
    return null;
  }

  Future<void> dispose() async {
    await stopScan();
    await _resultsController.close();
  }
}
