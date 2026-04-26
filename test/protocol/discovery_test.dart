import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/discovery.dart';

void main() {
  group('DiscoveredSession parsing', () {
    test('parses a valid v1 host advertisement', () {
      final data = Uint8List.fromList([
        0x01, // Version 1
        0x01, // Role: Host
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, // sessionUuidLow8
        0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x00, // reserved
      ]);
      
      final session = DiscoveredSession.fromManufacturerData(
        data,
        hostName: "Maya's Pixel",
        rssi: -45,
      );

      expect(session, isNotNull);
      expect(session!.protocolVersion, 1);
      expect(session.isHost, true);
      expect(session.sessionUuidLow8, '0011223344556677');
      expect(session.hostName, "Maya's Pixel");
      expect(session.rssi, -45);
    });

    test('rejects advertisement with wrong version', () {
      final data = Uint8List.fromList([
        0x02, // Version 2 (unsupported)
        0x01, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ]);
      final session = DiscoveredSession.fromManufacturerData(data, hostName: 'X', rssi: 0);
      expect(session, isNull);
    });

    test('rejects truncated advertisement', () {
      final data = Uint8List.fromList([0x01, 0x01, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x00, 0x00, 0x00]);
      final session = DiscoveredSession.fromManufacturerData(data, hostName: 'X', rssi: 0);
      expect(session, isNull);
    });

    test('derives mhzDisplay from sessionUuidLow8 correctly', () {
      // tenths = 880 + (low_12_bits % 200)
      // mhz    = tenths / 10.0
      
      // Case 1: low 12 bits are 0. 
      // bytes ending in ... 0x00, 0x00
      final s1 = DiscoveredSession(
        protocolVersion: 1,
        isHost: true,
        sessionUuidLow8: '0000000000000000',
        flags: 0,
        hostName: 'H1',
        rssi: -50,
      );
      // low12 = 0, tenths = 880 + 0 = 880, mhz = 88.0
      expect(s1.mhzDisplay, '88.0');

      // Case 2: low 12 bits are 1043. 
      // 104.3 MHz means tenths = 1043.
      // 1043 = 880 + 163.
      // So we need low12 % 200 = 163.
      // Let's use low12 = 163 (0x00A3).
      final s2 = DiscoveredSession(
        protocolVersion: 1,
        isHost: true,
        sessionUuidLow8: '00000000000000A3',
        flags: 0,
        hostName: 'H2',
        rssi: -50,
      );
      // low12 = 163, tenths = 880 + (163 % 200) = 880 + 163 = 1043, mhz = 104.3
      expect(s2.mhzDisplay, '104.3');

      // Case 3: low 12 bits overflow 200.
      // let low12 = 250 (0x00FA).
      final s3 = DiscoveredSession(
        protocolVersion: 1,
        isHost: true,
        sessionUuidLow8: '00000000000000FA',
        flags: 0,
        hostName: 'H3',
        rssi: -50,
      );
      // low12 = 250, tenths = 880 + (250 % 200) = 880 + 50 = 930, mhz = 93.0
      expect(s3.mhzDisplay, '93.0');
    });
  });
}
