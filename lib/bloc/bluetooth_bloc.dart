import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'dart:async';
import 'bluetooth_event.dart';
import 'bluetooth_state.dart';
import '../models/bluetooth_device.dart';
import '../services/audio_service.dart';

/// BLoC for managing Bluetooth LE Audio connections and state
class BluetoothBloc extends Bloc<BluetoothEvent, BluetoothState> {
  final AudioService audioService;
  Box<String>? deviceNamesBox;
  StreamSubscription? _eventSubscription;

  BluetoothBloc({required this.audioService})
    : super(const BluetoothInitialState()) {
    on<StartScanEvent>(_onStartScan);
    on<StopScanEvent>(_onStopScan);
    on<ConnectDeviceEvent>(_onConnectDevice);
    on<DisconnectDeviceEvent>(_onDisconnectDevice);
    on<RenameDeviceEvent>(_onRenameDevice);
    on<DeviceDiscoveredEvent>(_onDeviceDiscovered);
    on<AudioLevelChangedEvent>(_onAudioLevelChanged);
    on<BluetoothErrorEvent>(_onError);

    _initHive();
    _listenToAudioEvents();
  }

  Future<void> _initHive() async {
    try {
      deviceNamesBox = await Hive.openBox<String>('device_names');
    } catch (e) {
      debugPrint('Error initializing Hive: $e');
    }
  }

  void _listenToAudioEvents() {
    _eventSubscription = audioService.audioEvents.listen((event) {
      final type = event['type'] as String?;

      switch (type) {
        case 'deviceDiscovered':
          final address = event['address'] as String;
          final name = event['name'] as String;
          add(
            DeviceDiscoveredEvent(
              BluetoothDevice(
                macAddress: address,
                displayName: name,
                isConnected: false,
              ),
            ),
          );
          break;

        case 'deviceConnected':
          final address = event['address'] as String;
          // Update device to connected state
          if (state is BluetoothScanningState) {
            final devices = (state as BluetoothScanningState).discoveredDevices;
            final device = devices.firstWhere(
              (d) => d.macAddress == address,
              orElse: () =>
                  BluetoothDevice(macAddress: address, displayName: 'Unknown'),
            );
            add(ConnectDeviceEvent(device.macAddress));
          }
          break;

        case 'deviceDisconnected':
          final address = event['address'] as String;
          add(DisconnectDeviceEvent(address));
          break;

        case 'error':
          final message = event['message'] as String;
          add(BluetoothErrorEvent(message));
          break;
      }
    });
  }

  Future<void> _onError(
    BluetoothErrorEvent event,
    Emitter<BluetoothState> emit,
  ) async {
    emit(BluetoothErrorState(event.message));
  }

  Future<void> _onStartScan(
    StartScanEvent event,
    Emitter<BluetoothState> emit,
  ) async {
    emit(const BluetoothScanningState([]));
    try {
      final success = await audioService.startScan();
      if (!success) {
        emit(const BluetoothErrorState('Failed to start Bluetooth scan'));
      }
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
      // Just stop the scan, don't change state
      // This prevents issues when navigating away
    } catch (e) {
      // Don't emit error on stop scan failure
      debugPrint('Failed to stop scan: $e');
    }
  }

  Future<void> _onConnectDevice(
    ConnectDeviceEvent event,
    Emitter<BluetoothState> emit,
  ) async {
    debugPrint('Connecting to device: ${event.macAddress}');
    emit(const BluetoothLoadingState());
    try {
      final success = await audioService.connectDevice(event.macAddress);
      debugPrint('Connection result: $success');

      if (success) {
        // Get current connected devices
        final connectedDevices = await _getConnectedDevices();
        debugPrint('Connected devices count: ${connectedDevices.length}');

        // If we have connected devices, show them
        if (connectedDevices.isNotEmpty) {
          emit(BluetoothConnectedState(connectedDevices));
        } else {
          debugPrint('No devices returned, creating manual device');
          // If connection succeeded but no devices returned, create one manually
          final savedName = deviceNamesBox?.get(event.macAddress);
          final device = BluetoothDevice(
            macAddress: event.macAddress,
            displayName: savedName ?? 'Connected Device',
            isConnected: true,
            isActive: false,
            audioLevel: 0.0,
          );
          emit(BluetoothConnectedState([device]));
        }
      } else {
        emit(const BluetoothErrorState('Failed to connect to device'));
      }
    } catch (e) {
      debugPrint('Connection error: $e');
      emit(BluetoothErrorState('Failed to connect: $e'));
    }
  }

  Future<void> _onDisconnectDevice(
    DisconnectDeviceEvent event,
    Emitter<BluetoothState> emit,
  ) async {
    try {
      final success = await audioService.disconnectDevice(event.macAddress);

      if (success) {
        // Get updated connected devices
        final connectedDevices = await _getConnectedDevices();
        if (connectedDevices.isEmpty) {
          emit(const BluetoothInitialState());
        } else {
          emit(BluetoothConnectedState(connectedDevices));
        }
      }
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
      if (deviceNamesBox != null) {
        await deviceNamesBox!.put(event.macAddress, event.newName);
      }

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
    try {
      if (state is BluetoothScanningState) {
        final currentDevices =
            (state as BluetoothScanningState).discoveredDevices;

        // Check if device already exists
        final exists = currentDevices.any(
          (d) => d.macAddress == event.device.macAddress,
        );
        if (!exists) {
          // Get saved name from Hive if available
          String? savedName;
          if (deviceNamesBox != null) {
            savedName = deviceNamesBox!.get(event.device.macAddress);
          }

          final device = savedName != null
              ? event.device.copyWith(displayName: savedName)
              : event.device;

          emit(BluetoothScanningState([...currentDevices, device]));
        }
      }
    } catch (e) {
      debugPrint('Error processing discovered device: $e');
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
    try {
      final devices = await audioService.getConnectedDevices();
      return devices.map((deviceMap) {
        final address = deviceMap['address'] ?? 'Unknown';
        final name = deviceMap['name'] ?? 'Unknown Device';

        String? savedName;
        if (deviceNamesBox != null) {
          savedName = deviceNamesBox!.get(address);
        }

        return BluetoothDevice(
          macAddress: address,
          displayName: savedName ?? name,
          isConnected: true,
          isActive: false,
          audioLevel: 0.0,
        );
      }).toList();
    } catch (e) {
      debugPrint('Error getting connected devices: $e');
      return [];
    }
  }

  @override
  Future<void> close() {
    _eventSubscription?.cancel();
    // Check if box is open before closing
    if (deviceNamesBox != null && deviceNamesBox!.isOpen) {
      deviceNamesBox!.close();
    }
    return super.close();
  }
}
