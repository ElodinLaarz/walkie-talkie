import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';

/// Service for communicating with native Android audio layer
class AudioService {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.elodin.walkie_talkie/audio',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.elodin.walkie_talkie/audio_events',
  );

  Stream<Map<String, dynamic>>? _eventStream;

  /// Start the foreground service
  Future<bool> startService() async {
    try {
      final result = await _methodChannel.invokeMethod('startService');
      return result as bool;
    } catch (e) {
      debugPrint('Error starting service: $e');
      return false;
    }
  }

  /// Stop the foreground service
  Future<bool> stopService() async {
    try {
      final result = await _methodChannel.invokeMethod('stopService');
      return result as bool;
    } catch (e) {
      debugPrint('Error stopping service: $e');
      return false;
    }
  }

  /// Start scanning for Bluetooth LE Audio devices
  Future<bool> startScan() async {
    try {
      final result = await _methodChannel.invokeMethod('scanDevices');
      return result as bool;
    } catch (e) {
      debugPrint('Error scanning devices: $e');
      return false;
    }
  }

  /// Stop scanning
  Future<void> stopScan() async {
    try {
      await _methodChannel.invokeMethod('stopScan');
    } catch (e) {
      debugPrint('Error stopping scan: $e');
    }
  }

  /// Connect to a Bluetooth device
  Future<bool> connectDevice(String macAddress) async {
    try {
      final result = await _methodChannel.invokeMethod('connectDevice', {
        'macAddress': macAddress,
      });
      return result as bool;
    } catch (e) {
      debugPrint('Error connecting to device: $e');
      return false;
    }
  }

  /// Disconnect from a Bluetooth device
  Future<bool> disconnectDevice(String macAddress) async {
    try {
      final result = await _methodChannel.invokeMethod('disconnectDevice', {
        'macAddress': macAddress,
      });
      return result as bool;
    } catch (e) {
      debugPrint('Error disconnecting from device: $e');
      return false;
    }
  }

  /// Begin voice capture and streaming. Wires the mic into the L2CAP CoC
  /// the host advertised in `JoinAccepted` (or the host's own
  /// AudioRecord → mix-minus loop when the local user *is* the host).
  ///
  /// Idempotent at the native layer — repeated calls while voice is up
  /// resolve to the existing capture session. Called from the room screen
  /// when the user enters the room or releases mute, so a quick
  /// mute → unmute → mute doesn't have to wait for the engine to spin
  /// down between toggles.
  ///
  /// Returns false if the native side rejects the request (permissions
  /// denied, no L2CAP link, AudioRecord init failure) or if the platform
  /// call throws. Logs the failure; callers are responsible for any
  /// user-visible error handling. Does not retry.
  Future<bool> startVoice() async {
    try {
      final result = await _methodChannel.invokeMethod('startVoice');
      return result == true;
    } catch (e) {
      debugPrint('Error starting voice: $e');
      return false;
    }
  }

  /// Tear down voice capture and streaming. Counterpart to [startVoice];
  /// safe to call when voice isn't running (the native side resolves it as
  /// a no-op rather than throwing).
  Future<bool> stopVoice() async {
    try {
      final result = await _methodChannel.invokeMethod('stopVoice');
      return result == true;
    } catch (e) {
      debugPrint('Error stopping voice: $e');
      return false;
    }
  }

  /// Set the local mic mute flag at the native layer. Mute does **not**
  /// tear down the L2CAP CoC or the AudioRecord — it just gates whether
  /// captured frames are encoded and sent. Keeping the engine warm makes
  /// unmute instant; tearing it down would round-trip through codec init
  /// every time the user taps the button.
  ///
  /// Wire-protocol implication: emitting a `mute` control message on the
  /// REQUEST characteristic is the *cubit's* job (so the host can echo it
  /// to the rest of the roster); this method only affects the local audio
  /// path. They're called together from the room screen.
  Future<bool> setMuted(bool muted) async {
    try {
      final result = await _methodChannel.invokeMethod('setMuted', {
        'muted': muted,
      });
      return result == true;
    } catch (e) {
      debugPrint('Error setting mute state: $e');
      return false;
    }
  }

  /// Get list of connected devices
  Future<List<Map<String, String>>> getConnectedDevices() async {
    try {
      final result = await _methodChannel.invokeMethod('getConnectedDevices');
      final List<dynamic> devices = result as List<dynamic>;
      return devices.map((device) {
        final Map<dynamic, dynamic> deviceMap = device as Map<dynamic, dynamic>;
        return {
          'address': deviceMap['address'] as String,
          'name': deviceMap['name'] as String,
        };
      }).toList();
    } catch (e) {
      debugPrint('Error getting connected devices: $e');
      return [];
    }
  }

  /// Stream of audio events from native layer
  Stream<Map<String, dynamic>> get audioEvents {
    _eventStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((event) {
          if (event == null) return <String, dynamic>{};
          return Map<String, dynamic>.from(event as Map);
        })
        .handleError((error) {
          debugPrint('Audio event stream error: $error');
          return <String, dynamic>{};
        });
    return _eventStream!;
  }

  /// Stream of peer IDs that are currently transmitting audio.
  ///
  /// The sentinel `'local'` represents this device's mic. Remote peers will
  /// be added once BLE audio transport is wired up. The room screen uses this
  /// to drive the talking VU rings for remote peers; the local user's ring is
  /// derived from the mute state directly.
  Stream<Set<String>> get talkingPeers {
    return audioEvents
        .where((e) => e['type'] == 'talkingPeers')
        .map((e) {
          final raw = e['peers'];
          if (raw is List) {
            return Set<String>.from(raw.map((p) => p.toString()));
          }
          return <String>{};
        });
  }
}
