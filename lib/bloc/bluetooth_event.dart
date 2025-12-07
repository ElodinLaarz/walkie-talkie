import 'package:equatable/equatable.dart';
import '../models/bluetooth_device.dart';

/// Base class for all Bluetooth events
abstract class BluetoothEvent extends Equatable {
  const BluetoothEvent();

  @override
  List<Object?> get props => [];
}

/// Event to start scanning for devices
class StartScanEvent extends BluetoothEvent {
  const StartScanEvent();
}

/// Event to stop scanning
class StopScanEvent extends BluetoothEvent {
  const StopScanEvent();
}

/// Event to connect to a device
class ConnectDeviceEvent extends BluetoothEvent {
  final String macAddress;

  const ConnectDeviceEvent(this.macAddress);

  @override
  List<Object?> get props => [macAddress];
}

/// Event to disconnect from a device
class DisconnectDeviceEvent extends BluetoothEvent {
  final String macAddress;

  const DisconnectDeviceEvent(this.macAddress);

  @override
  List<Object?> get props => [macAddress];
}

/// Event to rename a device
class RenameDeviceEvent extends BluetoothEvent {
  final String macAddress;
  final String newName;

  const RenameDeviceEvent(this.macAddress, this.newName);

  @override
  List<Object?> get props => [macAddress, newName];
}

/// Event when a device is discovered
class DeviceDiscoveredEvent extends BluetoothEvent {
  final BluetoothDevice device;

  const DeviceDiscoveredEvent(this.device);

  @override
  List<Object?> get props => [device];
}

/// Event when audio level changes
class AudioLevelChangedEvent extends BluetoothEvent {
  final String macAddress;
  final double level;

  const AudioLevelChangedEvent(this.macAddress, this.level);

  @override
  List<Object?> get props => [macAddress, level];
}

/// Event when an error occurs
class BluetoothErrorEvent extends BluetoothEvent {
  final String message;

  const BluetoothErrorEvent(this.message);

  @override
  List<Object?> get props => [message];
}
