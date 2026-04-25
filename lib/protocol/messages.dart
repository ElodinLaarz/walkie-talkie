import 'dart:convert';

import 'peer.dart';

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

  factory MediaState.fromJson(Map<String, dynamic> json) => MediaState(
        source: json['source'] as String,
        trackIdx: json['trackIdx'] as int,
        playing: json['playing'] as bool,
        positionMs: json['positionMs'] as int,
      );

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
      'ping' => Heartbeat._fromJson(json),
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

/// Parses a `roster` JSON list into typed `ProtocolPeer`s, raising
/// `FormatException` (not `TypeError`) when the wire shape is wrong.
List<ProtocolPeer> _parseRoster(Object? raw) {
  if (raw is! List) {
    throw const FormatException('`roster` must be a JSON array');
  }
  final out = <ProtocolPeer>[];
  for (final element in raw) {
    if (element is! Map) {
      throw const FormatException('roster element must be a JSON object');
    }
    out.add(ProtocolPeer.fromJson(Map<String, dynamic>.from(element)));
  }
  return out;
}

/// Parses a `neighbors` JSON list into typed `NeighborSignal`s, with the same
/// `FormatException` discipline as `_parseRoster`.
List<NeighborSignal> _parseNeighbors(Object? raw) {
  if (raw is! List) {
    throw const FormatException('`neighbors` must be a JSON array');
  }
  final out = <NeighborSignal>[];
  for (final element in raw) {
    if (element is! Map) {
      throw const FormatException('neighbors element must be a JSON object');
    }
    out.add(NeighborSignal.fromJson(Map<String, dynamic>.from(element)));
  }
  return out;
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
        peerId: j['peerId'] as String,
        seq: j['seq'] as int,
        atMs: j['atMs'] as int,
        displayName: j['displayName'] as String,
        btDevice: j['btDevice'] as String?,
      );
}

final class JoinAccepted extends FrequencyMessage {
  final String hostPeerId;
  final List<ProtocolPeer> roster;
  final MediaState? mediaState;

  const JoinAccepted({
    required super.peerId,
    required super.seq,
    required super.atMs,
    required this.hostPeerId,
    required this.roster,
    this.mediaState,
  });

  @override
  String get kind => 'join_accepted';

  @override
  Map<String, dynamic> toJson() => {
        ..._envelope(),
        'hostPeerId': hostPeerId,
        'roster': roster.map((p) => p.toJson()).toList(),
        if (mediaState != null) 'mediaState': mediaState!.toJson(),
      };

  factory JoinAccepted._fromJson(Map<String, dynamic> j) => JoinAccepted(
        peerId: j['peerId'] as String,
        seq: j['seq'] as int,
        atMs: j['atMs'] as int,
        hostPeerId: j['hostPeerId'] as String,
        roster: _parseRoster(j['roster']),
        mediaState: j['mediaState'] == null
            ? null
            : MediaState.fromJson(
                Map<String, dynamic>.from(j['mediaState'] as Map),
              ),
      );
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
  Map<String, dynamic> toJson() => {
        ..._envelope(),
        'reason': reason.wire,
      };

  factory JoinDenied._fromJson(Map<String, dynamic> j) => JoinDenied(
        peerId: j['peerId'] as String,
        seq: j['seq'] as int,
        atMs: j['atMs'] as int,
        reason: JoinDenyReasonWire.fromWire(j['reason'] as String),
      );
}

final class Leave extends FrequencyMessage {
  const Leave({
    required super.peerId,
    required super.seq,
    required super.atMs,
  });

  @override
  String get kind => 'leave';

  @override
  Map<String, dynamic> toJson() => _envelope();

  factory Leave._fromJson(Map<String, dynamic> j) => Leave(
        peerId: j['peerId'] as String,
        seq: j['seq'] as int,
        atMs: j['atMs'] as int,
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
  Map<String, dynamic> toJson() => {
        ..._envelope(),
        'target': target,
      };

  factory RemovePeer._fromJson(Map<String, dynamic> j) => RemovePeer(
        peerId: j['peerId'] as String,
        seq: j['seq'] as int,
        atMs: j['atMs'] as int,
        target: j['target'] as String,
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
        peerId: j['peerId'] as String,
        seq: j['seq'] as int,
        atMs: j['atMs'] as int,
        roster: _parseRoster(j['roster']),
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
  Map<String, dynamic> toJson() => {
        ..._envelope(),
        'talking': talking,
      };

  factory TalkingState._fromJson(Map<String, dynamic> j) => TalkingState(
        peerId: j['peerId'] as String,
        seq: j['seq'] as int,
        atMs: j['atMs'] as int,
        talking: j['talking'] as bool,
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
  Map<String, dynamic> toJson() => {
        ..._envelope(),
        'muted': muted,
      };

  factory MuteState._fromJson(Map<String, dynamic> j) => MuteState(
        peerId: j['peerId'] as String,
        seq: j['seq'] as int,
        atMs: j['atMs'] as int,
        muted: j['muted'] as bool,
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
  })  : assert(
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
    final op = MediaOpWire.fromWire(j['op'] as String);
    final trackIdx = j['trackIdx'] as int?;
    final positionMs = j['positionMs'] as int?;
    if (op == MediaOp.queuePlay && trackIdx == null) {
      throw const FormatException(
        'MediaCommand(queue_play) requires trackIdx',
      );
    }
    if (op == MediaOp.seek && positionMs == null) {
      throw const FormatException('MediaCommand(seek) requires positionMs');
    }
    return MediaCommand(
      peerId: j['peerId'] as String,
      seq: j['seq'] as int,
      atMs: j['atMs'] as int,
      op: op,
      source: j['source'] as String,
      trackIdx: trackIdx,
      positionMs: positionMs,
    );
  }
}

// ── Health ──────────────────────────────────────────────────────────────────

class NeighborSignal {
  final String peerId;
  final int rssi;
  const NeighborSignal({required this.peerId, required this.rssi});

  Map<String, dynamic> toJson() => {'peerId': peerId, 'rssi': rssi};
  factory NeighborSignal.fromJson(Map<String, dynamic> j) => NeighborSignal(
        peerId: j['peerId'] as String,
        rssi: j['rssi'] as int,
      );

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
        peerId: j['peerId'] as String,
        seq: j['seq'] as int,
        atMs: j['atMs'] as int,
        neighbors: _parseNeighbors(j['neighbors']),
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
        peerId: j['peerId'] as String,
        seq: j['seq'] as int,
        atMs: j['atMs'] as int,
      );
}
