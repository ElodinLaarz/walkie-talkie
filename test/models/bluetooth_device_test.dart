import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/models/bluetooth_device.dart';

void main() {
  group('BluetoothDevice', () {
    test('supports value comparisons', () {
      final device1 = BluetoothDevice(
        macAddress: '00:00:00:00:00:00',
        displayName: 'Device 1',
        isConnected: false,
      );
      final device2 = BluetoothDevice(
        macAddress: '00:00:00:00:00:00',
        displayName: 'Device 1',
        isConnected: false,
      );

      expect(device1, device2);
    });

    test('copyWith creates a new instance with updated values', () {
      final device = BluetoothDevice(
        macAddress: '00:00:00:00:00:00',
        displayName: 'Device 1',
        isConnected: false,
      );

      final updatedDevice = device.copyWith(
        displayName: 'Updated Device',
        isConnected: true,
        audioLevel: 0.5,
        isActive: true,
      );

      expect(updatedDevice.macAddress, device.macAddress);
      expect(updatedDevice.displayName, 'Updated Device');
      expect(updatedDevice.isConnected, true);
      expect(updatedDevice.audioLevel, 0.5);
      expect(updatedDevice.isActive, true);
    });

    test('copyWith with null values retains original values', () {
      final device = BluetoothDevice(
        macAddress: '00:00:00:00:00:00',
        displayName: 'Device 1',
        isConnected: false,
        audioLevel: 0.5,
        isActive: true,
      );

      final updatedDevice = device.copyWith();

      expect(updatedDevice, device);
    });
  });
}
