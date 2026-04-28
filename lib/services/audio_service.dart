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
  static const EventChannel _controlBytesEventChannel = EventChannel(
    'com.elodin.walkie_talkie/control_bytes',
  );

  Stream<Map<String, dynamic>>? _eventStream;
  Stream<Map<String, dynamic>>? _controlBytesStream;

  /// Start the foreground service. Pass [freq] to show the active frequency
  /// in the notification ("On 104.3 · Tap to return").
  Future<bool> startService({String? freq}) async {
    try {
      final result = await _methodChannel.invokeMethod(
        'startService',
        freq != null ? <String, dynamic>{'freq': freq} : null,
      );
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

  /// Set the audio output routing for the voice stream.
  ///
  /// Routes the mixed audio output to the specified device type:
  /// - "bluetooth": Bluetooth headsets (AirPods, earbuds, etc.)
  /// - "earpiece": Phone's built-in earpiece (held to ear)
  /// - "speaker": Phone's speaker (loud, everyone nearby hears)
  ///
  /// The native layer auto-detects when Bluetooth devices connect/disconnect
  /// and routes accordingly, but this method allows manual override.
  ///
  /// Returns true if routing was successfully configured, false if the
  /// requested device type is unavailable or if the platform call fails.
  Future<bool> setAudioOutput(String output) async {
    try {
      final result = await _methodChannel.invokeMethod('setAudioOutput', {
        'output': output,
      });
      return result == true;
    } catch (e) {
      debugPrint('Error setting audio output to $output: $e');
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

  /// Stream of peer IDs currently transmitting voice.
  ///
  /// Emits a new set whenever the native mixer detects voice activity changes
  /// (peers starting or stopping transmission). The set contains peer IDs of
  /// all currently talking peers, or is empty when no one is transmitting.
  ///
  /// Filters audioEvents for 'talkingPeers' events and extracts the peer list.
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

  /// Stream of local voice-activity state changes from the native VAD.
  ///
  /// Emits `true` when the local microphone crosses the RMS threshold with
  /// the configured on-hysteresis (~100 ms), and `false` when it falls back
  /// below threshold with the off-hysteresis (~300 ms). Does not emit during
  /// muted periods — the engine zeros the mic buffer when muted.
  ///
  /// The cubit subscribes and sends [TalkingState] over the transport so
  /// remote peers can update their talking ring indicator.
  Stream<bool> get localTalking {
    return audioEvents
        .where((e) => e['type'] == 'localTalking')
        .map((e) => e['talking'] == true);
  }

  /// Start the GATT server for the host.
  ///
  /// Exposes REQUEST (write) and RESPONSE (notify) characteristics over
  /// the walkie-talkie service UUID. Guests write JoinRequest / MediaCommand /
  /// Leave messages to REQUEST; the host emits JoinAccepted / RosterUpdate /
  /// Heartbeat messages via RESPONSE notifications.
  ///
  /// Returns true if the GATT server started successfully, false otherwise.
  Future<bool> startGattServer() async {
    try {
      final result = await _methodChannel.invokeMethod('startGattServer');
      return result == true;
    } catch (e) {
      debugPrint('Error starting GATT server: $e');
      return false;
    }
  }

  /// Stop the GATT server.
  Future<bool> stopGattServer() async {
    try {
      final result = await _methodChannel.invokeMethod('stopGattServer');
      return result == true;
    } catch (e) {
      debugPrint('Error stopping GATT server: $e');
      return false;
    }
  }

  /// Send a notification to a connected GATT client.
  ///
  /// Writes bytes to the RESPONSE characteristic for the specified device.
  /// Used by the host to send JoinAccepted, RosterUpdate, Heartbeat, etc.
  /// to guests.
  ///
  /// Returns true if the notification was queued successfully, false otherwise.
  Future<bool> writeNotification(String deviceAddress, List<int> bytes) async {
    try {
      final result = await _methodChannel.invokeMethod('writeNotification', {
        'deviceAddress': deviceAddress,
        'bytes': bytes,
      });
      return result == true;
    } catch (e) {
      debugPrint('Error writing notification to $deviceAddress: $e');
      return false;
    }
  }

  /// Stream of control-plane byte fragments from the native GATT layer.
  ///
  /// On the host side, each event carries bytes written to the REQUEST
  /// characteristic by a connected guest. On the guest side, bytes arrive
  /// via RESPONSE notifications from the host. The [BleControlTransport]
  /// reassembles fragments and decodes complete [FrequencyMessage]s.
  ///
  /// Malformed events (missing `endpointId` or `bytes` fields) are silently
  /// dropped before reaching the transport layer.
  Stream<({String endpointId, Uint8List bytes})> get controlBytes {
    _controlBytesStream ??= _controlBytesEventChannel
        .receiveBroadcastStream()
        .map((event) {
          if (event == null) return <String, dynamic>{};
          return Map<String, dynamic>.from(event as Map);
        })
        .handleError((error) {
          debugPrint('Control bytes event stream error: $error');
          return <String, dynamic>{};
        });
    return _controlBytesStream!
        .where((e) => e['endpointId'] is String && e['bytes'] != null)
        .map((e) {
          final raw = e['bytes'];
          final bytes = raw is Uint8List
              ? raw
              : Uint8List.fromList((raw as List).cast<int>());
          return (endpointId: e['endpointId'] as String, bytes: bytes);
        });
  }

  /// Write [bytes] to the GATT control plane.
  ///
  /// On the guest side this writes to the host's REQUEST characteristic.
  /// Failures are logged and swallowed — the transport layer decides on
  /// retry / teardown.
  Future<void> writeControlBytes(Uint8List bytes) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'writeControlBytes',
        <String, dynamic>{'bytes': bytes},
      );
    } catch (e) {
      debugPrint('Error writing control bytes: $e');
    }
  }
}
