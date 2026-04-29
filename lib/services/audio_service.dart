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

  /// Stream of local voice activity detection events.
  ///
  /// Emits true when the native audio engine detects voice activity above the
  /// threshold (RMS > -40 dBFS), false when activity drops below threshold.
  /// Includes hysteresis (100ms to flip on, 300ms to flip off) to avoid
  /// flickering at the threshold boundary.
  ///
  /// Filters audioEvents for 'localTalking' events from the native layer.
  Stream<bool> get localTalking {
    return audioEvents
        .where((e) => e['type'] == 'localTalking')
        .map((e) => e['talking'] == true);
  }

  /// Start LE advertising for the host.
  ///
  /// Broadcasts the walkie-talkie service UUID plus a 16-byte manufacturer
  /// payload that encodes the protocol version, role, and low 8 bytes of
  /// [sessionUuid] (see [docs/protocol.md] § "Bluetooth LE advertising").
  /// Other phones running the discovery service pick this up and surface
  /// the host as a tunable frequency.
  ///
  /// [displayName] is included in the advertisement (LE device-name field)
  /// so the discovery row can render the host's name without an extra
  /// GATT round-trip. [sessionUuid] is the canonical full UUID minted by
  /// the host on session start; the advertiser truncates it to the low
  /// 8 bytes per the wire spec.
  ///
  /// Returns true if advertising started successfully, false otherwise.
  /// The native implementation lands in issue #41; until then this is a
  /// no-op stub on the platform side.
  Future<bool> startAdvertising({
    required String sessionUuid,
    required String displayName,
  }) async {
    try {
      final result = await _methodChannel.invokeMethod('startAdvertising', {
        'sessionUuid': sessionUuid,
        'displayName': displayName,
      });
      return result == true;
    } catch (e) {
      debugPrint('Error starting advertising: $e');
      return false;
    }
  }

  /// Stop LE advertising. Counterpart to [startAdvertising]; safe to call
  /// when advertising isn't running (the native side resolves it as a
  /// no-op rather than throwing).
  Future<bool> stopAdvertising() async {
    try {
      final result = await _methodChannel.invokeMethod('stopAdvertising');
      return result == true;
    } catch (e) {
      debugPrint('Error stopping advertising: $e');
      return false;
    }
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

  /// Snapshot the current RSSI for each peer connected over the GATT
  /// link. Returns one entry per neighbor `(peerId, rssi)`; `rssi` is in
  /// dBm (negative values; closer to 0 is stronger). Empty list when no
  /// peers are connected, the native side hasn't wired up
  /// `BluetoothGatt.readRemoteRssi` yet, or the platform call throws.
  ///
  /// Used by [SignalReporter] on the guest side to build the protocol's
  /// 10-second `SignalReport` envelope.
  ///
  /// **Note on `peerId`.** The native layer keys connections by Bluetooth
  /// MAC, not by application-level `peerId`. The current contract is that
  /// the native side returns the MAC as the `peerId` field; mapping MAC
  /// back to the application `peerId` will land alongside the GATT-client
  /// issue (#43) which records that mapping during the handshake. Until
  /// then, the host side treats the value as opaque — its detection logic
  /// keys on whatever string arrives. Reports for `peerId`s the host
  /// can't resolve against its current roster are dropped before
  /// surfacing a toast (see `_onSignalReport` in `FrequencySessionCubit`).
  Future<List<({String peerId, int rssi})>> getCurrentRssi() async {
    try {
      final result =
          await _methodChannel.invokeMethod<List<dynamic>>('getCurrentRssi');
      if (result == null) return const [];
      return result
          .map((entry) {
            // Type-check before casting — a non-Map element from the
            // platform side would otherwise throw, and the outer
            // try/catch would discard the *entire* batch (including
            // valid samples). Drop just the bad entry instead.
            if (entry is! Map) return null;
            final peerId = entry['peerId'];
            final rssi = entry['rssi'];
            if (peerId is! String || rssi is! int) return null;
            return (peerId: peerId, rssi: rssi);
          })
          .whereType<({String peerId, int rssi})>()
          .toList(growable: false);
    } catch (e) {
      debugPrint('Error getting current RSSI: $e');
      return const [];
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

  /// Start an L2CAP CoC server socket for the voice plane.
  ///
  /// Returns the dynamically assigned PSM (odd, in [0x0080, 0x00FF]) on
  /// success, or null if the native layer could not open the socket (e.g.
  /// Bluetooth is off or the OEM rejects the call). The returned PSM is
  /// the value that should be published in the [JoinAccepted.voicePsm]
  /// field so guests can dial the voice channel.
  Future<int?> startVoiceServer() async {
    try {
      final result = await _methodChannel.invokeMethod<int>('startVoiceServer');
      return result;
    } catch (e) {
      debugPrint('Error starting voice server: $e');
      return null;
    }
  }

  /// Connect the voice plane as a guest to [macAddress] on [psm].
  ///
  /// Runs on a background thread with exponential backoff (up to ~8 s total).
  /// Returns true if the L2CAP channel was established, false if all retries
  /// exhausted or the native layer is unavailable. A false result should be
  /// treated as non-fatal — the control plane stays up and the user can see a
  /// degraded-voice toast; see the known risks in issue #46.
  Future<bool> connectVoiceClient(String macAddress, int psm) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'connectVoiceClient',
        <String, dynamic>{'macAddress': macAddress, 'psm': psm},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error connecting voice client: $e');
      return false;
    }
  }

  /// Tear down the L2CAP voice transport (both server and client).
  /// Safe to call when the transport is not running.
  Future<bool> stopVoiceTransport() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('stopVoiceTransport');
      return result == true;
    } catch (e) {
      debugPrint('Error stopping voice transport: $e');
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

  /// Connect to the host's GATT server as a guest.
  ///
  /// Initiates a GATT connection to [macAddress], discovers the walkie-talkie
  /// service, and enables notifications on the RESPONSE characteristic. Once
  /// connected, the guest can write protocol messages via [writeRequest] and
  /// receive host responses via the [controlBytes] stream.
  ///
  /// Returns true if the connection attempt was initiated, false otherwise.
  /// Actual connection state changes are reported through the audioEvents stream.
  Future<bool> connectToHost(String macAddress) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'connectToHost',
        <String, dynamic>{'macAddress': macAddress},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error connecting to host: $e');
      return false;
    }
  }

  /// Disconnect from the host's GATT server.
  ///
  /// Tears down the GATT connection established via [connectToHost].
  /// Safe to call when not connected (the native side resolves it as a no-op).
  Future<bool> disconnectFromHost() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('disconnectFromHost');
      return result == true;
    } catch (e) {
      debugPrint('Error disconnecting from host: $e');
      return false;
    }
  }

  /// Write bytes to the host's REQUEST characteristic.
  ///
  /// Used by guests to send JoinRequest, MediaCommand, Leave, etc. to the host.
  /// The connection must be established via [connectToHost] before calling this.
  ///
  /// Returns true if the write was queued successfully, false otherwise.
  Future<bool> writeRequest(Uint8List bytes) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'writeRequest',
        <String, dynamic>{'bytes': bytes},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error writing request: $e');
      return false;
    }
  }
}
