import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('native audio bridge contract', () {
    test('startVoice starts and stopVoice stops the native engine', () {
      final mainActivity = File(
        'android/app/src/main/kotlin/com/elodin/walkie_talkie/MainActivity.kt',
      ).readAsStringSync();

      expect(mainActivity, contains('"startVoice" ->'));
      // startVoiceCapture stays idempotent on an existing peerAudioManager —
      // the early-return short-circuits a duplicate start. (Form changed from a
      // `return true` expression to a callback-style guard when startVoice was
      // made async to retry past the foreground-service startup race; the
      // idempotency contract is unchanged.)
      expect(
        mainActivity,
        contains('if (peerAudioManager != null) {'),
      );
      expect(
        mainActivity,
        contains('startVoiceCapture(loopbackTestMode = false)'),
      );
      expect(mainActivity, contains('"stopVoice" ->'));
      expect(mainActivity, contains('stopVoiceCapture()'));
      expect(mainActivity, contains('service.startAudioEngine()'));
      // The service lookup was refactored to use a local variable for efficiency
      expect(
        mainActivity,
        contains('val service = WalkieTalkieService.getRunning()'),
      );
      expect(mainActivity, contains('service?.stopAudioEngine()'));
    });

    test(
      'loopback mode has a MethodChannel entry and synthetic mixer device',
      () {
        final mainActivity = File(
          'android/app/src/main/kotlin/com/elodin/walkie_talkie/MainActivity.kt',
        ).readAsStringSync();
        final audioEngine = File(
          'android/app/src/main/cpp/audio_engine.cpp',
        ).readAsStringSync();

        expect(mainActivity, contains('"startLoopbackTest" ->'));
        expect(mainActivity, contains('"stopLoopbackTest" ->'));
        expect(mainActivity, contains('LOOPBACK_TEST_DEVICE_ID = -1'));
        expect(mainActivity, contains('audioMixerManager?.addDevice(0)'));
        expect(
          mainActivity,
          contains('audioMixerManager?.addDevice(LOOPBACK_TEST_DEVICE_ID)'),
        );
        expect(audioEngine, contains('g_loopbackTestMode'));
        expect(audioEngine, contains('kLoopbackTestDeviceId = -1'));
        expect(audioEngine, contains('kLoopbackTestDeviceId, codecScratch_'));
      },
    );

    test('input callback writes mixed PCM to the Oboe playback stream', () {
      final audioEngine = File(
        'android/app/src/main/cpp/audio_engine.cpp',
      ).readAsStringSync();

      expect(audioEngine, contains('getDirection() != oboe::Direction::Input'));
      expect(audioEngine, contains('playbackStream->write('));
      expect(audioEngine, contains('playoutScratch_'));
    });

    test('unregisterVoicePeer releases a departed peer\'s native state', () {
      final mainActivity = File(
        'android/app/src/main/kotlin/com/elodin/walkie_talkie/MainActivity.kt',
      ).readAsStringSync();

      // Issue #476: the cubit calls this channel method on a peer's departure
      // so the host doesn't leak one native PeerState per guest that ever
      // connected. Native unregisterPeer + JNI already exist; this pins the
      // MainActivity wiring that the Dart-side tests can't exercise directly.
      expect(mainActivity, contains('"unregisterVoicePeer" ->'));
      expect(mainActivity, contains('peerAudioManager?.unregisterPeer(mac)'));
    });
  });
}
