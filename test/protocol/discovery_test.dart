import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/discovery.dart';
import 'package:walkie_talkie/protocol/frequency_session.dart';

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
        macAddress: 'AA:BB:CC:DD:EE:FF',
      );

      expect(session, isNotNull);
      expect(session!.protocolVersion, 1);
      expect(session.isHost, true);
      expect(session.sessionUuidLow8, '0011223344556677');
      expect(session.hostName, "Maya's Pixel");
      expect(session.rssi, -45);
      expect(session.macAddress, 'AA:BB:CC:DD:EE:FF');
    });

    test('round-trips the macAddress through fromManufacturerData', () {
      // The MAC isn't encoded in the advertisement payload — it comes from
      // the BLE scan record on the device side. fromManufacturerData has
      // to thread it through to DiscoveredSession unchanged so the guest's
      // GATT-connect call can dial the right host.
      final data = Uint8List.fromList([
        0x01,
        0x01,
        0xDE,
        0xAD,
        0xBE,
        0xEF,
        0xCA,
        0xFE,
        0xBA,
        0xBE,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      const mac = '11:22:33:44:55:66';

      final session = DiscoveredSession.fromManufacturerData(
        data,
        hostName: 'Devon',
        rssi: -60,
        macAddress: mac,
      );

      expect(session, isNotNull);
      expect(session!.macAddress, mac);
    });

    test('rejects advertisement with wrong version', () {
      final data = Uint8List.fromList([
        0x02, // Version 2 (unsupported)
        0x01,
        0x00,
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      final session = DiscoveredSession.fromManufacturerData(
        data,
        hostName: 'X',
        rssi: 0,
        macAddress: 'AA:BB:CC:DD:EE:FF',
      );
      expect(session, isNull);
    });

    test('rejects non-host role byte', () {
      final data = Uint8List.fromList([
        0x01, // Version 1
        0x02, // Role: unknown (not host)
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, // sessionUuidLow8
        0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x00, // reserved
      ]);
      final session = DiscoveredSession.fromManufacturerData(
        data,
        hostName: 'X',
        rssi: 0,
        macAddress: 'AA:BB:CC:DD:EE:FF',
      );
      expect(session, isNull);
    });

    test('parses non-zero flags and preserves byte order', () {
      // Low byte set: flags = 0x0001
      final dataLowByte = Uint8List.fromList([
        0x01, // version
        0x01, // role: host
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, // sessionUuidLow8
        0x00, 0x01, // flags: big-endian 0x0001
        0x00, 0x00, 0x00, 0x00, // reserved
      ]);
      final s1 = DiscoveredSession.fromManufacturerData(
        dataLowByte,
        hostName: 'X',
        rssi: 0,
        macAddress: 'AA:BB:CC:DD:EE:FF',
      );
      expect(s1, isNotNull);
      expect(s1!.flags, 0x0001);

      // High byte set: flags = 0x0100
      final dataHighByte = Uint8List.fromList([
        0x01, // version
        0x01, // role: host
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, // sessionUuidLow8
        0x01, 0x00, // flags: big-endian 0x0100
        0x00, 0x00, 0x00, 0x00, // reserved
      ]);
      final s2 = DiscoveredSession.fromManufacturerData(
        dataHighByte,
        hostName: 'X',
        rssi: 0,
        macAddress: 'AA:BB:CC:DD:EE:FF',
      );
      expect(s2, isNotNull);
      expect(s2!.flags, 0x0100);
    });

    test('rejects truncated advertisement', () {
      final data = Uint8List.fromList([
        0x01,
        0x01,
        0x00,
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x00,
        0x00,
        0x00,
      ]);
      final session = DiscoveredSession.fromManufacturerData(
        data,
        hostName: 'X',
        rssi: 0,
        macAddress: 'AA:BB:CC:DD:EE:FF',
      );
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
        macAddress: 'AA:BB:CC:DD:EE:FF',
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
        macAddress: 'AA:BB:CC:DD:EE:FF',
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
        macAddress: 'AA:BB:CC:DD:EE:FF',
      );
      // low12 = 250, tenths = 880 + (250 % 200) = 880 + 50 = 930, mhz = 93.0
      expect(s3.mhzDisplay, '93.0');
    });

    test(
      'mhzDisplay falls back to 88.0 on a sessionUuidLow8 with non-hex chars',
      () {
        // Hits the int.tryParse-null branch in _hexToBytes; the parse fails,
        // _hexToBytes returns an empty Uint8List, and _deriveMhz returns the
        // 88.0 default when bytes.length < 2.
        final s = DiscoveredSession(
          protocolVersion: 1,
          isHost: true,
          sessionUuidLow8: 'ZZZZ00FF00FF00FF',
          flags: 0,
          hostName: 'badHex',
          rssi: -60,
          macAddress: 'AA:BB:CC:DD:EE:FF',
        );
        expect(s.mhzDisplay, '88.0');
      },
    );

    test('mhzDisplay falls back to 88.0 on an odd-length sessionUuidLow8', () {
      // hex.length.isOdd → _hexToBytes returns an empty Uint8List.
      final s = DiscoveredSession(
        protocolVersion: 1,
        isHost: true,
        sessionUuidLow8: 'ABC',
        flags: 0,
        hostName: 'oddLen',
        rssi: -55,
        macAddress: 'AA:BB:CC:DD:EE:FF',
      );
      expect(s.mhzDisplay, '88.0');
    });

    test('guest-decode and host-self-view derive the same mhzDisplay for equal '
        'low-12 bits', () {
      // Both sites now route through FrequencySession.mhzDisplayFromLow12.
      // This pins that they agree byte-for-byte: a DiscoveredSession built
      // from advertisement bytes encoding `low12` must show the same
      // frequency as a FrequencySession whose UUID has those same low 12
      // bits. Includes a value above the 200-bucket count to cover the
      // modulo wrap.
      for (final low12 in [0, 163, 250, 511, 4095]) {
        final hi = (low12 >> 8) & 0x0F; // only the low 12 bits matter
        final lo = low12 & 0xFF;
        final low8Hex =
            '000000000000'
            '${hi.toRadixString(16).padLeft(2, '0')}'
            '${lo.toRadixString(16).padLeft(2, '0')}';
        final guest = DiscoveredSession(
          protocolVersion: 1,
          isHost: true,
          sessionUuidLow8: low8Hex,
          flags: 0,
          hostName: 'H',
          rssi: -50,
          macAddress: 'AA:BB:CC:DD:EE:FF',
        );
        // A full UUID whose last 3 nibbles are the same low 12 bits.
        final host = FrequencySession(
          sessionUuid:
              '00000000-0000-0000-0000-000000000'
              '${low12.toRadixString(16).padLeft(3, '0')}',
          hostPeerId: 'h',
        );
        expect(
          guest.mhzDisplay,
          host.mhzDisplay,
          reason: 'derivations diverged for low12=$low12',
        );
      }
    });
  });
}
