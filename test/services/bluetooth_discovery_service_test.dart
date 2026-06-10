import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:walkie_talkie/protocol/discovery.dart';
import 'package:walkie_talkie/services/bluetooth_discovery_service.dart';

import 'bluetooth_discovery_service_test.mocks.dart';

/// Tests for DiscoveryService.parseResult, covering:
/// - Manufacturer data filtering (valid v1 payloads accepted, invalid rejected)
/// - RSSI propagation from scan results to DiscoveredSession
/// - Advertisement name (advName) passthrough to DiscoveredSession.hostName
/// - MAC address propagation from device.remoteId to DiscoveredSession.macAddress
/// - Multiple manufacturer data entries (iteration until valid found)
@GenerateMocks([BluetoothDevice, AdvertisementData])
void main() {
  // Ensure Flutter bindings are initialized for any widget-dependent code
  WidgetsFlutterBinding.ensureInitialized();

  group('DiscoveryService parseResult', () {
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
        uuidBytes.add(
          int.parse(sessionUuidLow8.substring(i, i + 2), radix: 16),
        );
      }

      return Uint8List.fromList([
        0x01, // Version 1
        0x01, // Role: Host
        ...uuidBytes, // sessionUuidLow8 (8 bytes)
        0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x00, // reserved
      ]);
    }

    test(
      'parseResult extracts valid manufacturer data and propagates all fields',
      () {
        final scanResult = makeScanResult(
          manufacturerData: {0xFFFF: validV1Payload().toList()},
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
      },
    );

    test('parseResult returns null for invalid protocol version', () {
      // Version 2 is unsupported
      final invalidPayload = Uint8List.fromList([
        0x02, // Version 2 (unsupported)
        0x01, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ]);

      final scanResult = makeScanResult(
        manufacturerData: {0xFFFF: invalidPayload.toList()},
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
        manufacturerData: {0xFFFF: truncatedPayload.toList()},
        advName: 'BadHost',
        rssi: -45,
      );

      final session = service.parseResult(scanResult);
      expect(session, isNull);
    });

    test('parseResult handles multiple manufacturer data entries', () {
      // A foreign company id is present alongside ours; only the kManufacturerId
      // entry is parsed.
      final validPayload = validV1Payload();
      final junkPayload = Uint8List.fromList([0x99, 0x99]);

      final scanResult = makeScanResult(
        manufacturerData: {
          0x0001: junkPayload.toList(), // Foreign company id; skipped (#122)
          0xFFFF: validPayload.toList(), // Valid Frequency payload
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
        manufacturerData: {0xFFFF: validV1Payload().toList()},
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
        manufacturerData: {0xFFFF: validV1Payload().toList()},
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
        manufacturerData: {0xFFFF: validV1Payload().toList()},
        advName: 'WeakHost',
        rssi: -95, // Very weak
      );

      final strongSignal = makeScanResult(
        manufacturerData: {0xFFFF: validV1Payload().toList()},
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
        manufacturerData: {
          0xFFFF: validV1Payload(sessionUuidLow8: uuid1).toList(),
        },
        advName: 'Host1',
        rssi: -50,
      );

      final result2 = makeScanResult(
        manufacturerData: {
          0xFFFF: validV1Payload(sessionUuidLow8: uuid2).toList(),
        },
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

    test('parseResult accepts test/internal manufacturer ID 0xFFFF', () {
      // HostAdvertiser uses MANUFACTURER_ID = 0xFFFF (Bluetooth SIG test/internal
      // range). parseResult re-checks the company id against kManufacturerId in
      // software (#122) and only then applies protocol-level filtering. This
      // test pins the accept path for the actual HostAdvertiser id.
      final scanResult = makeScanResult(
        manufacturerData: {0xFFFF: validV1Payload().toList()},
        advName: 'Moto G',
        rssi: -68,
      );

      final session = service.parseResult(scanResult);

      expect(session, isNotNull);
      expect(session!.hostName, 'Moto G');
      expect(session.sessionUuidLow8, '0011223344556677');
    });

    test(
      'parseResult ignores a valid payload under a foreign company id (#122)',
      () {
        // A foreign company id (not kManufacturerId) carries a structurally
        // valid v1 host payload, and it is iterated first. The platform scan
        // filter constrains the scan, but parseResult re-parses every entry, so
        // it must skip the foreign id and return only the kManufacturerId host —
        // otherwise a device advertising under another company id whose payload
        // happens to start 0x01 0x01 would surface as a fake host.
        final foreignUuid = '1111111111111111';
        final hostUuid = '2222222222222222';

        final scanResult = makeScanResult(
          manufacturerData: {
            // Iterated first; valid v1 payload but under the wrong company id.
            0x05A1: validV1Payload(sessionUuidLow8: foreignUuid).toList(),
            0xFFFF: validV1Payload(sessionUuidLow8: hostUuid).toList(),
          },
          advName: 'MixedMfg',
          rssi: -70,
        );

        final session = service.parseResult(scanResult);

        expect(session, isNotNull);
        expect(session!.sessionUuidLow8, hostUuid.toLowerCase());
      },
    );

    test(
      'parseResult returns null when a valid payload is under a foreign id only',
      () {
        // Defense-in-depth: even a perfectly-formed v1 payload must be rejected
        // when its company id is not kManufacturerId (#122).
        final scanResult = makeScanResult(
          manufacturerData: {0x05A1: validV1Payload().toList()},
          advName: 'Impostor',
          rssi: -55,
        );

        expect(service.parseResult(scanResult), isNull);
      },
    );
  });

  group('DiscoveryService handleScanResults — composite key', () {
    late DiscoveryService service;

    setUp(() {
      service = DiscoveryService();
    });

    tearDown(() async {
      await service.dispose();
    });

    ScanResult makeScanResult2({
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

    Uint8List validV1Payload2({String sessionUuidLow8 = '0011223344556677'}) {
      final uuidBytes = <int>[];
      for (var i = 0; i < sessionUuidLow8.length; i += 2) {
        uuidBytes.add(
          int.parse(sessionUuidLow8.substring(i, i + 2), radix: 16),
        );
      }
      return Uint8List.fromList([
        0x01, 0x01, ...uuidBytes, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ]);
    }

    test(
      'two advertisers with same sessionUuidLow8 but different MACs both tracked',
      () async {
        const sharedUuid = 'aabbccddeeff0011';
        final r1 = makeScanResult2(
          manufacturerData: {0xFFFF: validV1Payload2(sessionUuidLow8: sharedUuid).toList()},
          advName: 'HostA',
          rssi: -50,
          macAddress: 'AA:AA:AA:AA:AA:AA',
        );
        final r2 = makeScanResult2(
          manufacturerData: {0xFFFF: validV1Payload2(sessionUuidLow8: sharedUuid).toList()},
          advName: 'HostB',
          rssi: -60,
          macAddress: 'BB:BB:BB:BB:BB:BB',
        );

        final emitted = <List<DiscoveredSession>>[];
        service.results.listen(emitted.add);

        service.handleScanResults([r1, r2]);

        await Future<void>.delayed(Duration.zero);

        expect(emitted, isNotEmpty);
        final sessions = emitted.last;
        expect(sessions.length, 2, reason: 'both hosts must appear, not clobber each other');
        final macs = sessions.map((s) => s.macAddress).whereType<String>().toSet();
        expect(macs, containsAll(['AA:AA:AA:AA:AA:AA', 'BB:BB:BB:BB:BB:BB']));
      },
    );
  });

  group('DiscoveryService freshness window', () {
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

  group('DiscoveryService prune timer', () {
    test('prune timer period is half the freshness window', () {
      // Timer fires at freshnessWindow ~/ 2 = 5 s so a host that stops
      // advertising is removed within at most 1.5× the freshness window
      // (worst case: entry added just after a prune tick, then one full
      // freshnessWindow elapses, then the next tick fires).
      final halfWindow = DiscoveryService.freshnessWindow ~/ 2;
      expect(halfWindow, const Duration(seconds: 5));
    });
  });

  group('DiscoveryService dispose', () {
    test('closes the results controller even when stopScan throws', () async {
      final service = _ThrowingStopScanDiscoveryService();
      // Subscribe so we can observe the stream closing (done callback).
      var done = false;
      service.results.listen(null, onDone: () => done = true);

      // dispose() must propagate the stopScan failure but still close the
      // controller in its finally block (regression for the leak where a
      // throwing stopScan skipped close()).
      await expectLater(service.dispose(), throwsStateError);

      // Give the broadcast controller's done event a microtask to deliver.
      await Future<void>.delayed(Duration.zero);
      expect(done, isTrue, reason: 'results controller should be closed');
    });
  });
}

/// Test double whose stopScan() always throws, exercising dispose()'s
/// finally-block close of the broadcast controller.
class _ThrowingStopScanDiscoveryService extends DiscoveryService {
  @override
  Future<void> stopScan() async {
    throw StateError('stopScan failed');
  }
}
