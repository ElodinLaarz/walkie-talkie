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
  // connectToHost results consumed in order; empty = false.
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
            if (call.method == 'connectToHost') {
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
      final controller = ReconnectController(audio: audio, delays: _testDelays);

      final result = await controller.attempt(macAddress: 'AA:BB:CC:DD:EE:FF');

      expect(result, isTrue);
      expect(connectCallCount, 1);
    });

    test('retries until a later attempt succeeds', () async {
      connectResults.addAll([false, false, true]);
      final controller = ReconnectController(audio: audio, delays: _testDelays);

      final result = await controller.attempt(macAddress: 'AA:BB:CC:DD:EE:FF');

      expect(result, isTrue);
      expect(connectCallCount, 3);
    });

    test('returns false when all retries are exhausted', () async {
      final controller = ReconnectController(audio: audio, delays: _testDelays);

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

      final result = await controller.attempt(macAddress: 'AA:BB:CC:DD:EE:FF');

      expect(cancelled, isTrue);
      expect(result, isFalse);
      // Only the first attempt (false) should have run.
      expect(connectCallCount, 1);
    });

    test('cancel after completion is a no-op', () async {
      connectResults.addAll([true]);
      final controller = ReconnectController(audio: audio, delays: _testDelays);

      await controller.attempt(macAddress: 'AA:BB:CC:DD:EE:FF');
      controller.cancel(); // must not throw
    });

    test('a superseding attempt does not clobber a prior cancel', () async {
      // Regression for #34: the old design reset a shared `_cancelled` flag at
      // the start of every attempt, so a second overlapping call resurrected a
      // loop that had already been cancelled. The generation guard keeps the
      // first loop cancelled even though the second call clears the flag.
      connectResults.addAll([true, true, true, true, true, true]);
      final delays = List<Duration>.filled(6, const Duration(milliseconds: 20));
      final controller = ReconnectController(audio: audio, delays: delays);

      final f1 = controller.attempt(macAddress: 'AA:BB:CC:DD:EE:FF');
      // Cancel f1 mid first-delay, then immediately supersede it with f2.
      await Future.delayed(const Duration(milliseconds: 5));
      controller.cancel();
      final f2 = controller.attempt(macAddress: '11:22:33:44:55:66');

      final r1 = await f1;
      final r2 = await f2;

      expect(r1, isFalse); // stays cancelled despite f2 resetting the flag
      expect(r2, isTrue); // f2 runs fresh and its first dial succeeds
    });

    test('starting a new attempt supersedes the in-flight one', () async {
      // Two overlapping attempts must not both drive the dial loop; the later
      // call wins and the earlier bails on the generation change before it
      // ever dials, so only f2 consumes the retry budget (no double-dial).
      final delays = List<Duration>.filled(6, const Duration(milliseconds: 20));
      final controller = ReconnectController(audio: audio, delays: delays);

      final f1 = controller.attempt(macAddress: 'AA:BB:CC:DD:EE:FF');
      await Future.delayed(const Duration(milliseconds: 5));
      final f2 = controller.attempt(macAddress: '11:22:33:44:55:66');

      final r1 = await f1;
      await f2;

      expect(r1, isFalse);
      expect(connectCallCount, _testDelays.length); // 6 — only f2 dialed
    });

    test('six-step budget fits within 20 s purge window', () {
      final sleepBudget = ReconnectController.delays.fold(
        Duration.zero,
        (acc, d) => acc + d,
      );
      // 250ms + 500ms + 1s + 2s + 4s + 5s = 12750ms
      expect(sleepBudget.inMilliseconds, 12750);
      expect(ReconnectController.delays, hasLength(6));

      final n = ReconnectController.delays.length;
      final worstCase = sleepBudget + ReconnectController.connectTimeout * n;
      // 12750ms + 6 × 1000ms = 18750ms < 20000ms (15s miss-threshold + 5s grace)
      expect(worstCase.inMilliseconds, lessThan(20000));
    });
  });
}
