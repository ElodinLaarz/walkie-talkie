import 'package:equatable/equatable.dart';

import '../protocol/messages.dart';
import '../protocol/peer.dart';

/// Sealed hierarchy describing the session-level Frequency state. Each
/// stage carries exactly the fields it needs — the UI exhaustively
/// switches on the runtime type and the analyzer flags missing branches.
/// Force-unwraps and "is this field set?" plumbing aren't required.
sealed class FrequencySessionState extends Equatable {
  const FrequencySessionState();
}

/// App just launched; the identity store hasn't been read yet.
final class SessionBooting extends FrequencySessionState {
  const SessionBooting();

  @override
  List<Object?> get props => const [];
}

/// No persisted display name; the user is going through onboarding.
final class SessionOnboarding extends FrequencySessionState {
  const SessionOnboarding();

  @override
  List<Object?> get props => const [];
}

/// User has a persisted display name and is on Discovery, but hasn't
/// joined or created a frequency yet.
final class SessionDiscovery extends FrequencySessionState {
  final String myName;
  const SessionDiscovery({required this.myName});

  @override
  List<Object?> get props => [myName];
}

/// User is in a room. Both [roomFreq] and [roomIsHost] are non-nullable
/// by construction, so the UI can read them without force-unwrapping.
///
/// [hostPeerId], [roster], and [mediaState] are populated from the host's
/// `JoinAccepted` (or self-issued for hosts) — they're nullable on entry
/// because the room is joined before the handshake completes; they're
/// settled with `applyJoinAccepted`.
final class SessionRoom extends FrequencySessionState {
  final String myName;
  final String roomFreq;
  final bool roomIsHost;

  /// Peer-id of the room's host. Always null until `applyJoinAccepted`
  /// fires (or the local user is the host and self-seeds it).
  final String? hostPeerId;

  /// Latest roster snapshot from the host. Empty until handshake.
  final List<ProtocolPeer> roster;

  /// Snapshot of what's playing as of the most recent host message
  /// (`JoinAccepted` or echoed `MediaCommand`). Null until set —
  /// guests treat null as "host hasn't told me yet, render the local
  /// queue's first track and wait for the snapshot to land."
  final MediaState? mediaState;

  const SessionRoom({
    required this.myName,
    required this.roomFreq,
    required this.roomIsHost,
    this.hostPeerId,
    this.roster = const [],
    this.mediaState,
  });

  SessionRoom copyWith({
    String? myName,
    String? roomFreq,
    bool? roomIsHost,
    String? hostPeerId,
    List<ProtocolPeer>? roster,
    MediaState? mediaState,
  }) =>
      SessionRoom(
        myName: myName ?? this.myName,
        roomFreq: roomFreq ?? this.roomFreq,
        roomIsHost: roomIsHost ?? this.roomIsHost,
        hostPeerId: hostPeerId ?? this.hostPeerId,
        roster: roster ?? this.roster,
        mediaState: mediaState ?? this.mediaState,
      );

  @override
  List<Object?> get props =>
      [myName, roomFreq, roomIsHost, hostPeerId, roster, mediaState];
}
