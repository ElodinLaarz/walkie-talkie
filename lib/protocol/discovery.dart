import 'dart:typed_data';

/// The 128-bit service UUID used by Frequency for discovery and control.
const String kWalkieTalkieServiceUuid = '8e5e8e8e-8e8e-4e8e-8e8e-8e8e8e8e8e8e';

/// Metadata for a discovered Frequency session.
class DiscoveredSession {
  final int protocolVersion;
  final bool isHost;
  final String sessionUuidLow8;
  final int flags;
  final String hostName;
  final int rssi;
  final String mhzDisplay;

  DiscoveredSession({
    required this.protocolVersion,
    required this.isHost,
    required this.sessionUuidLow8,
    required this.flags,
    required this.hostName,
    required this.rssi,
  }) : mhzDisplay = _deriveMhz(sessionUuidLow8);

  /// Derives the cosmetic MHz display string from the session UUID.
  /// 
  /// tenths = 880 + (low_12_bits % 200)
  /// mhz    = tenths / 10.0
  static String _deriveMhz(String sessionUuidLow8) {
    // We only have the low 8 bytes (64 bits) of the session UUID in the 
    // advertisement. The protocol says low 12 bits of the full UUID are used.
    // The advertisement layout says offset 2 contains "low 8 bytes of sessionUuid".
    // So we can extract the low 12 bits from these 8 bytes.
    final bytes = _hexToBytes(sessionUuidLow8);
    if (bytes.length < 2) return '88.0';
    
    // Big-endian: low 12 bits of the full UUID. 
    // If we have the "low 8 bytes" [B8, B9, B10, B11, B12, B13, B14, B15],
    // the low 12 bits of the UUID are the low 12 bits of B15 + B14.
    final low12 = ((bytes[bytes.length - 2] & 0x0F) << 8) | bytes[bytes.length - 1];
    final tenths = 880 + (low12 % 200);
    return (tenths / 10.0).toStringAsFixed(1);
  }

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  /// Parses manufacturer data according to the v1 protocol spec.
  /// 
  /// | offset | bytes | meaning                                  |
  /// | ------ | ----- | ---------------------------------------- |
  /// | 0      | 1     | protocol version (`0x01` for v1)         |
  /// | 1      | 1     | role (`0x01` = host)                     |
  /// | 2      | 8     | low 8 bytes of `sessionUuid`             |
  /// | 10     | 2     | flags (reserved, zero in v1)             |
  /// | 12     | 4     | reserved                                 |
  static DiscoveredSession? fromManufacturerData(
    Uint8List data, {
    required String hostName,
    required int rssi,
  }) {
    if (data.length < 16) return null;

    final version = data[0];
    if (version != 1) return null; // Only v1 supported.

    final role = data[1];
    if (role != 0x01) return null; // v1 only defines a host role; future roles
                                   // will get their own value.
    const isHost = true;

    final sessionUuidLow8 = data
        .sublist(2, 10)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    
    final flags = (data[10] << 8) | data[11];

    return DiscoveredSession(
      protocolVersion: version,
      isHost: isHost,
      sessionUuidLow8: sessionUuidLow8,
      flags: flags,
      hostName: hostName,
      rssi: rssi,
    );
  }
}
