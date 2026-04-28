import 'dart:async';

import 'audio_service.dart';

/// Drives the guest-side exponential-backoff reconnect loop after a transient
/// BLE drop. Call [attempt] once a drop is detected; cancel with [cancel] if
/// the user manually leaves the room before the loop completes.
///
/// The six delay steps give a total worst-case budget of ~19 s — designed to
/// complete before the host's heartbeat window (15 s + 5 s grace) purges the
/// peer. Coordinate with the heartbeat implementation: the host should NOT
/// purge a peer whose last heartbeat arrived ≤ 5 s before the silence began.
class ReconnectController {
  static const List<Duration> delays = [
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];

  final AudioService _audio;
  final List<Duration> _delays;
  bool _cancelled = false;

  ReconnectController({required AudioService audio, List<Duration>? delays})
      : _audio = audio,
        _delays = delays ?? ReconnectController.delays;

  /// Attempt to reconnect to [macAddress], retrying up to [delays.length]
  /// times with exponential backoff. Returns `true` if the BLE connection is
  /// re-established, `false` if all retries are exhausted or [cancel] was
  /// called.
  Future<bool> attempt({required String macAddress}) async {
    _cancelled = false;
    for (final delay in _delays) {
      if (_cancelled) return false;
      await Future.delayed(delay);
      if (_cancelled) return false;
      try {
        if (await _audio.connectDevice(macAddress)) return true;
      } catch (_) {
        // Native errors are already logged inside AudioService; treat as a
        // failed attempt and continue to the next retry.
        continue;
      }
    }
    return false;
  }

  /// Signals the in-progress [attempt] to stop after its current delay.
  /// Safe to call after [attempt] has already completed.
  void cancel() => _cancelled = true;
}
