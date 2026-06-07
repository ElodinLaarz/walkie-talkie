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
                case 'startLoopbackTest':
                case 'stopLoopbackTest':
                case 'setMuted':
                case 'setAudioOutput':
                case 'connectVoiceClient':
                case 'stopVoiceTransport':
                case 'unregisterVoicePeer':
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
        isMethodCall(
          'startService',
          arguments: <String, dynamic>{'freq': '104.3'},
        ),
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

    test('startLoopbackTest calls correct method', () async {
      final result = await audioService.startLoopbackTest();
      expect(result, true);
      expect(log, <Matcher>[
        isMethodCall('startLoopbackTest', arguments: null),
      ]);
    });

    test('stopLoopbackTest calls correct method', () async {
      final result = await audioService.stopLoopbackTest();
      expect(result, true);
      expect(log, <Matcher>[isMethodCall('stopLoopbackTest', arguments: null)]);
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
        codec.encodeSuccessEnvelope({
          'type': 'talkingPeers',
          'peers': ['local'],
        }),
        (_) {},
      );
      await Future<void>.microtask(() {});

      // Simulate native emitting an empty set (local stops talking).
      binding.defaultBinaryMessenger.handlePlatformMessage(
        eventChannelName,
        codec.encodeSuccessEnvelope({
          'type': 'talkingPeers',
          'peers': <String>[],
        }),
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
        codec.encodeSuccessEnvelope({
          'type': 'deviceConnected',
          'address': 'AA:BB',
        }),
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
              codec.encodeSuccessEnvelope({
                'type': 'localTalking',
                'talking': true,
              }),
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
              codec.encodeSuccessEnvelope({
                'type': 'localTalking',
                'talking': false,
              }),
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
              codec.encodeSuccessEnvelope({
                'type': 'talkingPeers',
                'peers': <String>[],
              }),
              (_) {},
            );
        await Future<void>.microtask(() {});

        expect(received, isEmpty);
      });
    });

    group('getCurrentRssi', () {
      test('returns parsed (peerId, rssi) entries from native', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.elodin.walkie_talkie/audio'),
              (MethodCall call) async {
                if (call.method != 'getCurrentRssi') return null;
                return [
                  {'peerId': 'AA:BB:CC:DD:EE:FF', 'rssi': -65},
                  {'peerId': '11:22:33:44:55:66', 'rssi': -85},
                ];
              },
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('com.elodin.walkie_talkie/audio'),
                null,
              ),
        );

        final result = await audioService.getCurrentRssi();
        expect(result, hasLength(2));
        expect(result[0].peerId, 'AA:BB:CC:DD:EE:FF');
        expect(result[0].rssi, -65);
        expect(result[1].peerId, '11:22:33:44:55:66');
        expect(result[1].rssi, -85);
      });

      test('returns empty list when native returns null', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.elodin.walkie_talkie/audio'),
              (MethodCall call) async {
                if (call.method != 'getCurrentRssi') return null;
                return null;
              },
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('com.elodin.walkie_talkie/audio'),
                null,
              ),
        );

        expect(await audioService.getCurrentRssi(), isEmpty);
      });

      test('returns empty list when native throws', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.elodin.walkie_talkie/audio'),
              (MethodCall call) async {
                if (call.method != 'getCurrentRssi') return null;
                throw PlatformException(code: 'ERR');
              },
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('com.elodin.walkie_talkie/audio'),
                null,
              ),
        );

        expect(await audioService.getCurrentRssi(), isEmpty);
      });

      test(
        'skips malformed entries with missing or wrong-typed fields',
        () async {
          // Malformed events would otherwise crash the call site or
          // surface NaN/0 RSSI readings to the cubit. The Dart side keeps
          // the contract tight so a bad native packet is a drop, not a
          // failure.
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('com.elodin.walkie_talkie/audio'),
                (MethodCall call) async {
                  if (call.method != 'getCurrentRssi') return null;
                  return [
                    {'peerId': 'good', 'rssi': -70},
                    {'peerId': 'no-rssi'}, // missing rssi
                    {'rssi': -50}, // missing peerId
                    {'peerId': 'wrong-type', 'rssi': '-50'}, // rssi is string
                    {'peerId': 42, 'rssi': -50}, // peerId is int
                  ];
                },
              );
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(
                  const MethodChannel('com.elodin.walkie_talkie/audio'),
                  null,
                ),
          );

          final result = await audioService.getCurrentRssi();
          expect(result, hasLength(1));
          expect(result.first.peerId, 'good');
          expect(result.first.rssi, -70);
        },
      );

      test('preserves valid entries when one element is not a Map', () async {
        // A non-Map element (a malformed native packet) used to throw
        // inside the .map() block and the outer catch would discard the
        // entire batch. Now we type-check + drop just the bad entry, so
        // valid samples in the same batch survive.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.elodin.walkie_talkie/audio'),
              (MethodCall call) async {
                if (call.method != 'getCurrentRssi') return null;
                return [
                  {'peerId': 'good', 'rssi': -70},
                  'not-a-map', // bare string would have crashed the cast
                  42, // bare int, same
                  {'peerId': 'also-good', 'rssi': -75},
                ];
              },
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('com.elodin.walkie_talkie/audio'),
                null,
              ),
        );

        final result = await audioService.getCurrentRssi();
        expect(result, hasLength(2));
        expect(result.map((r) => r.peerId), ['good', 'also-good']);
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
        final result = await audioService.connectVoiceClient(
          'AA:BB:CC:DD:EE:FF',
          0x83,
        );
        expect(result, true);
        expect(log, [
          isMethodCall(
            'connectVoiceClient',
            arguments: <String, dynamic>{
              'macAddress': 'AA:BB:CC:DD:EE:FF',
              'psm': 0x83,
            },
          ),
        ]);
      });

      test('stopVoiceTransport calls correct method', () async {
        log.clear();
        final result = await audioService.stopVoiceTransport();
        expect(result, true);
        expect(log, [isMethodCall('stopVoiceTransport', arguments: null)]);
      });

      test('unregisterPeer passes mac to native layer', () async {
        log.clear();
        final result = await audioService.unregisterPeer('AA:BB:CC:DD:EE:FF');
        expect(result, true);
        expect(log, [
          isMethodCall(
            'unregisterVoicePeer',
            arguments: <String, dynamic>{'macAddress': 'AA:BB:CC:DD:EE:FF'},
          ),
        ]);
      });
    });

    group('error path coverage (catch blocks return defaults)', () {
      void installFailing() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.elodin.walkie_talkie/audio'),
              (call) async => throw PlatformException(code: 'BOOM'),
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('com.elodin.walkie_talkie/audio'),
                null,
              ),
        );
      }

      test('startService returns false', () async {
        installFailing();
        expect(await audioService.startService(), false);
      });

      test('stopService returns false', () async {
        installFailing();
        expect(await audioService.stopService(), false);
      });

      test('startScan returns false', () async {
        installFailing();
        expect(await audioService.startScan(), false);
      });

      test('stopScan swallows error', () async {
        installFailing();
        await audioService.stopScan(); // no throw
      });

      test('connectDevice returns false', () async {
        installFailing();
        expect(await audioService.connectDevice('AA:BB'), false);
      });

      test('disconnectDevice returns false', () async {
        installFailing();
        expect(await audioService.disconnectDevice('AA:BB'), false);
      });

      test('startVoice returns false', () async {
        installFailing();
        expect(await audioService.startVoice(), false);
      });

      test('stopVoice returns false', () async {
        installFailing();
        expect(await audioService.stopVoice(), false);
      });

      test('setMuted returns false', () async {
        installFailing();
        expect(await audioService.setMuted(true), false);
      });

      test('setAudioOutput returns false', () async {
        installFailing();
        expect(await audioService.setAudioOutput('speaker'), false);
      });

      test('getConnectedDevices returns empty list', () async {
        installFailing();
        expect(await audioService.getConnectedDevices(), isEmpty);
      });

      test('startAdvertising returns false', () async {
        installFailing();
        expect(
          await audioService.startAdvertising(
            sessionUuid: 'uuid',
            displayName: 'Maya',
          ),
          false,
        );
      });

      test('stopAdvertising returns false', () async {
        installFailing();
        expect(await audioService.stopAdvertising(), false);
      });

      test('startGattServer returns false', () async {
        installFailing();
        expect(await audioService.startGattServer(), false);
      });

      test('stopGattServer returns false', () async {
        installFailing();
        expect(await audioService.stopGattServer(), false);
      });

      test('writeNotification returns false', () async {
        installFailing();
        expect(await audioService.writeNotification('AA:BB', [1, 2, 3]), false);
      });

      test('connectVoiceClient returns false', () async {
        installFailing();
        expect(await audioService.connectVoiceClient('AA:BB', 0x81), false);
      });

      test('stopVoiceTransport returns false', () async {
        installFailing();
        expect(await audioService.stopVoiceTransport(), false);
      });

      test('unregisterPeer returns false', () async {
        installFailing();
        expect(await audioService.unregisterPeer('AA:BB'), false);
      });

      test('connectToHost returns false', () async {
        installFailing();
        expect(await audioService.connectToHost('AA:BB'), false);
      });

      test('disconnectFromHost returns false', () async {
        installFailing();
        expect(await audioService.disconnectFromHost(), false);
      });

      test('writeRequest returns false', () async {
        installFailing();
        expect(await audioService.writeRequest(Uint8List.fromList([1])), false);
      });

      test('writeControlBytes swallows error', () async {
        installFailing();
        await audioService.writeControlBytes(
          Uint8List.fromList([1]),
        ); // no throw
      });

      test('getNegotiatedMtu returns null', () async {
        installFailing();
        expect(await audioService.getNegotiatedMtu('AA:BB'), isNull);
      });

      test('setPeerBitrate returns null', () async {
        installFailing();
        expect(await audioService.setPeerBitrate('AA:BB', 24000), isNull);
      });

      test('getLinkTelemetry returns null', () async {
        installFailing();
        expect(await audioService.getLinkTelemetry('AA:BB'), isNull);
      });

      test('getInitialLink returns null on error', () async {
        installFailing();
        expect(await audioService.getInitialLink(), isNull);
      });
    });

    group('happy-path coverage for missing methods', () {
      Future<dynamic> Function(MethodCall)? handler;

      setUp(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.elodin.walkie_talkie/audio'),
              (call) async {
                log.add(call);
                return handler == null ? null : await handler!(call);
              },
            );
      });

      tearDown(() {
        handler = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.elodin.walkie_talkie/audio'),
              null,
            );
      });

      test('setAudioOutput forwards arg', () async {
        handler = (_) async => true;
        log.clear();
        expect(await audioService.setAudioOutput('bluetooth'), true);
        expect(log, [
          isMethodCall('setAudioOutput', arguments: {'output': 'bluetooth'}),
        ]);
      });

      test('startAdvertising forwards args', () async {
        handler = (_) async => true;
        log.clear();
        expect(
          await audioService.startAdvertising(
            sessionUuid: 'abc-123',
            displayName: 'Maya',
          ),
          true,
        );
        expect(log, [
          isMethodCall(
            'startAdvertising',
            arguments: {'sessionUuid': 'abc-123', 'displayName': 'Maya'},
          ),
        ]);
      });

      test('stopAdvertising calls correct method', () async {
        handler = (_) async => true;
        log.clear();
        expect(await audioService.stopAdvertising(), true);
        expect(log, [isMethodCall('stopAdvertising', arguments: null)]);
      });

      test('startGattServer / stopGattServer', () async {
        handler = (_) async => true;
        log.clear();
        expect(await audioService.startGattServer(), true);
        expect(await audioService.stopGattServer(), true);
        expect(log.map((c) => c.method), ['startGattServer', 'stopGattServer']);
      });

      test('writeNotification forwards args', () async {
        handler = (_) async => true;
        log.clear();
        expect(
          await audioService.writeNotification('AA:BB:CC', [9, 8, 7]),
          true,
        );
        expect(log, [
          isMethodCall(
            'writeNotification',
            arguments: {
              'deviceAddress': 'AA:BB:CC',
              'bytes': [9, 8, 7],
            },
          ),
        ]);
      });

      test('connectToHost / disconnectFromHost / writeRequest', () async {
        handler = (_) async => true;
        log.clear();
        expect(await audioService.connectToHost('AA:BB'), true);
        expect(await audioService.disconnectFromHost(), true);
        expect(
          await audioService.writeRequest(Uint8List.fromList([1, 2])),
          true,
        );
        expect(log.map((c) => c.method), [
          'connectToHost',
          'disconnectFromHost',
          'writeRequest',
        ]);
      });

      test('writeControlBytes forwards bytes', () async {
        handler = (_) async => null;
        log.clear();
        await audioService.writeControlBytes(Uint8List.fromList([1, 2, 3]));
        expect(log, hasLength(1));
        expect(log.first.method, 'writeControlBytes');
        expect(log.first.arguments['bytes'], isA<Uint8List>());
      });

      test('getNegotiatedMtu returns native int', () async {
        handler = (_) async => 247;
        log.clear();
        expect(await audioService.getNegotiatedMtu('AA:BB'), 247);
        expect(log, [
          isMethodCall('getNegotiatedMtu', arguments: {'endpointId': 'AA:BB'}),
        ]);
      });

      test('setPeerBitrate returns clamped value', () async {
        handler = (_) async => 16000;
        log.clear();
        expect(await audioService.setPeerBitrate('AA:BB', 24000), 16000);
        expect(log, [
          isMethodCall(
            'setPeerBitrate',
            arguments: {'macAddress': 'AA:BB', 'bps': 24000},
          ),
        ]);
      });

      test('setPeerBitrate returns null on negative result', () async {
        handler = (_) async => -1;
        expect(await audioService.setPeerBitrate('AA:BB', 24000), isNull);
      });

      test('setPeerBitrate returns null when native returns null', () async {
        handler = (_) async => null;
        expect(await audioService.setPeerBitrate('AA:BB', 24000), isNull);
      });

      test('getLinkTelemetry returns parsed snapshot', () async {
        handler = (_) async => [10, 5, 8, 4, 16000];
        final snap = await audioService.getLinkTelemetry('AA:BB');
        expect(snap, isNotNull);
        expect(snap!.underrunCount, 10);
        expect(snap.lateFrameCount, 5);
        expect(snap.targetDepthFrames, 8);
        expect(snap.currentDepthFrames, 4);
        expect(snap.currentBitrateBps, 16000);
      });

      test('getLinkTelemetry returns null on wrong shape (length)', () async {
        handler = (_) async => [1, 2, 3]; // only 3 elements
        expect(await audioService.getLinkTelemetry('AA:BB'), isNull);
      });

      test('getLinkTelemetry returns null on wrong type element', () async {
        handler = (_) async => [1, 2, 3, 4, '16000']; // last is string
        expect(await audioService.getLinkTelemetry('AA:BB'), isNull);
      });

      test(
        'getLinkTelemetry returns null when native returns non-list',
        () async {
          handler = (_) async => 'nope';
          expect(await audioService.getLinkTelemetry('AA:BB'), isNull);
        },
      );

      test('getInitialLink returns freq string from native', () async {
        handler = (call) async {
          if (call.method == 'getInitialLink') return '104.3';
          return null;
        };
        final result = await audioService.getInitialLink();
        expect(result, '104.3');
        expect(log.last, isMethodCall('getInitialLink', arguments: null));
      });

      test('getInitialLink returns null when native returns null', () async {
        handler = (call) async => null;
        expect(await audioService.getInitialLink(), isNull);
      });
    });

    group('LinkTelemetrySnapshot equality + hashCode', () {
      const a = LinkTelemetrySnapshot(
        underrunCount: 1,
        lateFrameCount: 2,
        targetDepthFrames: 3,
        currentDepthFrames: 4,
        currentBitrateBps: 16000,
      );
      const b = LinkTelemetrySnapshot(
        underrunCount: 1,
        lateFrameCount: 2,
        targetDepthFrames: 3,
        currentDepthFrames: 4,
        currentBitrateBps: 16000,
      );
      const c = LinkTelemetrySnapshot(
        underrunCount: 99,
        lateFrameCount: 2,
        targetDepthFrames: 3,
        currentDepthFrames: 4,
        currentBitrateBps: 16000,
      );

      test('identical instances are equal', () {
        expect(a, equals(a));
      });

      test('value-equal instances are equal', () {
        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
      });

      test('different fields are not equal', () {
        expect(a == c, isFalse);
      });

      test('not equal to a different type', () {
        expect(a == Object(), isFalse);
      });
    });

    group('audioEvents stream', () {
      test('parses native events into Map<String,dynamic>', () async {
        const eventChannelName = 'com.elodin.walkie_talkie/audio_events';
        final codec = const StandardMethodCodec();

        final received = <Map<String, dynamic>>[];
        final sub = audioService.audioEvents.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              eventChannelName,
              codec.encodeSuccessEnvelope({'type': 'foo', 'value': 7}),
              (_) {},
            );
        await Future<void>.microtask(() {});

        expect(received, hasLength(1));
        expect(received.first['type'], 'foo');
        expect(received.first['value'], 7);
      });

      test('caches a single broadcast stream across reads', () {
        final s1 = audioService.audioEvents;
        final s2 = audioService.audioEvents;
        expect(identical(s1, s2), isTrue);
      });
    });

    group('controlBytes stream', () {
      test('emits typed records for Uint8List events', () async {
        const eventChannelName = 'com.elodin.walkie_talkie/control_bytes';
        final codec = const StandardMethodCodec();

        final received = <({String endpointId, Uint8List bytes})>[];
        final sub = audioService.controlBytes.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              eventChannelName,
              codec.encodeSuccessEnvelope({
                'endpointId': 'AA:BB',
                'bytes': Uint8List.fromList([1, 2, 3]),
              }),
              (_) {},
            );
        await Future<void>.delayed(Duration.zero);

        expect(received, hasLength(1));
        expect(received[0].endpointId, 'AA:BB');
        expect(received[0].bytes, Uint8List.fromList([1, 2, 3]));
      });

      test('emits typed records for List<int> bytes (codec branch)', () async {
        const eventChannelName = 'com.elodin.walkie_talkie/control_bytes';
        final codec = const StandardMethodCodec();

        final received = <({String endpointId, Uint8List bytes})>[];
        final sub = audioService.controlBytes.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              eventChannelName,
              codec.encodeSuccessEnvelope({
                'endpointId': 'CC:DD',
                'bytes': <int>[9, 8, 7],
              }),
              (_) {},
            );
        await Future<void>.delayed(Duration.zero);

        expect(received, hasLength(1));
        expect(received[0].endpointId, 'CC:DD');
        expect(received[0].bytes, Uint8List.fromList([9, 8, 7]));
      });

      test('drops malformed events (missing fields)', () async {
        const eventChannelName = 'com.elodin.walkie_talkie/control_bytes';
        final codec = const StandardMethodCodec();

        final received = <({String endpointId, Uint8List bytes})>[];
        final sub = audioService.controlBytes.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              eventChannelName,
              codec.encodeSuccessEnvelope({'endpointId': 'AA'}), // no bytes
              (_) {},
            );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              eventChannelName,
              codec.encodeSuccessEnvelope({
                'bytes': [1],
              }), // no endpointId
              (_) {},
            );
        await Future<void>.microtask(() {});

        expect(received, isEmpty);
      });

      test('caches the broadcast source across reads', () async {
        // The exposed stream is the where/map wrapper, so identity does not
        // hold; instead, verify a single emission fan-outs to two listeners
        // attached to two separate `controlBytes` reads — this is only
        // possible if the underlying broadcast source is cached.
        final s1 = audioService.controlBytes;
        final s2 = audioService.controlBytes;
        final eventChannelName = 'com.elodin.walkie_talkie/control_bytes';
        final codec = const StandardMethodCodec();
        final a = <({String endpointId, Uint8List bytes})>[];
        final b = <({String endpointId, Uint8List bytes})>[];
        final subA = s1.listen(a.add);
        final subB = s2.listen(b.add);
        addTearDown(() async {
          await subA.cancel();
          await subB.cancel();
        });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              eventChannelName,
              codec.encodeSuccessEnvelope({
                'endpointId': 'X',
                'bytes': Uint8List.fromList([42]),
              }),
              (_) {},
            );
        await Future<void>.delayed(Duration.zero);

        expect(a, hasLength(1));
        expect(b, hasLength(1));
        expect(a.first.endpointId, 'X');
        expect(a.first.bytes, Uint8List.fromList([42]));
        expect(b.first.endpointId, 'X');
        expect(b.first.bytes, Uint8List.fromList([42]));
      });
    });

    group('voice-path telemetry streams', () {
      const eventChannelName = 'com.elodin.walkie_talkie/audio_events';
      final codec = const StandardMethodCodec();

      test('l2capOpen surfaces guest-side l2capOpen events', () async {
        final received = <Map<String, dynamic>>[];
        final sub = audioService.l2capOpen.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              eventChannelName,
              codec.encodeSuccessEnvelope({
                'type': 'l2capOpen',
                'address': 'AA:BB:CC:DD:EE:FF',
                'role': 'guest',
              }),
              (_) {},
            );
        await Future<void>.microtask(() {});

        expect(received, hasLength(1));
        expect(received.first['address'], 'AA:BB:CC:DD:EE:FF');
        expect(received.first['role'], 'guest');
      });

      test('l2capOpen surfaces host-side l2capOpen events', () async {
        final received = <Map<String, dynamic>>[];
        final sub = audioService.l2capOpen.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              eventChannelName,
              codec.encodeSuccessEnvelope({
                'type': 'l2capOpen',
                'address': '11:22:33:44:55:66',
                'role': 'host',
              }),
              (_) {},
            );
        await Future<void>.microtask(() {});

        expect(received, hasLength(1));
        expect(received.first['role'], 'host');
      });

      test('l2capOpen ignores unrelated events', () async {
        final received = <Map<String, dynamic>>[];
        final sub = audioService.l2capOpen.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              eventChannelName,
              codec.encodeSuccessEnvelope({
                'type': 'talkingPeers',
                'peers': [],
              }),
              (_) {},
            );
        await Future<void>.microtask(() {});

        expect(received, isEmpty);
      });

      test('firstEncodedFrame surfaces first-encode events', () async {
        final received = <Map<String, dynamic>>[];
        final sub = audioService.firstEncodedFrame.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              eventChannelName,
              codec.encodeSuccessEnvelope({
                'type': 'firstEncodedFrame',
                'address': 'AA:BB:CC:DD:EE:FF',
              }),
              (_) {},
            );
        await Future<void>.microtask(() {});

        expect(received, hasLength(1));
        expect(received.first['address'], 'AA:BB:CC:DD:EE:FF');
      });

      test('firstDecodedFrame surfaces first-decode events', () async {
        final received = <Map<String, dynamic>>[];
        final sub = audioService.firstDecodedFrame.listen(received.add);
        addTearDown(sub.cancel);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              eventChannelName,
              codec.encodeSuccessEnvelope({
                'type': 'firstDecodedFrame',
                'address': 'AA:BB:CC:DD:EE:FF',
              }),
              (_) {},
            );
        await Future<void>.microtask(() {});

        expect(received, hasLength(1));
        expect(received.first['address'], 'AA:BB:CC:DD:EE:FF');
      });

      test(
        'firstEncodedFrame and firstDecodedFrame ignore unrelated events',
        () async {
          final encoded = <Map<String, dynamic>>[];
          final decoded = <Map<String, dynamic>>[];
          final s1 = audioService.firstEncodedFrame.listen(encoded.add);
          final s2 = audioService.firstDecodedFrame.listen(decoded.add);
          addTearDown(s1.cancel);
          addTearDown(s2.cancel);

          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
                eventChannelName,
                codec.encodeSuccessEnvelope({
                  'type': 'l2capOpen',
                  'address': 'X',
                  'role': 'guest',
                }),
                (_) {},
              );
          await Future<void>.microtask(() {});

          expect(encoded, isEmpty);
          expect(decoded, isEmpty);
        },
      );
    });
  });
}
