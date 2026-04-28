import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:walkie_talkie/bloc/discovery_cubit.dart';
import 'package:walkie_talkie/bloc/discovery_state.dart';
import 'package:walkie_talkie/protocol/discovery.dart';
import 'package:walkie_talkie/services/bluetooth_discovery_service.dart';

import 'discovery_cubit_test.mocks.dart';

@GenerateMocks([DiscoveryService])
void main() {
  late MockDiscoveryService mockService;
  late DiscoveryCubit cubit;
  late StreamController<List<DiscoveredSession>> resultsController;

  setUp(() {
    mockService = MockDiscoveryService();
    resultsController = StreamController<List<DiscoveredSession>>.broadcast();
    when(mockService.results).thenAnswer((_) => resultsController.stream);
    when(mockService.startScan()).thenAnswer((_) async {});
    when(mockService.stopScan()).thenAnswer((_) async {});
    cubit = DiscoveryCubit(mockService);
  });

  tearDown(() async {
    await cubit.close();
    await resultsController.close();
  });

  test('initial state is DiscoveryInitial', () {
    expect(cubit.state, DiscoveryInitial());
  });

  test('startDiscovery starts scan and listens for results', () async {
    await cubit.startDiscovery();
    verify(mockService.startScan()).called(1);
    expect(cubit.state, const DiscoveryScanning());

    final sessions = [
      DiscoveredSession(
        protocolVersion: 1,
        isHost: true,
        sessionUuidLow8: '1234567890123456',
        flags: 0,
        hostName: 'Host',
        rssi: -50,
        macAddress: 'AA:BB:CC:DD:EE:FF',
      ),
    ];

    resultsController.add(sessions);
    await Future.delayed(Duration.zero);
    
    expect(cubit.state, DiscoveryScanning(sessions: sessions));
  });

  test('startDiscovery handles startScan failure with explicit failure state', () async {
    when(mockService.startScan()).thenThrow(Exception('permission denied'));
    await cubit.startDiscovery();
    expect(cubit.state, const DiscoveryStopped());
  });

  test('stopDiscovery clears sessions when paused', () async {
    await cubit.startDiscovery();
    final sessions = [
      DiscoveredSession(
        protocolVersion: 1,
        isHost: true,
        sessionUuidLow8: '1234567890123456',
        flags: 0,
        hostName: 'Host',
        rssi: -50,
        macAddress: 'AA:BB:CC:DD:EE:FF',
      ),
    ];
    resultsController.add(sessions);
    await Future.delayed(Duration.zero);
    
    await cubit.stopDiscovery();
    expect(cubit.state, const DiscoveryStopped()); // empty sessions expected
  });
}
