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
                case 'startVoice':
                case 'stopVoice':
                case 'setMuted':
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

    test('startVoice calls correct method', () async {
      final result = await audioService.startVoice();
      expect(result, true);
      expect(log, <Matcher>[isMethodCall('startVoice', arguments: null)]);
    });

    test('stopVoice calls correct method', () async {
      final result = await audioService.stopVoice();
      expect(result, true);
      expect(log, <Matcher>[isMethodCall('stopVoice', arguments: null)]);
    });

    test('setMuted forwards the muted flag in the args', () async {
      final muted = await audioService.setMuted(true);
      final unmuted = await audioService.setMuted(false);
      expect(muted, true);
      expect(unmuted, true);
      expect(log, <Matcher>[
        isMethodCall('setMuted', arguments: {'muted': true}),
        isMethodCall('setMuted', arguments: {'muted': false}),
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

    test('talkingPeers maps native events to peer ID sets', () async {
      const eventChannelName = 'com.elodin.walkie_talkie/audio_events';

      // Grab the codec the EventChannel registered so we can send events.
      final codec = const StandardMethodCodec();

      // Collect emitted peer sets.
      final received = <Set<String>>[];
      final sub = audioService.talkingPeers.listen(received.add);
      addTearDown(sub.cancel);

      // Simulate native emitting talkingPeers with the local sentinel.
      final binding = TestDefaultBinaryMessengerBinding.instance;
      binding.defaultBinaryMessenger.handlePlatformMessage(
        eventChannelName,
        codec.encodeSuccessEnvelope({'type': 'talkingPeers', 'peers': ['local']}),
        (_) {},
      );
      await Future<void>.microtask(() {});

      // Simulate native emitting an empty set (local stops talking).
      binding.defaultBinaryMessenger.handlePlatformMessage(
        eventChannelName,
        codec.encodeSuccessEnvelope({'type': 'talkingPeers', 'peers': <String>[]}),
        (_) {},
      );
      await Future<void>.microtask(() {});

      expect(received, [
        {'local'},
        <String>{},
      ]);
    });

    test('talkingPeers ignores unrelated native events', () async {
      const eventChannelName = 'com.elodin.walkie_talkie/audio_events';
      final codec = const StandardMethodCodec();

      final received = <Set<String>>[];
      final sub = audioService.talkingPeers.listen(received.add);
      addTearDown(sub.cancel);

      final binding = TestDefaultBinaryMessengerBinding.instance;
      binding.defaultBinaryMessenger.handlePlatformMessage(
        eventChannelName,
        codec.encodeSuccessEnvelope({'type': 'deviceConnected', 'address': 'AA:BB'}),
        (_) {},
      );
      await Future<void>.microtask(() {});

      expect(received, isEmpty);
    });
  });
}
