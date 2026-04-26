import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../protocol/discovery.dart';

/// DiscoveryService scans for nearby Frequency hosts using Bluetooth LE.
class DiscoveryService {
  final StreamController<List<DiscoveredSession>> _resultsController =
      StreamController<List<DiscoveredSession>>.broadcast();

  Stream<List<DiscoveredSession>> get results => _resultsController.stream;

  final Map<String, DiscoveredSession> _discovered = {};
  Timer? _cleanupTimer;
  StreamSubscription? _scanSubscription;

  /// Starts scanning for Frequency advertisements.
  Future<void> startScan() async {
    // 1. Check if Bluetooth is available and on.
    if (await FlutterBluePlus.isSupported == false) {
      throw Exception('Bluetooth LE is not supported on this device');
    }

    _discovered.clear();
    _emit();

    // 2. Listen for scan results.
    await _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        final session = _parseResult(r);
        if (session != null) {
          _discovered[session.sessionUuidLow8] = session;
          _emit();
        }
      }
    });

    // 3. Start scanning.
    // We filter by the service UUID defined in the protocol.
    await FlutterBluePlus.startScan(
      withServices: [Guid(kWalkieTalkieServiceUuid)],
      // We remove the timeout to let the user control pausing/scanning
      // and prevent silent timeout failures (Thread 5, 11).
    );

    // 4. Periodically clean up old results.
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // In a real app, we might check timestamps. For now, we'll keep it simple.
    });
  }

  /// Stops the active scan.
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
  }

  void _emit() {
    _resultsController.add(_discovered.values.toList());
  }

  DiscoveredSession? _parseResult(ScanResult r) {
    // Manufacturer data is a Map<int, List<int>>.
    for (final entry in r.advertisementData.manufacturerData.entries) {
      final data = Uint8List.fromList(entry.value);
      final session = DiscoveredSession.fromManufacturerData(
        data,
        hostName: r.advertisementData.advName,
        rssi: r.rssi,
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
