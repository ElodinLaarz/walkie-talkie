import 'package:equatable/equatable.dart';
import '../models/bluetooth_device.dart';

/// Base class for all Bluetooth states
abstract class BluetoothState extends Equatable {
  const BluetoothState();

  @override
  List<Object?> get props => [];
}

/// Initial state
class BluetoothInitialState extends BluetoothState {
  const BluetoothInitialState();
}

/// Scanning for devices
class BluetoothScanningState extends BluetoothState {
  final List<BluetoothDevice> discoveredDevices;

  const BluetoothScanningState(this.discoveredDevices);

  @override
  List<Object?> get props => [discoveredDevices];
}

/// Connected to devices
class BluetoothConnectedState extends BluetoothState {
  final List<BluetoothDevice> connectedDevices;

  const BluetoothConnectedState(this.connectedDevices);

  @override
  List<Object?> get props => [connectedDevices];
}

/// Error state
class BluetoothErrorState extends BluetoothState {
  final String message;

  const BluetoothErrorState(this.message);

  @override
  List<Object?> get props => [message];
}

/// Loading state
class BluetoothLoadingState extends BluetoothState {
  const BluetoothLoadingState();
}
