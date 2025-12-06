import 'package:flutter/services.dart';

/// Service for communicating with native Android audio layer
class AudioService {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.elodin.walkie_talkie/audio',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.elodin.walkie_talkie/audio_events',
  );

  /// Start the foreground service
  Future<bool> startService() async {
    try {
      final result = await _methodChannel.invokeMethod('startService');
      return result as bool;
    } catch (e) {
      print('Error starting service: $e');
      return false;
    }
  }

  /// Stop the foreground service
  Future<bool> stopService() async {
    try {
      final result = await _methodChannel.invokeMethod('stopService');
      return result as bool;
    } catch (e) {
      print('Error stopping service: $e');
      return false;
    }
  }

  /// Start scanning for Bluetooth LE Audio devices
  Future<void> startScan() async {
    try {
      await _methodChannel.invokeMethod('scanDevices');
    } catch (e) {
      print('Error scanning devices: $e');
      rethrow;
    }
  }

  /// Stop scanning
  Future<void> stopScan() async {
    // TODO: Implement stop scan in native layer
  }

  /// Connect to a Bluetooth device
  Future<void> connectDevice(String macAddress) async {
    try {
      await _methodChannel.invokeMethod('connectDevice', {
        'macAddress': macAddress,
      });
    } catch (e) {
      print('Error connecting to device: $e');
      rethrow;
    }
  }

  /// Disconnect from a Bluetooth device
  Future<void> disconnectDevice(String macAddress) async {
    try {
      await _methodChannel.invokeMethod('disconnectDevice', {
        'macAddress': macAddress,
      });
    } catch (e) {
      print('Error disconnecting from device: $e');
      rethrow;
    }
  }

  /// Stream of audio events from native layer
  Stream<dynamic> get audioEvents => _eventChannel.receiveBroadcastStream();
}
