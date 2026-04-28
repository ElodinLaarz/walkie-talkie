import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../protocol/framing.dart';
import '../protocol/messages.dart';
import '../protocol/sequence_filter.dart';
import 'audio_service.dart';

/// Bridges the Frequency wire protocol to the native GATT byte streams.
///
/// **Send side.** [send] serialises a [FrequencyMessage] to JSON, splits it
/// into ≤247-byte GATT fragments via [encodeFragments], and writes each one
/// to the native layer sequentially via `writeControlBytes`.
///
/// **Receive side.** Raw byte fragments arrive through the injected
/// `controlBytes` stream, keyed by the remote endpoint id. Each fragment is
/// fed to the [FragmentReassembler] for that endpoint. When a message
/// assembles, [FrequencyMessage.decode] parses it, the [SequenceFilter]
/// drops duplicates, and the message is emitted on [incoming].
///
/// Fragment errors and JSON parse errors are logged and dropped — the
/// underlying connection stays up.
class BleControlTransport {
  final Future<void> Function(Uint8List bytes) _writeBytes;
  final SequenceFilter _filter = SequenceFilter();
  final Map<String, FragmentReassembler> _reassemblers = {};
  final StreamController<FrequencyMessage> _incoming =
      StreamController<FrequencyMessage>.broadcast();

  late final StreamSubscription<({String endpointId, Uint8List bytes})>
      _subscription;

  /// Fully-assembled, idempotency-filtered messages from the remote side.
  Stream<FrequencyMessage> get incoming => _incoming.stream;

  BleControlTransport(AudioService audio)
      : _writeBytes = audio.writeControlBytes {
    _subscription = audio.controlBytes.listen(_onControlBytes);
  }

  /// Test-only constructor. Inject a synthetic `controlBytes` stream and a
  /// write callback to exercise the transport without touching MethodChannels.
  @visibleForTesting
  BleControlTransport.forTest({
    required Stream<({String endpointId, Uint8List bytes})> controlBytes,
    required Future<void> Function(Uint8List bytes) writeBytes,
  }) : _writeBytes = writeBytes {
    _subscription = controlBytes.listen(_onControlBytes);
  }

  /// Serialise [msg] and write it as one or more GATT fragments.
  ///
  /// Fragments are written sequentially — each `writeControlBytes` call
  /// awaits before the next begins, matching the GATT write-without-response
  /// ordering contract.
  Future<void> send(FrequencyMessage msg) async {
    final fragments = encodeFragments(msg.encode());
    for (final f in fragments) {
      await _writeBytes(f);
    }
  }

  /// Drop the sequence-filter watermark and reassembler buffer for [peerId].
  ///
  /// Must be called on clean disconnect (Leave / RemovePeer flow) and on
  /// dirty-disconnect detection (heartbeat timeout) so a reconnecting peer's
  /// fresh `seq=1` is not swallowed by a stale watermark from the previous
  /// session.
  void forgetPeer(String peerId) {
    _filter.forget(peerId);
    _reassemblers.remove(peerId);
  }

  /// Cancel the native-bytes subscription and close [incoming].
  ///
  /// After dispose, [incoming] emits no further events. Call once during
  /// app lifecycle teardown.
  void dispose() {
    _subscription.cancel();
    _incoming.close();
  }

  void _onControlBytes(({String endpointId, Uint8List bytes}) event) {
    final r = _reassemblers.putIfAbsent(
      event.endpointId,
      FragmentReassembler.new,
    );
    try {
      final json = r.feed(event.bytes);
      if (json == null) return;
      final msg = FrequencyMessage.decode(json);
      if (!_filter.accept(peerId: msg.peerId, seq: msg.seq)) return;
      if (!_incoming.isClosed) _incoming.add(msg);
    } on FragmentError catch (e) {
      debugPrint('drop fragment from ${event.endpointId}: $e');
    } on FormatException catch (e) {
      debugPrint('drop message from ${event.endpointId}: $e');
    }
  }
}
