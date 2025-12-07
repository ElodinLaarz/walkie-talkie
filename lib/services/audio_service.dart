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
}
