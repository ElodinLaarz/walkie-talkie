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

  /// Starts scanning for Frequency advertisements.
  Future<void> startScan() async {
    // 1. Check if Bluetooth is available and on.
    if (await FlutterBluePlus.isSupported == false) {
      throw Exception('Bluetooth LE is not supported on this device');
    }

    if (await FlutterBluePlus.adapterState.first == BluetoothAdapterState.off) {
      throw Exception('Bluetooth adapter is off');
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
    await _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        final session = parseResult(r);
        if (session != null) {
          _discovered[session.sessionUuidLow8] =
              (session: session, lastSeen: DateTime.now());
        }
      }
      // Emit unconditionally so the freshness window prunes stale entries
      // even when this tick has no new sessions (e.g. every host went out
      // of range — the listener still needs to see the empty list).
      _emit();
    });

    // 3. Start scanning.
    // We filter by the service UUID defined in the protocol.
    await FlutterBluePlus.startScan(
      withServices: [Guid(kWalkieTalkieServiceUuid)],
      // We remove the timeout to let the user control pausing/scanning
      // and prevent silent timeout failures (Thread 5, 11).
    );
  }

  /// Stops the active scan.
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
  }

  void _emit() {
    final cutoff = DateTime.now().subtract(freshnessWindow);
    _discovered.removeWhere((_, entry) => entry.lastSeen.isBefore(cutoff));
    _resultsController.add(
      _discovered.values.map((e) => e.session).toList(),
    );
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
