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

    tearDown(() async {
      transport.dispose();
      await controlBytesController.close();
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

    group('MTU-aware send', () {
      // Custom transport per-test so each test can wire its own MTU oracle.
      late StreamController<({String endpointId, Uint8List bytes})> mtuController;
      late List<Uint8List> mtuWritten;

      setUp(() {
        mtuController = StreamController.broadcast();
        mtuWritten = [];
      });

      tearDown(() async {
        await mtuController.close();
      });

      test('does not consult the MTU oracle when no active endpoint is set',
          () async {
        var mtuCalls = 0;
        final t = BleControlTransport.forTest(
          controlBytes: mtuController.stream,
          writeBytes: (bytes) async => mtuWritten.add(bytes),
          getMtu: (_) async {
            mtuCalls++;
            return 100;
          },
        );

        await t.send(_heartbeat());

        // Without setActiveEndpoint, the oracle is never consulted and the
        // encoder uses kMaxFragmentSize. Heartbeat is small enough to land
        // in a single fragment regardless.
        expect(mtuCalls, 0);
        expect(mtuWritten, hasLength(1));
        // The single fragment was sized against kMaxFragmentSize, not the
        // smaller MTU 100.
        expect(mtuWritten.first.length, lessThanOrEqualTo(kMaxFragmentSize));
        t.dispose();
      });

      test('queries MTU for the active endpoint and sizes fragments accordingly',
          () async {
        var queriedFor = <String>[];
        final t = BleControlTransport.forTest(
          controlBytes: mtuController.stream,
          writeBytes: (bytes) async => mtuWritten.add(bytes),
          getMtu: (endpointId) async {
            queriedFor.add(endpointId);
            return 100; // Force smaller fragments.
          },
        );
        t.setActiveEndpoint('host-mac-1');

        final msg = JoinAccepted(
          peerId: 'host',
          seq: 1,
          atMs: 1000,
          hostPeerId: 'host',
          roster: List.generate(
            12,
            (i) => ProtocolPeer(
              peerId: 'p$i-long-uuid-string-padding-here',
              displayName: 'User $i with a longer display name',
            ),
          ),
        );

        await t.send(msg);

        expect(queriedFor, ['host-mac-1']);
        // MTU 100 → fragment ceiling 97. Every fragment except the last
        // must be exactly 97 bytes (header + payload).
        expect(mtuWritten.length, greaterThan(1));
        for (final f in mtuWritten.take(mtuWritten.length - 1)) {
          expect(f.length, 97, reason: 'mid-stream fragment must be exactly mtu-3');
        }
        // Last fragment is the remainder; must be ≤ 97.
        expect(mtuWritten.last.length, lessThanOrEqualTo(97));

        // Reassemble end-to-end and verify identity.
        final r = FragmentReassembler();
        String? json;
        for (final f in mtuWritten) {
          json = r.feed(f);
        }
        expect(json, isNotNull);
        final decoded = FrequencyMessage.decode(json!) as JoinAccepted;
        expect(decoded.roster, hasLength(12));
        t.dispose();
      });

      test('falls back to kMaxFragmentSize when oracle returns null', () async {
        final t = BleControlTransport.forTest(
          controlBytes: mtuController.stream,
          writeBytes: (bytes) async => mtuWritten.add(bytes),
          getMtu: (_) async => null,
        );
        t.setActiveEndpoint('host-mac-1');

        await t.send(_heartbeat());

        // Single small message → single fragment regardless. The point is
        // it doesn't throw and writeBytes is still invoked.
        expect(mtuWritten, hasLength(1));
        t.dispose();
      });

      test('aborts the send when MTU is below kMinControlMtu', () async {
        final t = BleControlTransport.forTest(
          controlBytes: mtuController.stream,
          writeBytes: (bytes) async => mtuWritten.add(bytes),
          getMtu: (_) async => kMinControlMtu - 1, // 63: just below floor.
        );
        t.setActiveEndpoint('host-mac-1');

        await t.send(_heartbeat());

        // Nothing reached the wire — the aborted send leaves the link
        // intact for the caller to tear down (or wait out).
        expect(mtuWritten, isEmpty);
        t.dispose();
      });

      test('exactly kMinControlMtu allows the send through', () async {
        final t = BleControlTransport.forTest(
          controlBytes: mtuController.stream,
          writeBytes: (bytes) async => mtuWritten.add(bytes),
          getMtu: (_) async => kMinControlMtu,
        );
        t.setActiveEndpoint('host-mac-1');

        await t.send(_heartbeat());

        // At least one fragment hit the wire, none above the budget
        // (mtu - att header = 61).
        expect(mtuWritten, isNotEmpty);
        final budget = kMinControlMtu - kAttHeaderOverhead;
        for (final f in mtuWritten) {
          expect(f.length, lessThanOrEqualTo(budget));
        }
        // Round-trip survives the small fragments.
        final r = FragmentReassembler();
        String? json;
        for (final f in mtuWritten) {
          json = r.feed(f);
        }
        expect(json, isNotNull);
        expect(FrequencyMessage.decode(json!), isA<Heartbeat>());
        t.dispose();
      });

      test('high MTU (>247) is clamped to kMaxFragmentSize', () async {
        // Some link layers report an inflated MTU; we must not request a
        // fragment size above the v1 ceiling regardless.
        final t = BleControlTransport.forTest(
          controlBytes: mtuController.stream,
          writeBytes: (bytes) async => mtuWritten.add(bytes),
          getMtu: (_) async => 512,
        );
        t.setActiveEndpoint('host-mac-1');

        // Build a message larger than one 247-byte fragment so we can
        // observe the cap.
        final big = JoinAccepted(
          peerId: 'host',
          seq: 1,
          atMs: 1000,
          hostPeerId: 'host',
          roster: List.generate(
            15,
            (i) => ProtocolPeer(
              peerId: 'p$i-very-long-uuid-here-padding-padding',
              displayName: 'User $i with a longer display name',
            ),
          ),
        );

        await t.send(big);

        for (final f in mtuWritten) {
          expect(f.length, lessThanOrEqualTo(kMaxFragmentSize));
        }
        t.dispose();
      });

      test('clearing the active endpoint reverts to default fragmentation',
          () async {
        var calls = 0;
        final t = BleControlTransport.forTest(
          controlBytes: mtuController.stream,
          writeBytes: (bytes) async => mtuWritten.add(bytes),
          getMtu: (_) async {
            calls++;
            return 64;
          },
        );

        t.setActiveEndpoint('host-mac-1');
        await t.send(_heartbeat(seq: 1));
        expect(calls, 1);

        t.setActiveEndpoint(null);
        await t.send(_heartbeat(seq: 2));
        // No further oracle calls after clearing the binding.
        expect(calls, 1);
        expect(t.activeEndpoint, isNull);
        t.dispose();
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

      test('forgetAllPeers clears every peer\'s watermark + reassembler',
          () async {
        // Wipe-the-slate-clean variant for the leaveRoom path: held-over
        // watermarks from an old session must not silently swallow `seq=1`
        // of the next session.
        final emitted = <FrequencyMessage>[];
        final sub = transport.incoming.listen(emitted.add);

        // Advance watermarks for two distinct peers.
        _injectMessage(controlBytesController,
            _heartbeat(peerId: 'peer-a', seq: 5));
        _injectMessage(controlBytesController,
            _heartbeat(peerId: 'peer-b', seq: 3));
        await Future<void>.delayed(Duration.zero);
        expect(emitted, hasLength(2));

        transport.forgetAllPeers();

        // Both peers' fresh sessions start at seq=1; both should land.
        _injectMessage(controlBytesController,
            _heartbeat(peerId: 'peer-a', seq: 1));
        _injectMessage(controlBytesController,
            _heartbeat(peerId: 'peer-b', seq: 1));
        await Future<void>.delayed(Duration.zero);

        expect(emitted, hasLength(4));
        await sub.cancel();
      });

      test('cleans up the reassembler via endpointId mapping on reconnect',
          () async {
        final emitted = <FrequencyMessage>[];
        final sub = transport.incoming.listen(emitted.add);

        // Feed a fragment that does NOT complete a message — leaves state in
        // the reassembler for 'ep-1'.
        final partialFragments = encodeFragments(_joinRequest().encode());
        // Only inject the first fragment so reassembler has pending state.
        controlBytesController
            .add((endpointId: 'ep-1', bytes: partialFragments.first));
        await Future<void>.delayed(Duration.zero);

        // First we need a complete message to build the peerId→endpointId map.
        _injectMessage(controlBytesController, _heartbeat(seq: 1));
        await Future<void>.delayed(Duration.zero);
        expect(emitted, hasLength(1));

        // After forgetPeer, the reassembler for 'ep-1' is cleared. A new
        // fragment starting from idx=0 must be accepted (not treated as a
        // continuation of the earlier partial message).
        transport.forgetPeer('peer-a');

        _injectMessage(
          controlBytesController,
          _heartbeat(peerId: 'peer-a', seq: 1),
        );
        await Future<void>.delayed(Duration.zero);

        // seq=1 from 'peer-a' is accepted again after forgetPeer.
        expect(emitted, hasLength(2));
        await sub.cancel();
      });
    });
  });
}
