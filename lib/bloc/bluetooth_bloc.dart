import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';
import 'bluetooth_event.dart';
import 'bluetooth_state.dart';
import '../models/bluetooth_device.dart';
import '../services/audio_service.dart';

/// BLoC for managing Bluetooth LE Audio connections and state
class BluetoothBloc extends Bloc<BluetoothEvent, BluetoothState> {
  final AudioService audioService;
  late Box<String> deviceNamesBox;

  BluetoothBloc({required this.audioService})
    : super(const BluetoothInitialState()) {
    on<StartScanEvent>(_onStartScan);
    on<StopScanEvent>(_onStopScan);
    on<ConnectDeviceEvent>(_onConnectDevice);
    on<DisconnectDeviceEvent>(_onDisconnectDevice);
    on<RenameDeviceEvent>(_onRenameDevice);
    on<DeviceDiscoveredEvent>(_onDeviceDiscovered);
    on<AudioLevelChangedEvent>(_onAudioLevelChanged);

    _initHive();
  }

  Future<void> _initHive() async {
    deviceNamesBox = await Hive.openBox<String>('device_names');
  }

  Future<void> _onStartScan(
    StartScanEvent event,
    Emitter<BluetoothState> emit,
  ) async {
    emit(const BluetoothScanningState([]));
    try {
      await audioService.startScan();
    } catch (e) {
      emit(BluetoothErrorState('Failed to start scan: $e'));
    }
  }

  Future<void> _onStopScan(
    StopScanEvent event,
    Emitter<BluetoothState> emit,
  ) async {
    try {
      await audioService.stopScan();
      if (state is BluetoothScanningState) {
        final devices = (state as BluetoothScanningState).discoveredDevices;
        emit(BluetoothScanningState(devices));
      }
    } catch (e) {
      emit(BluetoothErrorState('Failed to stop scan: $e'));
    }
  }

  Future<void> _onConnectDevice(
    ConnectDeviceEvent event,
    Emitter<BluetoothState> emit,
  ) async {
    emit(const BluetoothLoadingState());
    try {
      await audioService.connectDevice(event.macAddress);

      // Get current connected devices
      final connectedDevices = await _getConnectedDevices();
      emit(BluetoothConnectedState(connectedDevices));
    } catch (e) {
      emit(BluetoothErrorState('Failed to connect: $e'));
    }
  }

  Future<void> _onDisconnectDevice(
    DisconnectDeviceEvent event,
    Emitter<BluetoothState> emit,
  ) async {
    try {
      await audioService.disconnectDevice(event.macAddress);

      // Get updated connected devices
      final connectedDevices = await _getConnectedDevices();
      emit(BluetoothConnectedState(connectedDevices));
    } catch (e) {
      emit(BluetoothErrorState('Failed to disconnect: $e'));
    }
  }

  Future<void> _onRenameDevice(
    RenameDeviceEvent event,
    Emitter<BluetoothState> emit,
  ) async {
    try {
      // Save the new name to Hive
      await deviceNamesBox.put(event.macAddress, event.newName);

      // Update the state with the new name
      if (state is BluetoothConnectedState) {
        final devices = (state as BluetoothConnectedState).connectedDevices;
        final updatedDevices = devices.map((device) {
          if (device.macAddress == event.macAddress) {
            return device.copyWith(displayName: event.newName);
          }
          return device;
        }).toList();
        emit(BluetoothConnectedState(updatedDevices));
      }
    } catch (e) {
      emit(BluetoothErrorState('Failed to rename device: $e'));
    }
  }

  Future<void> _onDeviceDiscovered(
    DeviceDiscoveredEvent event,
    Emitter<BluetoothState> emit,
  ) async {
    if (state is BluetoothScanningState) {
      final currentDevices =
          (state as BluetoothScanningState).discoveredDevices;

      // Check if device already exists
      final exists = currentDevices.any(
        (d) => d.macAddress == event.device.macAddress,
      );
      if (!exists) {
        // Get saved name from Hive if available
        final savedName = deviceNamesBox.get(event.device.macAddress);
        final device = savedName != null
            ? event.device.copyWith(displayName: savedName)
            : event.device;

        emit(BluetoothScanningState([...currentDevices, device]));
      }
    }
  }

  Future<void> _onAudioLevelChanged(
    AudioLevelChangedEvent event,
    Emitter<BluetoothState> emit,
  ) async {
    if (state is BluetoothConnectedState) {
      final devices = (state as BluetoothConnectedState).connectedDevices;
      final updatedDevices = devices.map((device) {
        if (device.macAddress == event.macAddress) {
          return device.copyWith(audioLevel: event.level);
        }
        return device;
      }).toList();
      emit(BluetoothConnectedState(updatedDevices));
    }
  }

  Future<List<BluetoothDevice>> _getConnectedDevices() async {
    // TODO: Get actual connected devices from the service
    // For now, return empty list
    return [];
  }

  @override
  Future<void> close() {
    deviceNamesBox.close();
    return super.close();
  }
}
