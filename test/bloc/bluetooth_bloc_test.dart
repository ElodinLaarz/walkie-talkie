import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mockito/mockito.dart';
import 'package:walkie_talkie/bloc/bluetooth_bloc.dart';
import 'package:walkie_talkie/bloc/bluetooth_event.dart';
import 'package:walkie_talkie/bloc/bluetooth_state.dart';
import 'package:walkie_talkie/models/bluetooth_device.dart';

import '../helpers/test_helpers.mocks.dart';

void main() {
  group('BluetoothBloc', () {
    late MockAudioService mockAudioService;
    late BluetoothBloc bluetoothBloc;
    late StreamController<Map<String, dynamic>> audioEventsController;
    late Directory tempDir;

    setUp(() async {
      mockAudioService = MockAudioService();
      audioEventsController =
          StreamController<Map<String, dynamic>>.broadcast();

      when(
        mockAudioService.audioEvents,
      ).thenAnswer((_) => audioEventsController.stream);

      tempDir = await Directory.systemTemp.createTemp();
      Hive.init(tempDir.path);

      bluetoothBloc = BluetoothBloc(audioService: mockAudioService);
    });

    tearDown(() async {
      await bluetoothBloc.close();
      await audioEventsController.close();
      await Hive.deleteFromDisk();
    });

    test('initial state is BluetoothInitialState', () {
      expect(bluetoothBloc.state, const BluetoothInitialState());
    });

    blocTest<BluetoothBloc, BluetoothState>(
      'emits [BluetoothScanningState] when StartScanEvent is added and scan succeeds',
      build: () {
        when(mockAudioService.startScan()).thenAnswer((_) async => true);
        return bluetoothBloc;
      },
      act: (bloc) => bloc.add(const StartScanEvent()),
      expect: () => [const BluetoothScanningState([])],
      verify: (_) {
        verify(mockAudioService.startScan()).called(1);
      },
    );

    blocTest<BluetoothBloc, BluetoothState>(
      'emits [BluetoothScanningState, BluetoothErrorState] when StartScanEvent is added and scan fails',
      build: () {
        when(mockAudioService.startScan()).thenAnswer((_) async => false);
        return bluetoothBloc;
      },
      act: (bloc) => bloc.add(const StartScanEvent()),
      expect: () => [
        const BluetoothScanningState([]),
        const BluetoothErrorState('Failed to start Bluetooth scan'),
      ],
    );

    blocTest<BluetoothBloc, BluetoothState>(
      'emits [BluetoothScanningState] with device when DeviceDiscoveredEvent is added',
      build: () => bluetoothBloc,
      seed: () => const BluetoothScanningState([]),
      act: (bloc) {
        final device = BluetoothDevice(
          macAddress: '00:00:00:00:00:00',
          displayName: 'Device 1',
          isConnected: false,
        );
        bloc.add(DeviceDiscoveredEvent(device));
      },
      expect: () => [
        BluetoothScanningState([
          BluetoothDevice(
            macAddress: '00:00:00:00:00:00',
            displayName: 'Device 1',
            isConnected: false,
          ),
        ]),
      ],
    );

    blocTest<BluetoothBloc, BluetoothState>(
      'emits [BluetoothLoadingState, BluetoothConnectedState] when ConnectDeviceEvent is added and connection succeeds',
      build: () {
        when(mockAudioService.connectDevice(any)).thenAnswer((_) async => true);
        when(mockAudioService.getConnectedDevices()).thenAnswer(
          (_) async => [
            {'address': '00:00:00:00:00:00', 'name': 'Device 1'},
          ],
        );
        return bluetoothBloc;
      },
      act: (bloc) => bloc.add(const ConnectDeviceEvent('00:00:00:00:00:00')),
      expect: () => [
        const BluetoothLoadingState(),
        BluetoothConnectedState([
          BluetoothDevice(
            macAddress: '00:00:00:00:00:00',
            displayName: 'Device 1',
            isConnected: true,
          ),
        ]),
      ],
    );

    blocTest<BluetoothBloc, BluetoothState>(
      'emits [BluetoothLoadingState, BluetoothErrorState] when ConnectDeviceEvent is added and connection fails',
      build: () {
        when(
          mockAudioService.connectDevice(any),
        ).thenAnswer((_) async => false);
        return bluetoothBloc;
      },
      act: (bloc) => bloc.add(const ConnectDeviceEvent('00:00:00:00:00:00')),
      expect: () => [
        const BluetoothLoadingState(),
        const BluetoothErrorState('Failed to connect to device'),
      ],
    );

    blocTest<BluetoothBloc, BluetoothState>(
      'emits [BluetoothInitialState] when DisconnectDeviceEvent is added and it was the last device',
      build: () {
        when(mockAudioService.disconnectDevice(any)).thenAnswer((_) async => true);
        when(mockAudioService.getConnectedDevices()).thenAnswer((_) async => []);
        return bluetoothBloc;
      },
      seed: () => BluetoothConnectedState([
        BluetoothDevice(macAddress: '00:00:00', displayName: 'Device 1', isConnected: true),
      ]),
      act: (bloc) => bloc.add(const DisconnectDeviceEvent('00:00:00')),
      expect: () => [
        const BluetoothInitialState(),
      ],
    );

    blocTest<BluetoothBloc, BluetoothState>(
      'emits updated BluetoothConnectedState when RenameDeviceEvent is added',
      build: () => bluetoothBloc,
      seed: () => BluetoothConnectedState([
        BluetoothDevice(macAddress: '00:00:00', displayName: 'Old Name', isConnected: true),
      ]),
      act: (bloc) => bloc.add(const RenameDeviceEvent('00:00:00', 'New Name')),
      expect: () => [
        BluetoothConnectedState([
          BluetoothDevice(macAddress: '00:00:00', displayName: 'New Name', isConnected: true),
        ]),
      ],
    );

    blocTest<BluetoothBloc, BluetoothState>(
      'emits BluetoothErrorState when BluetoothErrorEvent is added',
      build: () => bluetoothBloc,
      act: (bloc) => bloc.add(const BluetoothErrorEvent('Something went wrong')),
      expect: () => [
        const BluetoothErrorState('Something went wrong'),
      ],
    );

    blocTest<BluetoothBloc, BluetoothState>(
      'does not add duplicate devices in BluetoothScanningState',
      build: () => bluetoothBloc,
      seed: () => BluetoothScanningState([
        BluetoothDevice(macAddress: '00:00:00', displayName: 'Device 1'),
      ]),
      act: (bloc) => bloc.add(DeviceDiscoveredEvent(
        BluetoothDevice(macAddress: '00:00:00', displayName: 'Device 1'),
      )),
      expect: () => [],
    );
  });
}
