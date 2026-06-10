import 'dart:convert';

import 'peer.dart';
import 'wire_fields.dart';

/// Wire-format version sent on every message and parsed by every receiver.
const int kProtocolVersion = 1;

/// Reasons a host can deny a join request.
enum JoinDenyReason { hostDeclined, roomFull, versionMismatch }

extension JoinDenyReasonWire on JoinDenyReason {
  String get wire => switch (this) {
    JoinDenyReason.hostDeclined => 'host_declined',
    JoinDenyReason.roomFull => 'room_full',
    JoinDenyReason.versionMismatch => 'version_mismatch',
  };

  static JoinDenyReason fromWire(String s) => switch (s) {
    'host_declined' => JoinDenyReason.hostDeclined,
    'room_full' => JoinDenyReason.roomFull,
    'version_mismatch' => JoinDenyReason.versionMismatch,
    _ => throw FormatException('Unknown deny reason: $s'),
  };
}

/// Operations carried by a `MediaCommand`.
enum MediaOp { play, pause, skip, prev, seek, queuePlay }

extension MediaOpWire on MediaOp {
  String get wire => switch (this) {
    MediaOp.play => 'play',
    MediaOp.pause => 'pause',
    MediaOp.skip => 'skip',
    MediaOp.prev => 'prev',
    MediaOp.seek => 'seek',
    MediaOp.queuePlay => 'queue_play',
  };

  static MediaOp fromWire(String s) => switch (s) {
    'play' => MediaOp.play,
    'pause' => MediaOp.pause,
    'skip' => MediaOp.skip,
    'prev' => MediaOp.prev,
    'seek' => MediaOp.seek,
    'queue_play' => MediaOp.queuePlay,
    _ => throw FormatException('Unknown media op: $s'),
  };
}

/// Snapshot of what's playing on the host, sent inside `JoinAccepted` so a
/// freshly-joined guest can render the room without waiting for the next
/// `MediaCommand`.
class MediaState {
  final String source;
  final int trackIdx;
  final bool playing;
  final int positionMs;

  const MediaState({
    required this.source,
    required this.trackIdx,
    required this.playing,
    required this.positionMs,
  });

  Map<String, dynamic> toJson() => {
    'source': source,
    'trackIdx': trackIdx,
    'playing': playing,
    'positionMs': positionMs,
  };

