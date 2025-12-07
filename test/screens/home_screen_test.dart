import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:walkie_talkie/bloc/bluetooth_bloc.dart';
import 'package:walkie_talkie/bloc/bluetooth_event.dart';
import 'package:walkie_talkie/bloc/bluetooth_state.dart';
import 'package:walkie_talkie/models/bluetooth_device.dart';
import 'package:walkie_talkie/screens/home_screen.dart';
import 'package:walkie_talkie/services/audio_service.dart';

class MockBluetoothBloc extends MockBloc<BluetoothEvent, BluetoothState>
    implements BluetoothBloc {}

class MockAudioService extends Mock implements AudioService {}

void main() {
  group('HomeScreen', () {
    late MockBluetoothBloc mockBluetoothBloc;
    late MockAudioService mockAudioService;

    setUp(() {
      mockBluetoothBloc = MockBluetoothBloc();
      mockAudioService = MockAudioService();
      when(() => mockBluetoothBloc.audioService).thenReturn(mockAudioService);
      when(() => mockAudioService.startService()).thenAnswer((_) async => true);
    });

    testWidgets('renders empty view when state is BluetoothInitialState', (
      tester,
    ) async {
      when(
        () => mockBluetoothBloc.state,
      ).thenReturn(const BluetoothInitialState());

      await tester.pumpWidget(
        BlocProvider<BluetoothBloc>.value(
          value: mockBluetoothBloc,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );

      expect(find.text('No devices connected'), findsOneWidget);
      expect(find.text('Tap the button below to add devices'), findsOneWidget);
    });

    testWidgets(
      'renders connected view when state is BluetoothConnectedState',
      (tester) async {
        final device = BluetoothDevice(
          macAddress: '00:00:00:00:00:00',
          displayName: 'Device 1',
          isConnected: true,
        );

        when(
          () => mockBluetoothBloc.state,
        ).thenReturn(BluetoothConnectedState([device]));

        await tester.pumpWidget(
          BlocProvider<BluetoothBloc>.value(
            value: mockBluetoothBloc,
            child: const MaterialApp(home: HomeScreen()),
          ),
        );

        expect(find.text('Command Center'), findsOneWidget);
        expect(find.text('Device 1'), findsOneWidget);
      },
    );

    testWidgets('navigates to DiscoveryScreen when FAB is pressed', (
      tester,
    ) async {
      when(
        () => mockBluetoothBloc.state,
      ).thenReturn(const BluetoothInitialState());

      await tester.pumpWidget(
        BlocProvider<BluetoothBloc>.value(
          value: mockBluetoothBloc,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Discover Devices'), findsOneWidget);
    }, skip: true);
  });
}
