import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/services/audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioService', () {
    late AudioService audioService;
    final List<MethodCall> log = <MethodCall>[];

    setUp(() {
      audioService = AudioService();
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.elodin.walkie_talkie/audio'),
            (MethodCall methodCall) async {
              log.add(methodCall);
              switch (methodCall.method) {
                case 'startService':
                case 'stopService':
                case 'scanDevices':
                case 'connectDevice':
                case 'disconnectDevice':
                  return true;
                case 'stopScan':
                  return null;
                case 'getConnectedDevices':
                  return [
                    {'address': '00:00:00:00:00:00', 'name': 'Device 1'},
                  ];
                default:
                  return null;
              }
            },
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.elodin.walkie_talkie/audio'),
            null,
          );
    });

    test('startService calls correct method', () async {
      final result = await audioService.startService();
      expect(result, true);
      expect(log, <Matcher>[isMethodCall('startService', arguments: null)]);
    });

    test('stopService calls correct method', () async {
      final result = await audioService.stopService();
      expect(result, true);
      expect(log, <Matcher>[isMethodCall('stopService', arguments: null)]);
    });

    test('startScan calls correct method', () async {
      final result = await audioService.startScan();
      expect(result, true);
      expect(log, <Matcher>[isMethodCall('scanDevices', arguments: null)]);
    });

    test('stopScan calls correct method', () async {
      await audioService.stopScan();
      expect(log, <Matcher>[isMethodCall('stopScan', arguments: null)]);
    });

    test('connectDevice calls correct method with arguments', () async {
      final result = await audioService.connectDevice('00:00:00:00:00:00');
      expect(result, true);
      expect(log, <Matcher>[
        isMethodCall(
          'connectDevice',
          arguments: {'macAddress': '00:00:00:00:00:00'},
        ),
      ]);
    });

    test('disconnectDevice calls correct method with arguments', () async {
      final result = await audioService.disconnectDevice('00:00:00:00:00:00');
      expect(result, true);
      expect(log, <Matcher>[
        isMethodCall(
          'disconnectDevice',
          arguments: {'macAddress': '00:00:00:00:00:00'},
        ),
      ]);
    });

    test(
      'getConnectedDevices calls correct method and parses result',
      () async {
        final result = await audioService.getConnectedDevices();
        expect(result.length, 1);
        expect(result.first['address'], '00:00:00:00:00:00');
        expect(result.first['name'], 'Device 1');
        expect(log, <Matcher>[
          isMethodCall('getConnectedDevices', arguments: null),
        ]);
      },
    );
  });
}
