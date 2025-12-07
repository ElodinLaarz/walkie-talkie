import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:walkie_talkie/bloc/bluetooth_bloc.dart';
import 'package:walkie_talkie/bloc/bluetooth_event.dart';
import 'package:walkie_talkie/bloc/bluetooth_state.dart';
import 'package:walkie_talkie/models/bluetooth_device.dart';
import 'package:walkie_talkie/screens/discovery_screen.dart';

class MockBluetoothBloc extends MockBloc<BluetoothEvent, BluetoothState>
    implements BluetoothBloc {}

void main() {
  group('DiscoveryScreen', () {
    late MockBluetoothBloc mockBluetoothBloc;

    setUp(() {
      mockBluetoothBloc = MockBluetoothBloc();
    });

    testWidgets('renders scanning view when state is BluetoothScanningState', (
      tester,
    ) async {
      when(
        () => mockBluetoothBloc.state,
      ).thenReturn(const BluetoothScanningState([]));

      await tester.pumpWidget(
        BlocProvider<BluetoothBloc>.value(
          value: mockBluetoothBloc,
          child: const MaterialApp(home: DiscoveryScreen()),
        ),
      );

      expect(find.text('Scanning for devices...'), findsOneWidget);
      expect(find.text('No devices found yet'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    }, skip: true);

    testWidgets('renders device list when devices are discovered', (
      tester,
    ) async {
      final device = BluetoothDevice(
        macAddress: '00:00:00:00:00:00',
        displayName: 'Device 1',
        isConnected: false,
      );

      when(
        () => mockBluetoothBloc.state,
      ).thenReturn(BluetoothScanningState([device]));

      await tester.pumpWidget(
        BlocProvider<BluetoothBloc>.value(
          value: mockBluetoothBloc,
          child: const MaterialApp(home: DiscoveryScreen()),
        ),
      );

      expect(find.text('Device 1'), findsOneWidget);
      expect(find.text('00:00:00:00:00:00'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    }, skip: true);

    testWidgets('adds ConnectDeviceEvent when connect button is pressed', (
      tester,
    ) async {
      final device = BluetoothDevice(
        macAddress: '00:00:00:00:00:00',
        displayName: 'Device 1',
        isConnected: false,
      );

      when(
        () => mockBluetoothBloc.state,
      ).thenReturn(BluetoothScanningState([device]));

      await tester.pumpWidget(
        BlocProvider<BluetoothBloc>.value(
          value: mockBluetoothBloc,
          child: MaterialApp(home: Scaffold(body: Container())),
        ),
      );

      final context = tester.element(find.byType(Container));
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BlocProvider<BluetoothBloc>.value(
            value: mockBluetoothBloc,
            child: const DiscoveryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      verify(
        () => mockBluetoothBloc.add(
          const ConnectDeviceEvent('00:00:00:00:00:00'),
        ),
      ).called(1);
    }, skip: true);
  });
}
