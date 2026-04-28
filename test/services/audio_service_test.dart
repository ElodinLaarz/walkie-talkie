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
                case 'setAudioOutput':
                case 'connectVoiceClient':
                case 'stopVoiceTransport':
                  return true;
                case 'startVoiceServer':
                  return 0x81;
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

    test('startService calls correct method without freq', () async {
      final result = await audioService.startService();
      expect(result, true);
      expect(log, <Matcher>[isMethodCall('startService', arguments: null)]);
    });

    test('startService passes freq to native layer', () async {
      final result = await audioService.startService(freq: '104.3');
      expect(result, true);
      expect(log, <Matcher>[
        isMethodCall('startService', arguments: <String, dynamic>{'freq': '104.3'}),
      ]);
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

    group('localTalking', () {
      late AudioService localTalkingAudio;

      setUp(() {
        localTalkingAudio = AudioService();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('com.elodin.walkie_talkie/audio'),
          (MethodCall call) async => null,
        );
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('com.elodin.walkie_talkie/audio'),
          null,
        );
      });

      test('emits true when native fires localTalking=true', () async {
        const eventChannelName = 'com.elodin.walkie_talkie/audio_events';
        final codec = const StandardMethodCodec();
        final received = <bool>[];
        final sub = localTalkingAudio.localTalking.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          eventChannelName,
          codec.encodeSuccessEnvelope({'type': 'localTalking', 'talking': true}),
          (_) {},
        );
        await Future<void>.microtask(() {});

        expect(received, [true]);
      });

      test('emits false when native fires localTalking=false', () async {
        const eventChannelName = 'com.elodin.walkie_talkie/audio_events';
        final codec = const StandardMethodCodec();
        final received = <bool>[];
        final sub = localTalkingAudio.localTalking.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          eventChannelName,
          codec.encodeSuccessEnvelope({'type': 'localTalking', 'talking': false}),
          (_) {},
        );
        await Future<void>.microtask(() {});

        expect(received, [false]);
      });

      test('ignores unrelated native events', () async {
        const eventChannelName = 'com.elodin.walkie_talkie/audio_events';
        final codec = const StandardMethodCodec();
        final received = <bool>[];
        final sub = localTalkingAudio.localTalking.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          eventChannelName,
          codec.encodeSuccessEnvelope({'type': 'talkingPeers', 'peers': <String>[]}),
          (_) {},
        );
        await Future<void>.microtask(() {});

        expect(received, isEmpty);
      });
    });

    group('L2CAP voice transport', () {
    test('startVoiceServer returns PSM from native layer', () async {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.elodin.walkie_talkie/audio'),
        (MethodCall call) async {
          log.add(call);
          if (call.method == 'startVoiceServer') return 0x81;
          return null;
        },
      );

      final psm = await audioService.startVoiceServer();
      expect(psm, 0x81);
      expect(log, [isMethodCall('startVoiceServer', arguments: null)]);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.elodin.walkie_talkie/audio'),
        null,
      );
    });

    test('startVoiceServer returns null on native error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.elodin.walkie_talkie/audio'),
        (MethodCall call) async => throw PlatformException(code: 'ERR'),
      );

      final psm = await audioService.startVoiceServer();
      expect(psm, isNull);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.elodin.walkie_talkie/audio'),
        null,
      );
    });

    test('connectVoiceClient passes mac and psm to native layer', () async {
      log.clear();
      final result = await audioService.connectVoiceClient('AA:BB:CC:DD:EE:FF', 0x83);
      expect(result, true);
      expect(log, [
        isMethodCall(
          'connectVoiceClient',
          arguments: <String, dynamic>{'macAddress': 'AA:BB:CC:DD:EE:FF', 'psm': 0x83},
        ),
      ]);
    });

    test('stopVoiceTransport calls correct method', () async {
      log.clear();
      final result = await audioService.stopVoiceTransport();
      expect(result, true);
      expect(log, [isMethodCall('stopVoiceTransport', arguments: null)]);
    });
  });
  });
}
