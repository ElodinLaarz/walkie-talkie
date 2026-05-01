import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/framing.dart';
import '../protocol/messages.dart';
import '../protocol/sequence_filter.dart';
import 'audio_service.dart';

/// Minimum ATT MTU the control plane requires before [BleControlTransport]
/// will emit fragments. Mirrors [`kVoiceMtu`](voice_frame.dart) for the voice
/// plane: a peer that negotiates below this is treated as a
/// version-mismatch and the send is aborted (per protocol § GATT service).
///
/// At MTU = 64 the per-fragment payload budget is `64 - 3 - 4 = 57` bytes
/// — enough to keep the worst-case roster under the v1 16-fragment ceiling
/// — but anything smaller starts pushing fragment counts into territory
/// where flaky OEM stacks reorder or drop writes.
const int kMinControlMtu = 64;

/// ATT opcode + handle bytes the link reserves before the GATT payload.
/// Subtracted from the negotiated MTU when sizing fragments so the link
/// doesn't refragment our writes unpredictably.
const int kAttHeaderOverhead = 3;

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
  final Future<int?> Function(String endpointId)? _getMtu;
  final SequenceFilter _filter = SequenceFilter();
  final Map<String, FragmentReassembler> _reassemblers = {};
  // Tracks peerId → endpointId so forgetPeer can clean up the right reassembler.
  // A peer's endpointId (BT MAC) differs from its peerId (application UUID);
  // this mapping is built lazily as messages arrive.
  final Map<String, String> _endpointByPeer = {};
  final StreamController<FrequencyMessage> _incoming =
      StreamController<FrequencyMessage>.broadcast();

  late final StreamSubscription<({String endpointId, Uint8List bytes})>
      _subscription;

  /// Endpoint the next [send] should size against. The cubit sets this
  /// to the host's BT MAC once a guest has connected; the host has no
  /// outbound use of [send] today (it writes notifications via
  /// `audio.writeNotification`), so the value stays null on that side.
  String? _activeEndpoint;

  /// Serialiser for [send]. Each call chains its body onto this future
  /// so concurrent senders never race their fragments onto the wire.
  ///
  /// Two unawaited `send` calls — common from VAD edges (see
  /// [FrequencySessionCubit] `_onLocalTalking`) and from the cubit's
  /// best-effort `_broadcastRosterUpdate` — would otherwise overlap
  /// inside [send]'s `await _writeBytes(f)` loop and let fragments
  /// belonging to different messages interleave on the wire. The
  /// receiver's [FragmentReassembler] would then either drop both
  /// (header mismatch) or splice them, and even for single-fragment
  /// messages the [SequenceFilter] would discard the older `seq` as
  /// out-of-order. This chain enforces strict serialisation on the
  /// wire — each `send` waits for the previous to fully drain before
  /// its first fragment goes out.
  ///
  /// Per-call errors are isolated: a failed send rejects only that
  /// caller's returned future, not the chain itself, so the next
  /// queued send still runs.
  Future<void> _sendChain = Future<void>.value();

  /// Fully-assembled, idempotency-filtered messages from the remote side.
  Stream<FrequencyMessage> get incoming => _incoming.stream;

  BleControlTransport(AudioService audio)
      : _writeBytes = audio.writeControlBytes,
        _getMtu = audio.getNegotiatedMtu {
    _subscription = audio.controlBytes.listen(_onControlBytes);
  }

  /// Test-only constructor. Inject a synthetic `controlBytes` stream and a
  /// write callback to exercise the transport without touching MethodChannels.
  ///
  /// [getMtu] is optional: if provided, [send] will query it for the active
  /// endpoint (set via [setActiveEndpoint]) and size fragments against the
  /// negotiated MTU. If omitted, [send] falls back to [kMaxFragmentSize].
  @visibleForTesting
  BleControlTransport.forTest({
    required Stream<({String endpointId, Uint8List bytes})> controlBytes,
    required Future<void> Function(Uint8List bytes) writeBytes,
    Future<int?> Function(String endpointId)? getMtu,
  })  : _writeBytes = writeBytes,
        _getMtu = getMtu {
    _subscription = controlBytes.listen(_onControlBytes);
  }

  /// Endpoint the transport should consult for MTU on subsequent sends.
  ///
  /// On the guest side, this is the host's BT MAC; the cubit calls it once
  /// the GATT-client connection is established. Pass null to clear the
  /// binding (e.g. on disconnect) and revert [send] to the default
  /// [kMaxFragmentSize].
  void setActiveEndpoint(String? endpointId) {
    _activeEndpoint = endpointId;
  }

  /// The endpoint [send] is currently sized against. Visible for tests and
  /// for the cubit's reconnect logic, which needs to know whether the
  /// transport has a live host binding before issuing the next write.
  String? get activeEndpoint => _activeEndpoint;

  /// Serialise [msg] and write it as one or more GATT fragments.
  ///
  /// Fragments are written sequentially — each `writeControlBytes` call
  /// awaits before the next begins, matching the GATT write-without-response
  /// ordering contract. Concurrent [send] calls are also serialised
  /// through [_sendChain]: a second caller's fragments wait for the
  /// previous send to fully drain before they go out, so two unawaited
  /// sends from different producers (e.g. VAD edges and roster updates)
  /// can't interleave on the wire.
  ///
  /// When an active endpoint is set (see [setActiveEndpoint]) and the
  /// transport has an MTU oracle wired, this queries the negotiated MTU
  /// per write and sizes fragments to `min(mtu - 3, kMaxFragmentSize)` so
  /// the link doesn't refragment writes. If the negotiated MTU is below
  /// [kMinControlMtu] the send aborts (logged + dropped) — mirroring the
  /// voice plane's `kVoiceMtu` floor and the protocol's
  /// "version-mismatch → disconnect" rule, without taking the link down
  /// unilaterally from the Dart side.
  ///
  /// When no endpoint is bound, no MTU oracle is wired, or the oracle
  /// returns null (no MTU observed yet), the encoder falls back to
  /// [kMaxFragmentSize] — the same behavior the transport had before MTU
  /// plumbing landed.
  ///
  /// Returns true when the message reached the wire, false when an
  /// MTU-floor violation caused the transport to drop the send. The cubit
  /// uses this signal to decide whether to disconnect: a single drop is
  /// expected (just-connected, MTU not yet observed → retry); persistent
  /// drops over the heartbeat window mean the link is unusable.
  Future<bool> send(FrequencyMessage msg) {
    // Chain onto the previous send so concurrent callers don't interleave
    // fragments on the wire. The completer lets each caller observe its
    // own send's outcome (true / false / thrown) without coupling to the
    // chain's collective state — a failed send must not poison the chain
    // and stall every subsequent caller.
    final completer = Completer<bool>();
    _sendChain = _sendChain.then((_) async {
      try {
        final result = await _sendOne(msg);
        if (!completer.isCompleted) completer.complete(result);
      } catch (error, stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// Body of a single [send] — runs serially under [_sendChain].
  Future<bool> _sendOne(FrequencyMessage msg) async {
    final maxFragmentSize = await _resolveFragmentSize();
    if (maxFragmentSize == null) {
      // MTU below the control-plane floor — drop the message rather than
      // emit fragments the link can't reliably carry. Caller (cubit) is
      // responsible for tearing down the connection if this persists.
      return false;
    }
    final fragments = encodeFragments(
      msg.encode(),
      maxFragmentSize: maxFragmentSize,
    );
    for (final f in fragments) {
      await _writeBytes(f);
    }
    return true;
  }

  /// Returns the per-fragment byte budget [send] should request from the
  /// encoder, or null if the negotiated MTU is below [kMinControlMtu] and
  /// the send must abort.
  Future<int?> _resolveFragmentSize() async {
    final endpoint = _activeEndpoint;
    final getMtu = _getMtu;
    if (endpoint == null || getMtu == null) return kMaxFragmentSize;

    final mtu = await getMtu(endpoint);
    if (mtu == null) {
      // No MTU observed yet (e.g. native side hasn't seen `onMtuChanged`
      // for this connection). Use the protocol default rather than gating
      // every send on a negotiation that may never happen explicitly —
      // BLE only fires `onMtuChanged` when one side requests a non-default
      // MTU.
      return kMaxFragmentSize;
    }
    if (mtu < kMinControlMtu) {
      debugPrint(
        'BleControlTransport: aborting send — negotiated MTU $mtu '
        'below floor $kMinControlMtu for endpoint $endpoint',
      );
      return null;
    }
    // MTU ≥ kMinControlMtu (64), so budget ≥ 61 — comfortably above the
    // encoder's kMinFragmentSize (23). Clamp to the v1 ceiling so we
    // never request a fragment size larger than the protocol's wire cap,
    // even if a future link layer reports an inflated MTU.
    final budget = mtu - kAttHeaderOverhead;
    return budget < kMaxFragmentSize ? budget : kMaxFragmentSize;
  }

  /// Drop the sequence-filter watermark and reassembler buffer for [peerId].
  ///
  /// Must be called on clean disconnect (Leave / RemovePeer flow) and on
  /// dirty-disconnect detection (heartbeat timeout) so a reconnecting peer's
  /// fresh `seq=1` is not swallowed by a stale watermark from the previous
  /// session.
  ///
  /// The reassembler is keyed by the peer's Bluetooth endpoint id (e.g. MAC),
  /// not the application-level [peerId]. The endpoint id is recorded when the
  /// first message from this peer arrives; if no message has been seen yet the
  /// reassembler cleanup is a no-op (there's nothing to clean up).
  void forgetPeer(String peerId) {
    _filter.forget(peerId);
    final endpointId = _endpointByPeer.remove(peerId);
    if (endpointId != null) {
      _reassemblers.remove(endpointId);
    }
  }

  /// Drop the watermark and reassembler buffer for **every** known peer.
  ///
  /// Called when the cubit leaves a room — held-over watermarks from the
  /// previous session would silently swallow `seq=1` of the next session
  /// (per the protocol's "fresh JoinAccepted resets seq" rule). Cheaper
  /// than enumerating the roster and calling [forgetPeer] N times, and
  /// also clears any peer the cubit didn't know about (ghosts left in
  /// the reassembler from a partial-fragment burst).
  void forgetAllPeers() {
    _filter.clear();
    _endpointByPeer.clear();
    _reassemblers.clear();
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
      // Record the mapping so forgetPeer can clean up the correct reassembler.
      _endpointByPeer[msg.peerId] = event.endpointId;
      if (!_filter.accept(peerId: msg.peerId, seq: msg.seq)) return;
      if (!_incoming.isClosed) _incoming.add(msg);
    } on FragmentError catch (e) {
      if (kDebugMode) debugPrint('drop fragment from ${event.endpointId}: $e');
    } on FormatException catch (e) {
      if (kDebugMode) debugPrint('drop message from ${event.endpointId}: $e');
    }
  }
}
