import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/services/audio_service.dart';
import 'package:walkie_talkie/services/reconnect_controller.dart';

// Short delays used in all tests so the suite runs fast.
const _testDelays = [
  Duration.zero,
  Duration.zero,
  Duration.zero,
  Duration.zero,
  Duration.zero,
  Duration.zero,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AudioService audio;
  // connectDevice results consumed in order; empty = false.
  final List<bool> connectResults = [];
  int connectCallCount = 0;

  setUp(() {
    audio = AudioService();
    connectResults.clear();
    connectCallCount = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.elodin.walkie_talkie/audio'),
      (MethodCall call) async {
        if (call.method == 'connectDevice') {
          connectCallCount++;
          if (connectResults.isEmpty) return false;
          return connectResults.removeAt(0);
        }
        return null;
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

  group('ReconnectController', () {
    test('returns true immediately when first attempt succeeds', () async {
      connectResults.addAll([true]);
      final controller =
          ReconnectController(audio: audio, delays: _testDelays);

      final result = await controller.attempt(macAddress: 'AA:BB:CC:DD:EE:FF');

      expect(result, isTrue);
      expect(connectCallCount, 1);
    });

    test('retries until a later attempt succeeds', () async {
      connectResults.addAll([false, false, true]);
      final controller =
          ReconnectController(audio: audio, delays: _testDelays);

      final result = await controller.attempt(macAddress: 'AA:BB:CC:DD:EE:FF');

      expect(result, isTrue);
      expect(connectCallCount, 3);
    });

    test('returns false when all retries are exhausted', () async {
      final controller =
          ReconnectController(audio: audio, delays: _testDelays);

      final result = await controller.attempt(macAddress: 'AA:BB:CC:DD:EE:FF');

      expect(result, isFalse);
      expect(connectCallCount, _testDelays.length);
    });

    test('cancel stops the loop before the next attempt', () async {
      // fail on first attempt, then succeed — but we cancel between them
      connectResults.addAll([false, true]);

      bool cancelled = false;
      // One non-zero delay to create a cancellation window.
      final delays = List<Duration>.filled(6, Duration.zero);
      delays[1] = const Duration(milliseconds: 20);

      final controller = ReconnectController(audio: audio, delays: delays);

      // Cancel partway through the second delay.
      Future.delayed(const Duration(milliseconds: 10), () {
        cancelled = true;
        controller.cancel();
      });

      final result =
          await controller.attempt(macAddress: 'AA:BB:CC:DD:EE:FF');

      expect(cancelled, isTrue);
      expect(result, isFalse);
      // Only the first attempt (false) should have run.
      expect(connectCallCount, 1);
    });

    test('cancel after completion is a no-op', () async {
      connectResults.addAll([true]);
      final controller =
          ReconnectController(audio: audio, delays: _testDelays);

      await controller.attempt(macAddress: 'AA:BB:CC:DD:EE:FF');
      controller.cancel(); // must not throw
    });

    test('delays list has six entries covering ~19s total budget', () {
      final total = ReconnectController.delays
          .fold(Duration.zero, (acc, d) => acc + d);
      // 250ms + 500ms + 1s + 2s + 5s + 10s = 18750ms
      expect(total.inMilliseconds, 18750);
      expect(ReconnectController.delays, hasLength(6));
    });
  });
}
