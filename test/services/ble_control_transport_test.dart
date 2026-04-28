import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/framing.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/protocol/peer.dart';
import 'package:walkie_talkie/services/ble_control_transport.dart';

// Helper: build a minimal JoinRequest for encoding/decoding tests.
JoinRequest _joinRequest({String peerId = 'peer-a', int seq = 1}) =>
    JoinRequest(
      peerId: peerId,
      seq: seq,
      atMs: 1000,
      displayName: 'Alice',
    );

// Helper: build a minimal Heartbeat.
Heartbeat _heartbeat({String peerId = 'peer-a', int seq = 1}) => Heartbeat(
      peerId: peerId,
      seq: seq,
      atMs: 1000,
    );

// Helper: encode a message into fragments and inject them into the stream.
void _injectMessage(
  StreamController<({String endpointId, Uint8List bytes})> controller,
  FrequencyMessage msg, {
  String endpointId = 'ep-1',
}) {
  for (final frag in encodeFragments(msg.encode())) {
    controller.add((endpointId: endpointId, bytes: frag));
  }
}

void main() {
  group('BleControlTransport', () {
    late StreamController<({String endpointId, Uint8List bytes})>
        controlBytesController;
    late List<Uint8List> writtenBytes;
    late BleControlTransport transport;

    setUp(() {
      controlBytesController = StreamController.broadcast();
      writtenBytes = [];
      transport = BleControlTransport.forTest(
        controlBytes: controlBytesController.stream,
        writeBytes: (bytes) async => writtenBytes.add(bytes),
      );
    });

    tearDown(() {
      transport.dispose();
      controlBytesController.close();
    });

    group('send', () {
      test('encodes a single-fragment message and calls writeBytes once',
          () async {
        final msg = _heartbeat();
        await transport.send(msg);

        expect(writtenBytes, hasLength(1));
        // The fragment must decode back to the same message.
        final reassembler = FragmentReassembler();
        final json = reassembler.feed(writtenBytes.first);
        expect(json, isNotNull);
        final decoded = FrequencyMessage.decode(json!);
        expect(decoded, isA<Heartbeat>());
        expect(decoded.peerId, msg.peerId);
        expect(decoded.seq, msg.seq);
      });

      test('writes multiple fragments for a large message', () async {
        // Build a roster big enough to force fragmentation (>243 bytes JSON).
        final roster = List.generate(
          15,
          (i) => ProtocolPeer(
            peerId: 'peer-$i-very-long-uuid-string-here-abcdef',
            displayName: 'User $i with a somewhat long display name',
          ),
        );
        final msg = JoinAccepted(
          peerId: 'host-peer',
          seq: 1,
          atMs: 1000,
          hostPeerId: 'host-peer',
          roster: roster,
        );

        await transport.send(msg);

        expect(writtenBytes.length, greaterThan(1));

        // Reassemble and verify round-trip.
        final reassembler = FragmentReassembler();
        String? json;
        for (final frag in writtenBytes) {
          json = reassembler.feed(frag);
        }
        expect(json, isNotNull);
        final decoded = FrequencyMessage.decode(json!) as JoinAccepted;
        expect(decoded.roster, hasLength(15));
      });
    });

    group('receive', () {
      test('emits a fully-assembled message on incoming', () async {
        final msg = _joinRequest();
        final emitted = <FrequencyMessage>[];
        final sub = transport.incoming.listen(emitted.add);

        _injectMessage(controlBytesController, msg);
        await Future<void>.delayed(Duration.zero);

        expect(emitted, hasLength(1));
        expect(emitted.first, isA<JoinRequest>());
        expect(emitted.first.seq, 1);
        await sub.cancel();
      });

      test('reassembles a multi-fragment message into one emission', () async {
        final roster = List.generate(
          15,
          (i) => ProtocolPeer(
            peerId: 'peer-$i-very-long-uuid-string-here-abcdef',
            displayName: 'User $i with a somewhat long display name',
          ),
        );
        final msg = JoinAccepted(
          peerId: 'host-peer',
          seq: 1,
          atMs: 1000,
          hostPeerId: 'host-peer',
          roster: roster,
        );

        final emitted = <FrequencyMessage>[];
        final sub = transport.incoming.listen(emitted.add);

        _injectMessage(controlBytesController, msg);
        await Future<void>.delayed(Duration.zero);

        expect(emitted, hasLength(1));
        expect((emitted.first as JoinAccepted).roster, hasLength(15));
        await sub.cancel();
      });

      test('drops a duplicate seq from the same peer', () async {
        final emitted = <FrequencyMessage>[];
        final sub = transport.incoming.listen(emitted.add);

        _injectMessage(controlBytesController, _heartbeat(seq: 1));
        _injectMessage(controlBytesController, _heartbeat(seq: 1));
        _injectMessage(controlBytesController, _heartbeat(seq: 2));
        await Future<void>.delayed(Duration.zero);

        expect(emitted, hasLength(2));
        expect(emitted[0].seq, 1);
        expect(emitted[1].seq, 2);
        await sub.cancel();
      });

      test('tracks seq independently per peer endpoint', () async {
        final emitted = <FrequencyMessage>[];
        final sub = transport.incoming.listen(emitted.add);

        _injectMessage(
          controlBytesController,
          _heartbeat(peerId: 'peer-a', seq: 1),
          endpointId: 'ep-a',
        );
        _injectMessage(
          controlBytesController,
          _heartbeat(peerId: 'peer-b', seq: 1),
          endpointId: 'ep-b',
        );
        await Future<void>.delayed(Duration.zero);

        // Both seq=1 messages should pass because they're from different peers.
        expect(emitted, hasLength(2));
        await sub.cancel();
      });

      test('drops a malformed fragment without crashing', () async {
        final emitted = <FrequencyMessage>[];
        final sub = transport.incoming.listen(emitted.add);

        // Too short to be a valid fragment (< 4 byte header).
        controlBytesController.add((
          endpointId: 'ep-1',
          bytes: Uint8List.fromList([0x00, 0x01]),
        ));
        // A valid message after the bad one should still arrive.
        _injectMessage(controlBytesController, _heartbeat(seq: 1));
        await Future<void>.delayed(Duration.zero);

        expect(emitted, hasLength(1));
        await sub.cancel();
      });

      test('drops a message with invalid JSON without crashing', () async {
        final emitted = <FrequencyMessage>[];
        final sub = transport.incoming.listen(emitted.add);

        // Manually craft a "complete" fragment with invalid JSON.
        final badPayload = 'not-valid-json!!!';
        final badBytes = badPayload.codeUnits;
        final frag = Uint8List(kFragmentHeaderSize + badBytes.length)
          ..[0] = kFragmentFlagsV1
          ..[1] = (badBytes.length >> 8) & 0xFF
          ..[2] = badBytes.length & 0xFF
          ..[3] = 0;
        frag.setRange(kFragmentHeaderSize, frag.length, badBytes);
        controlBytesController.add((endpointId: 'ep-1', bytes: frag));

        // Valid message after the bad one must still arrive.
        _injectMessage(controlBytesController, _heartbeat(seq: 1));
        await Future<void>.delayed(Duration.zero);

        expect(emitted, hasLength(1));
        await sub.cancel();
      });
    });

    group('forgetPeer', () {
      test('resets the seq watermark so a reconnecting peer is accepted',
          () async {
        final emitted = <FrequencyMessage>[];
        final sub = transport.incoming.listen(emitted.add);

        // Advance the watermark to seq=5.
        for (var i = 1; i <= 5; i++) {
          _injectMessage(
            controlBytesController,
            _heartbeat(peerId: 'peer-a', seq: i),
          );
        }
        await Future<void>.delayed(Duration.zero);
        expect(emitted, hasLength(5));

        // Forget the peer (simulating a reconnect).
        transport.forgetPeer('peer-a');

        // A fresh session starts at seq=1 — should be accepted.
        _injectMessage(
          controlBytesController,
          _heartbeat(peerId: 'peer-a', seq: 1),
        );
        await Future<void>.delayed(Duration.zero);

        expect(emitted, hasLength(6));
        await sub.cancel();
      });
    });
  });
}
