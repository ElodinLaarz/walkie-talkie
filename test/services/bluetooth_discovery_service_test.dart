import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:walkie_talkie/services/bluetooth_discovery_service.dart';

import 'bluetooth_discovery_service_test.mocks.dart';

/// Tests for BluetoothDiscoveryService.parseResult, covering:
/// - Manufacturer data filtering (valid v1 payloads accepted, invalid rejected)
/// - RSSI propagation from scan results to DiscoveredSession
/// - Advertisement name (advName) passthrough to DiscoveredSession.hostName
/// - MAC address propagation from device.remoteId to DiscoveredSession.macAddress
/// - Multiple manufacturer data entries (iteration until valid found)
@GenerateMocks([
  BluetoothDevice,
  AdvertisementData,
])
void main() {
  // Ensure Flutter bindings are initialized for any widget-dependent code
  WidgetsFlutterBinding.ensureInitialized();

  group('BluetoothDiscoveryService parseResult', () {
    late DiscoveryService service;

    setUp(() {
      service = DiscoveryService();
    });

    tearDown(() async {
      await service.dispose();
    });

    /// Helper to create a ScanResult with controlled manufacturer data and RSSI.
    ScanResult makeScanResult({
      required Map<int, List<int>> manufacturerData,
      required String advName,
      required int rssi,
      String macAddress = 'AA:BB:CC:DD:EE:FF',
    }) {
      final device = MockBluetoothDevice();
      final advData = MockAdvertisementData();

      when(device.remoteId).thenReturn(DeviceIdentifier(macAddress));
      when(advData.manufacturerData).thenReturn(manufacturerData);
      when(advData.advName).thenReturn(advName);

      return ScanResult(
        device: device,
        advertisementData: advData,
        rssi: rssi,
        timeStamp: DateTime.now(),
      );
    }

    /// Valid v1 host advertisement payload.
    /// Protocol: [version(1)][role(1)][sessionUuidLow8(8)][flags(2)][reserved(4)]
    Uint8List validV1Payload({String sessionUuidLow8 = '0011223344556677'}) {
      final uuidBytes = <int>[];
      for (var i = 0; i < sessionUuidLow8.length; i += 2) {
        uuidBytes.add(int.parse(sessionUuidLow8.substring(i, i + 2), radix: 16));
      }

      return Uint8List.fromList([
        0x01, // Version 1
        0x01, // Role: Host
        ...uuidBytes, // sessionUuidLow8 (8 bytes)
        0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x00, // reserved
      ]);
    }

    test('parseResult extracts valid manufacturer data and propagates all fields',
        () {
      final scanResult = makeScanResult(
        manufacturerData: {0x05A0: validV1Payload().toList()},
        advName: 'TestHost',
        rssi: -72,
        macAddress: '11:22:33:44:55:66',
      );

      final session = service.parseResult(scanResult);

      expect(session, isNotNull);
      expect(session!.hostName, 'TestHost');
      expect(session.rssi, -72);
      expect(session.macAddress, '11:22:33:44:55:66');
      expect(session.protocolVersion, 1);
      expect(session.isHost, true);
      expect(session.sessionUuidLow8, '0011223344556677');
    });

    test('parseResult returns null for invalid protocol version', () {
      // Version 2 is unsupported
      final invalidPayload = Uint8List.fromList([
        0x02, // Version 2 (unsupported)
        0x01, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ]);

      final scanResult = makeScanResult(
        manufacturerData: {0x05A0: invalidPayload.toList()},
        advName: 'InvalidHost',
        rssi: -50,
      );

      final session = service.parseResult(scanResult);
      expect(session, isNull);
    });

    test('parseResult returns null for truncated payload', () {
      // Missing required fields
      final truncatedPayload = Uint8List.fromList([
        0x01, 0x01, 0x00, 0x11, 0x22, // Only 5 bytes instead of 16
      ]);

      final scanResult = makeScanResult(
        manufacturerData: {0x05A0: truncatedPayload.toList()},
        advName: 'BadHost',
        rssi: -45,
      );

      final session = service.parseResult(scanResult);
      expect(session, isNull);
    });

    test('parseResult handles multiple manufacturer data entries', () {
      // First entry is junk, second is valid
      final validPayload = validV1Payload();
      final junkPayload = Uint8List.fromList([0x99, 0x99]);

      final scanResult = makeScanResult(
        manufacturerData: {
          0x0001: junkPayload.toList(), // Invalid company ID
          0x05A0: validPayload.toList(), // Valid Frequency payload
        },
        advName: 'MultiMfg',
        rssi: -65,
      );

      final session = service.parseResult(scanResult);

      expect(session, isNotNull);
      expect(session!.hostName, 'MultiMfg');
      expect(session.rssi, -65);
    });

    test('parseResult returns null when manufacturer data is empty', () {
      final scanResult = makeScanResult(
        manufacturerData: {}, // No manufacturer data
        advName: 'EmptyMfg',
        rssi: -40,
      );

      final session = service.parseResult(scanResult);
      expect(session, isNull);
    });

    test('parseResult propagates advName to DiscoveredSession.hostName', () {
      final scanResult = makeScanResult(
        manufacturerData: {0x05A0: validV1Payload().toList()},
        advName: 'Pixel 7 Pro',
        rssi: -55,
      );

      final session = service.parseResult(scanResult);

      expect(session, isNotNull);
      expect(session!.hostName, 'Pixel 7 Pro');
    });

    test('parseResult propagates macAddress from device.remoteId', () {
      const testMac = 'DE:AD:BE:EF:CA:FE';
      final scanResult = makeScanResult(
        manufacturerData: {0x05A0: validV1Payload().toList()},
        advName: 'TestDevice',
        rssi: -60,
        macAddress: testMac,
      );

      final session = service.parseResult(scanResult);

      expect(session, isNotNull);
      expect(session!.macAddress, testMac);
    });

    test('RSSI propagates correctly across negative range', () {
      // Test boundary values: very weak and very strong signals
      final weakSignal = makeScanResult(
        manufacturerData: {0x05A0: validV1Payload().toList()},
        advName: 'WeakHost',
        rssi: -95, // Very weak
      );

      final strongSignal = makeScanResult(
        manufacturerData: {0x05A0: validV1Payload().toList()},
        advName: 'StrongHost',
        rssi: -30, // Very strong
      );

      final weakSession = service.parseResult(weakSignal);
      final strongSession = service.parseResult(strongSignal);

      expect(weakSession, isNotNull);
      expect(weakSession!.rssi, -95);

      expect(strongSession, isNotNull);
      expect(strongSession!.rssi, -30);
    });

    test('parseResult extracts different session UUIDs correctly', () {
      final uuid1 = 'AABBCCDD11223344';
      final uuid2 = 'FFEEDDCC99887766';

      final result1 = makeScanResult(
        manufacturerData: {0x05A0: validV1Payload(sessionUuidLow8: uuid1).toList()},
        advName: 'Host1',
        rssi: -50,
      );

      final result2 = makeScanResult(
        manufacturerData: {0x05A0: validV1Payload(sessionUuidLow8: uuid2).toList()},
        advName: 'Host2',
        rssi: -60,
      );

      final session1 = service.parseResult(result1);
      final session2 = service.parseResult(result2);

      expect(session1, isNotNull);
      expect(session1!.sessionUuidLow8, uuid1.toLowerCase());

      expect(session2, isNotNull);
      expect(session2!.sessionUuidLow8, uuid2.toLowerCase());
    });

    test('parseResult returns first valid session from multiple mfg entries', () {
      // Both entries are valid with different UUIDs
      final uuid1 = '1111111111111111';
      final uuid2 = '2222222222222222';
      final payload1 = validV1Payload(sessionUuidLow8: uuid1);
      final payload2 = validV1Payload(sessionUuidLow8: uuid2);

      final scanResult = makeScanResult(
        manufacturerData: {
          0x05A0: payload1.toList(), // First valid
          0x05A1: payload2.toList(), // Second valid (different company ID)
        },
        advName: 'MultiValid',
        rssi: -70,
      );

      final session = service.parseResult(scanResult);

      // Should return the first valid session found during iteration
      expect(session, isNotNull);
      // The session UUID should be from one of the payloads
      expect(
        [uuid1.toLowerCase(), uuid2.toLowerCase()].contains(session!.sessionUuidLow8),
        true,
      );
    });
  });

  group('BluetoothDiscoveryService freshness window', () {
    test('freshnessWindow constant is 10 seconds', () {
      expect(DiscoveryService.freshnessWindow, const Duration(seconds: 10));
    });

    // Full integration test of freshness pruning would require:
    // 1. Mock DateTime or use a time-controllable service
    // 2. Emit a session
    // 3. Advance time by >10 seconds
    // 4. Emit a new scan (triggers _emit and pruning)
    // 5. Verify the old session is removed
    //
    // This is better suited for an integration test with clock injection,
    // which is beyond the scope of unit testing parseResult logic.
    // The pruning logic itself is simple (_emit removes entries older than
    // freshnessWindow) and is covered by code inspection.
  });
}