  factory MediaState.fromJson(Map<String, dynamic> json) {
    final trackIdx = reqInt(json, 'trackIdx');
    final positionMs = reqInt(json, 'positionMs');
    _requireNonNeg(trackIdx, 'trackIdx');
    _requireNonNeg(positionMs, 'positionMs');
    return MediaState(
      source: reqString(json, 'source'),
      trackIdx: trackIdx,
      playing: reqBool(json, 'playing'),
      positionMs: positionMs,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaState &&
          source == other.source &&
          trackIdx == other.trackIdx &&
          playing == other.playing &&
          positionMs == other.positionMs;

  @override
  int get hashCode => Object.hash(source, trackIdx, playing, positionMs);
}

/// Base class for every wire message in the Frequency control plane.
///
/// Sealed: a v2 protocol that needs new kinds bumps `kProtocolVersion` and
/// adds them in this file. Receivers exhaustively switch on the runtime
/// type and the analyzer surfaces missing branches.
sealed class FrequencyMessage {
  final String peerId;
  final int seq;
  final int atMs;

  const FrequencyMessage({
    required this.peerId,
    required this.seq,
    required this.atMs,
  });

  /// Wire `kind` discriminator.
  String get kind;

  /// Serialise to a JSON-shaped map, including the envelope.
  Map<String, dynamic> toJson();

  /// Convenience: stringified JSON ready for the GATT REQUEST/RESPONSE write.
  String encode() => jsonEncode(toJson());

  /// Parse a single line of wire JSON.
  ///
  /// Throws `FormatException` on:
  ///   * malformed JSON
  ///   * top-level value that isn't a JSON object
  ///   * missing or non-int `v`, or version mismatch
  ///   * missing or non-string `kind`, or unknown `kind`
  ///   * any kind-specific schema mismatch
  ///
  /// Receivers catch `FormatException` and drop the message; the connection
  /// stays up.
  static FrequencyMessage decode(String wire) {
    final decoded = jsonDecode(wire);
    if (decoded is! Map) {
      throw const FormatException('Frequency message must be a JSON object');
    }
    return fromJson(Map<String, dynamic>.from(decoded));
  }

  static FrequencyMessage fromJson(Map<String, dynamic> json) {
    final v = json['v'];
    if (v is! int) {
      throw const FormatException('Missing or non-int protocol version `v`');
    }
    if (v != kProtocolVersion) {
      throw FormatException('Unsupported protocol version: $v');
    }
    final kind = json['kind'];
    if (kind is! String) {
      throw const FormatException('Missing or non-string message `kind`');
    }
    return switch (kind) {
      'join_request' => JoinRequest._fromJson(json),
      'join_accepted' => JoinAccepted._fromJson(json),
      'join_denied' => JoinDenied._fromJson(json),
      'leave' => Leave._fromJson(json),
      'remove_peer' => RemovePeer._fromJson(json),
      'roster_update' => RosterUpdate._fromJson(json),
      'talking' => TalkingState._fromJson(json),
      'mute' => MuteState._fromJson(json),
      'media' => MediaCommand._fromJson(json),
      'signal_report' => SignalReport._fromJson(json),
      'link_quality' => LinkQuality._fromJson(json),
      'bitrate_hint' => BitrateHint._fromJson(json),
      'ping' => Heartbeat._fromJson(json),
      'host_transfer' => HostTransfer._fromJson(json),
      _ => throw FormatException('Unknown frequency message kind: $kind'),
    };
  }

  Map<String, dynamic> _envelope() => {
    'kind': kind,
    'peerId': peerId,
    'seq': seq,
    'atMs': atMs,
    'v': kProtocolVersion,
  };
}

/// Parses a JSON list of objects into typed values, raising `FormatException`
/// (not the `TypeError` a bare cast would) when the wire shape is wrong.
/// [field] names the list in the error messages; [fromJson] decodes each
/// element. Shared by the `roster` and `neighbors` parsers, which differ only
/// in their element type.
List<T> _parseObjectList<T>(
  Object? raw,
  String field,
  T Function(Map<String, dynamic>) fromJson,
) {
  if (raw is! List) {
    throw FormatException('`$field` must be a JSON array');
  }
  final out = <T>[];
  for (final element in raw) {
    if (element is! Map) {
      throw FormatException('$field element must be a JSON object');
    }
    out.add(fromJson(Map<String, dynamic>.from(element)));
  }
  return out;
}

/// Rejects a negative wire field as `FormatException` (the receiver drops the
/// message; the link stays up), using the `"$field out of range: $value"`
/// wording the numeric decoders share. Used for the int [trackIdx] /
/// [positionMs] in [MediaState] and [MediaCommand] and for the int [jitterMs]
/// / double [underrunsPerSec] in [LinkQuality] — hence [num], not [int].
void _requireNonNeg(num value, String field) {
  if (value < 0) {
    throw FormatException('$field out of range: $value');
  }
}

// ── Lifecycle ───────────────────────────────────────────────────────────────

final class JoinRequest extends FrequencyMessage {
  final String displayName;
  final String? btDevice;

  const JoinRequest({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.displayName,
    this.btDevice,
  });

  @override
  String get kind => 'join_request';

  @override
  Map<String, dynamic> toJson() => {
    ..._envelope(),
    'displayName': displayName,
    if (btDevice != null) 'btDevice': btDevice,
  };

  factory JoinRequest._fromJson(Map<String, dynamic> j) => JoinRequest(
    peerId: reqString(j, 'peerId'),
    seq: reqSeq(j, 'seq'),
    atMs: reqAtMs(j, 'atMs'),
    displayName: reqString(j, 'displayName'),
    btDevice: optString(j, 'btDevice'),
  );
}

final class JoinAccepted extends FrequencyMessage {
  final String hostPeerId;
  final List<ProtocolPeer> roster;
  final MediaState? mediaState;

  /// Dynamic LE-CoC PSM (`0x0080`–`0x00FF`) the host's voice server is
  /// bound to. Guests open an L2CAP CoC to this PSM after `JoinAccepted`
  /// lands. Optional on the wire — null means voice isn't available yet
  /// (e.g. the host is a control-plane-only build), and the guest stays
  /// silent until/unless a future message provides one.
  final int? voicePsm;

  /// Peer-id of the intended recipient. Non-null when the host sends a
  /// targeted `JoinAccepted` to a single joining guest (as opposed to a
  /// legacy broadcast with no recipient filter). Receivers that observe a
  /// non-null value that doesn't match their own peer-id must silently
  /// ignore the message so that existing guests don't reset their `_seq`
  /// counters when a new peer joins.
  final String? recipientPeerId;

  const JoinAccepted({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.hostPeerId,
    required this.roster,
    this.mediaState,
    this.voicePsm,
    this.recipientPeerId,
  }) : assert(
         voicePsm == null || (voicePsm >= 0x80 && voicePsm <= 0xFF),
         'voicePsm must be in dynamic-PSM range 0x0080-0x00FF',
       );

  @override
  String get kind => 'join_accepted';

  @override
  Map<String, dynamic> toJson() => {
    ..._envelope(),
    'hostPeerId': hostPeerId,
    'roster': roster.map((p) => p.toJson()).toList(),
    if (mediaState != null) 'mediaState': mediaState!.toJson(),
    if (voicePsm != null) 'voicePsm': voicePsm,
    if (recipientPeerId != null) 'recipientPeerId': recipientPeerId,
  };

  factory JoinAccepted._fromJson(Map<String, dynamic> j) {
    final voicePsm = optInt(j, 'voicePsm');
    if (voicePsm != null && (voicePsm < 0x80 || voicePsm > 0xFF)) {
      throw FormatException(
        'Invalid voicePsm: $voicePsm (must be in dynamic-PSM range 0x0080-0x00FF)',
      );
    }

    final rawMediaState = j['mediaState'];
    if (rawMediaState != null && rawMediaState is! Map) {
      throw const FormatException('`mediaState` must be a JSON object');
    }
    return JoinAccepted(
      peerId: reqString(j, 'peerId'),
      seq: reqSeq(j, 'seq'),
      atMs: reqAtMs(j, 'atMs'),
      hostPeerId: reqString(j, 'hostPeerId'),
      roster: _parseObjectList(j['roster'], 'roster', ProtocolPeer.fromJson),
      mediaState: rawMediaState == null
          ? null
          : MediaState.fromJson(Map<String, dynamic>.from(rawMediaState)),
      voicePsm: voicePsm,
      recipientPeerId: optString(j, 'recipientPeerId'),
    );
  }
}

final class JoinDenied extends FrequencyMessage {
  final JoinDenyReason reason;

  const JoinDenied({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.reason,
  });

  @override
  String get kind => 'join_denied';

  @override
  Map<String, dynamic> toJson() => {..._envelope(), 'reason': reason.wire};

  factory JoinDenied._fromJson(Map<String, dynamic> j) => JoinDenied(
    peerId: reqString(j, 'peerId'),
    seq: reqSeq(j, 'seq'),
    atMs: reqAtMs(j, 'atMs'),
    reason: JoinDenyReasonWire.fromWire(reqString(j, 'reason')),
  );
}

final class Leave extends FrequencyMessage {
  const Leave({required super.peerId, required super.seq, required super.atMs});

  @override
  String get kind => 'leave';

  @override
  Map<String, dynamic> toJson() => _envelope();

  factory Leave._fromJson(Map<String, dynamic> j) => Leave(
    peerId: reqString(j, 'peerId'),
    seq: reqSeq(j, 'seq'),
    atMs: reqAtMs(j, 'atMs'),
  );
}

final class RemovePeer extends FrequencyMessage {
  final String target;

  const RemovePeer({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.target,
  });

  @override
  String get kind => 'remove_peer';

  @override
  Map<String, dynamic> toJson() => {..._envelope(), 'target': target};

  factory RemovePeer._fromJson(Map<String, dynamic> j) => RemovePeer(
    peerId: reqString(j, 'peerId'),
    seq: reqSeq(j, 'seq'),
    atMs: reqAtMs(j, 'atMs'),
    target: reqString(j, 'target'),
  );
}

final class RosterUpdate extends FrequencyMessage {
  final List<ProtocolPeer> roster;

  const RosterUpdate({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.roster,
  });

  @override
  String get kind => 'roster_update';

  @override
  Map<String, dynamic> toJson() => {
    ..._envelope(),
    'roster': roster.map((p) => p.toJson()).toList(),
  };

  factory RosterUpdate._fromJson(Map<String, dynamic> j) => RosterUpdate(
    peerId: reqString(j, 'peerId'),
    seq: reqSeq(j, 'seq'),
    atMs: reqAtMs(j, 'atMs'),
    roster: _parseObjectList(j['roster'], 'roster', ProtocolPeer.fromJson),
  );
}

// ── Voice control ───────────────────────────────────────────────────────────

final class TalkingState extends FrequencyMessage {
  final bool talking;

  const TalkingState({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.talking,
  });

  @override
  String get kind => 'talking';

  @override
  Map<String, dynamic> toJson() => {..._envelope(), 'talking': talking};

  factory TalkingState._fromJson(Map<String, dynamic> j) => TalkingState(
    peerId: reqString(j, 'peerId'),
    seq: reqSeq(j, 'seq'),
    atMs: reqAtMs(j, 'atMs'),
    talking: reqBool(j, 'talking'),
  );
}

final class MuteState extends FrequencyMessage {
  final bool muted;

  const MuteState({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.muted,
  });

  @override
  String get kind => 'mute';

  @override
  Map<String, dynamic> toJson() => {..._envelope(), 'muted': muted};

  factory MuteState._fromJson(Map<String, dynamic> j) => MuteState(
    peerId: reqString(j, 'peerId'),
    seq: reqSeq(j, 'seq'),
    atMs: reqAtMs(j, 'atMs'),
    muted: reqBool(j, 'muted'),
  );
}

// ── Shared media ────────────────────────────────────────────────────────────

final class MediaCommand extends FrequencyMessage {
  final MediaOp op;
  final String source;
  final int? trackIdx;
  final int? positionMs;

  const MediaCommand({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.op,
    required this.source,
    this.trackIdx,
    this.positionMs,
  }) : assert(
         op != MediaOp.queuePlay || trackIdx != null,
         'MediaCommand(queue_play) requires trackIdx',
       ),
       assert(
         op != MediaOp.seek || positionMs != null,
         'MediaCommand(seek) requires positionMs',
       );

  @override
  String get kind => 'media';

  @override
  Map<String, dynamic> toJson() => {
    ..._envelope(),
    'op': op.wire,
    'source': source,
    if (trackIdx != null) 'trackIdx': trackIdx,
    if (positionMs != null) 'positionMs': positionMs,
  };

  factory MediaCommand._fromJson(Map<String, dynamic> j) {
    final op = MediaOpWire.fromWire(reqString(j, 'op'));
    final trackIdx = optInt(j, 'trackIdx');
    final positionMs = optInt(j, 'positionMs');
    if (op == MediaOp.queuePlay && trackIdx == null) {
      throw const FormatException('MediaCommand(queue_play) requires trackIdx');
    }
    if (op == MediaOp.seek && positionMs == null) {
      throw const FormatException('MediaCommand(seek) requires positionMs');
    }
    if (trackIdx != null) _requireNonNeg(trackIdx, 'trackIdx');
    if (positionMs != null) _requireNonNeg(positionMs, 'positionMs');
    return MediaCommand(
      peerId: reqString(j, 'peerId'),
      seq: reqSeq(j, 'seq'),
      atMs: reqAtMs(j, 'atMs'),
      op: op,
      source: reqString(j, 'source'),
      trackIdx: trackIdx,
      positionMs: positionMs,
    );
  }
}

// ── Health ──────────────────────────────────────────────────────────────────

class NeighborSignal {
  /// RSSI is reported in dBm. Real Bluetooth radios sit roughly in
  /// `[-120, 0]`; the bounds below allow a small margin and reject a
  /// corrupted or malicious peer that sends an absurd value (e.g. 1000000)
  /// that would otherwise skew signal-quality UI and any link/bitrate
  /// heuristics that read neighbor RSSI.
  static const int kMinRssiDbm = -127;
  static const int kMaxRssiDbm = 0;

  final String peerId;
  final int rssi;
  const NeighborSignal({required this.peerId, required this.rssi})
    : assert(
        rssi >= kMinRssiDbm && rssi <= kMaxRssiDbm,
        'rssi must be a dBm value in [kMinRssiDbm, kMaxRssiDbm]',
      );

  Map<String, dynamic> toJson() => {'peerId': peerId, 'rssi': rssi};
  factory NeighborSignal.fromJson(Map<String, dynamic> j) {
    final rssi = reqInt(j, 'rssi');
    if (rssi < kMinRssiDbm || rssi > kMaxRssiDbm) {
      throw FormatException('rssi out of range: $rssi');
    }
    return NeighborSignal(peerId: reqString(j, 'peerId'), rssi: rssi);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NeighborSignal && peerId == other.peerId && rssi == other.rssi;

  @override
  int get hashCode => Object.hash(peerId, rssi);
}

final class SignalReport extends FrequencyMessage {
  final List<NeighborSignal> neighbors;

  const SignalReport({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.neighbors,
  });

  @override
  String get kind => 'signal_report';

  @override
  Map<String, dynamic> toJson() => {
    ..._envelope(),
    'neighbors': neighbors.map((n) => n.toJson()).toList(),
  };

  factory SignalReport._fromJson(Map<String, dynamic> j) => SignalReport(
    peerId: reqString(j, 'peerId'),
    seq: reqSeq(j, 'seq'),
    atMs: reqAtMs(j, 'atMs'),
    neighbors: _parseObjectList(j['neighbors'], 'neighbors', NeighborSignal.fromJson),
  );
}

final class Heartbeat extends FrequencyMessage {
  const Heartbeat({
    required super.peerId,
    required super.seq,
    required super.atMs,
  });

  @override
  String get kind => 'ping';

  @override
  Map<String, dynamic> toJson() => _envelope();

  factory Heartbeat._fromJson(Map<String, dynamic> j) => Heartbeat(
    peerId: reqString(j, 'peerId'),
    seq: reqSeq(j, 'seq'),
    atMs: reqAtMs(j, 'atMs'),
  );
}

// ── Adaptive bitrate ────────────────────────────────────────────────────────

/// A peer's view of the receive-side voice link quality, sampled by the
/// `LinkQualityReporter` from the native `PeerAudioManager` telemetry every
/// few seconds and sent to the host. The host's `BitrateAdapter` consumes
/// these to decide whether to step the encoder up or down for that peer.
///
/// Direction on the wire: guests report on the host→guest stream they're
/// receiving. The host doesn't send `LinkQuality` over the wire — it polls
/// its own telemetry locally and feeds the adapter directly.
///
/// Field semantics:
///   * `lossPct` ∈ [0, 100] — fraction of expected frames that arrived too
///     late to play (jitter buffer rejections), as a percentage.
///   * `jitterMs` ∈ [0, kMaxJitterMs] — current jitter buffer fill in ms
///     (depth × 20 ms). Useful as an observability field; the adapter
///     doesn't use it.
///   * `underrunsPerSec` ∈ [0, kMaxUnderrunsPerSec] — rate of mixer-tick
///     underruns in the sampled window. A non-zero rate means the buffer
///     drained faster than the wire could refill it.
final class LinkQuality extends FrequencyMessage {
  /// Upper bound accepted for a wire `jitterMs`. The native jitter buffer
  /// hard-caps at `kJitterMaxDepth` = 10 frames × 20 ms = 200 ms
  /// (`audio_config.h`), so any legitimate value sits well under this; the
  /// 10 s ceiling is a 50× headroom for protocol evolution while still
  /// rejecting an int64-garbage value before it skews the host's
  /// voice-debug dashboard. Mirrors the `lossPct ∈ [0, 100]` range check.
  static const int kMaxJitterMs = 10000;

  /// Upper bound accepted for a wire `underrunsPerSec`. The mixer ticks at
  /// 50 fps (20 ms frames), so the underrun rate physically can't exceed
  /// ~50/s in steady state; 10 000 is generous headroom for a transient
  /// sampling window while still rejecting garbage.
  static const double kMaxUnderrunsPerSec = 10000;

  final double lossPct;
  final int jitterMs;
  final double underrunsPerSec;

  const LinkQuality({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.lossPct,
    required this.jitterMs,
    required this.underrunsPerSec,
  }) : assert(
         lossPct >= 0 && lossPct <= 100,
         'lossPct must be a percentage in [0, 100]',
       ),
       assert(jitterMs >= 0, 'jitterMs must be non-negative'),
       assert(underrunsPerSec >= 0, 'underrunsPerSec must be non-negative');

  @override
  String get kind => 'link_quality';

  @override
  Map<String, dynamic> toJson() => {
    ..._envelope(),
    'lossPct': lossPct,
    'jitterMs': jitterMs,
    'underrunsPerSec': underrunsPerSec,
  };

  factory LinkQuality._fromJson(Map<String, dynamic> j) {
    final lossPctRaw = j['lossPct'];
    final jitterMsRaw = j['jitterMs'];
    final underrunsRaw = j['underrunsPerSec'];
    if (lossPctRaw is! num) {
      throw const FormatException('`lossPct` must be a number');
    }
    if (jitterMsRaw is! int) {
      throw const FormatException('`jitterMs` must be an int');
    }
    if (underrunsRaw is! num) {
      throw const FormatException('`underrunsPerSec` must be a number');
    }
    final lossPct = lossPctRaw.toDouble();
    final underruns = underrunsRaw.toDouble();
    if (lossPct < 0 || lossPct > 100) {
      throw FormatException('lossPct out of range: $lossPct');
    }
    _requireNonNeg(jitterMsRaw, 'jitterMs');
    _requireNonNeg(underruns, 'underrunsPerSec');
    if (jitterMsRaw > kMaxJitterMs) {
      throw FormatException('jitterMs out of range: $jitterMsRaw');
    }
    if (underruns > kMaxUnderrunsPerSec) {
      throw FormatException('underrunsPerSec out of range: $underruns');
    }
    return LinkQuality(
      peerId: reqString(j, 'peerId'),
      seq: reqSeq(j, 'seq'),
      atMs: reqAtMs(j, 'atMs'),
      lossPct: lossPct,
      jitterMs: jitterMsRaw,
      underrunsPerSec: underruns,
    );
  }
}

/// Host → specific-guest advisory: "guest [target], set your outbound
/// encoder bitrate to [bps]." The recipient applies the value to its
/// own `PeerAudioManager` for the link to the host. Out-of-range values
/// are clamped at the native layer to the {Low, Mid, High} operating
/// points in `audio_config.h`.
///
/// The host emits these in response to its own receive-side telemetry of
/// each guest's stream — so a guest whose uplink is degraded gets nudged
/// down before the host's jitter buffer underruns become audible.
///
/// **Why a target field.** The host writes via `BleControlTransport.send`,
/// which broadcasts on the GATT RESPONSE characteristic to every
/// subscribed guest. Without a `target` field, every guest in a
/// multi-guest room would interpret the hint and adjust their own
/// encoder — turning a per-link decision into a room-wide one. Mirrors
/// the `RemovePeer` pattern: guests filter on receive by `target ==
/// localPeerId` and ignore hints addressed to someone else.
final class BitrateHint extends FrequencyMessage {
  /// Upper bound accepted for a wire `bps`. Opus tops out at ~510 kbps for
  /// multi-channel audio; 500 000 bps gives generous headroom for future
  /// encoder growth while rejecting int64-garbage values (e.g. 2^53) before
  /// they skew Dart-side display or heuristics. Mirrors the `kMaxJitterMs`
  /// pattern on [LinkQuality].
  static const int kMaxBps = 500000;

  final String target;
  final int bps;

  const BitrateHint({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.target,
    required this.bps,
  }) : assert(bps > 0, 'bps must be positive');

  @override
  String get kind => 'bitrate_hint';

  @override
  Map<String, dynamic> toJson() => {
    ..._envelope(),
    'target': target,
    'bps': bps,
  };

  factory BitrateHint._fromJson(Map<String, dynamic> j) {
    final bps = reqInt(j, 'bps');
    if (bps <= 0) {
      throw FormatException('bps out of range: $bps');
    }
    if (bps > kMaxBps) {
      throw FormatException('bps out of range: $bps');
    }
    return BitrateHint(
      peerId: reqString(j, 'peerId'),
      seq: reqSeq(j, 'seq'),
      atMs: reqAtMs(j, 'atMs'),
      target: reqString(j, 'target'),
      bps: bps,
    );
  }
}

// ── Host handover ────────────────────────────────────────────────────────────

/// Sent by the current host just before it leaves when guests are present.
/// The named peer should start advertising + serving GATT with [sessionUuid]
/// and take over as the new host. All other peers update their [hostPeerId]
/// so subsequent messages from the old host (e.g. [Leave]) are not
/// misinterpreted as a room-killing event.
final class HostTransfer extends FrequencyMessage {
  final String newHostPeerId;

  /// Full session UUID the new host must use when calling startAdvertising,
  /// so the room frequency stays stable for guests that need to reconnect.
  final String sessionUuid;

  const HostTransfer({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.newHostPeerId,
    required this.sessionUuid,
  });

  @override
  String get kind => 'host_transfer';

  @override
  Map<String, dynamic> toJson() => {
    ..._envelope(),
    'newHostPeerId': newHostPeerId,
    'sessionUuid': sessionUuid,
  };

  factory HostTransfer._fromJson(Map<String, dynamic> j) => HostTransfer(
    peerId: reqString(j, 'peerId'),
    seq: reqSeq(j, 'seq'),
    atMs: reqAtMs(j, 'atMs'),
    newHostPeerId: reqString(j, 'newHostPeerId'),
    sessionUuid: reqString(j, 'sessionUuid'),
  );
}
