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

  /// Starts scanning for Frequency advertisements.
  Future<void> startScan() async {
    // 1. Check if Bluetooth is available and on.
    if (await FlutterBluePlus.isSupported == false) {
      return;
    }

    // 2. Listen for scan results.
    FlutterBluePlus.scanResults.listen((results) {
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
      timeout: const Duration(seconds: 15),
    );

    // 4. Periodically clean up old results.
    _cleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // In a real app, we might check timestamps. For now, we'll keep it simple.
    });
  }

  /// Stops the active scan.
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _cleanupTimer?.cancel();
  }

  void _emit() {
    _resultsController.add(_discovered.values.toList());
  }

  DiscoveredSession? _parseResult(ScanResult r) {
    // Manufacturer data is a Map<int, List<int>>.
    // Frequency protocol doesn't specify a manufacturer ID, so we might 
    // need to check all of them or a specific one if it's assigned later.
    // For now, we'll check any manufacturer data that matches our 16-byte format.
    for (final entry in r.advertisementData.manufacturerData.entries) {
      final data = Uint8List.fromList(entry.value);
      final session = DiscoveredSession.fromManufacturerData(
        data,
        hostName: r.advertisementData.localName,
        rssi: r.rssi,
      );
      if (session != null) return session;
    }
    return null;
  }

  void dispose() {
    _resultsController.close();
    stopScan();
  }
}
