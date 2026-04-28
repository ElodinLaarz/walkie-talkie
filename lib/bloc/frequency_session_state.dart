import 'package:equatable/equatable.dart';

import '../protocol/messages.dart';
import '../protocol/peer.dart';
import '../services/permission_watcher.dart';

/// Sentinel marking an argument-not-supplied position in `copyWith`. A
/// caller passing `null` explicitly is distinguishable from omitting
/// the argument, which the `??` pattern can't model.
const Object _unset = Object();

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
///
/// [recentHostedFrequencies] is the most-recent-first list of channels
/// the local user has hosted on this device, sourced from
/// `RecentFrequenciesStore`. Empty when the user hasn't hosted before
/// or the persisted store couldn't be read. The list is expected to
/// already be unmodifiable (Equatable diffs it element-wise, so a
/// caller mutating it in place would silently break state-change
/// detection).
final class SessionDiscovery extends FrequencySessionState {
  final String myName;
  final List<String> recentHostedFrequencies;
  const SessionDiscovery({
    required this.myName,
    this.recentHostedFrequencies = const [],
  });

  @override
  List<Object?> get props => [myName, recentHostedFrequencies];
}

/// User revoked one or more required runtime permissions while the app was
/// running. The cubit transitions here from any other stage when
/// [PermissionWatcher] reports a non-empty missing list, so the UI can
/// render an explanatory screen with a "Re-grant in Settings" affordance.
///
/// [missing] is the ordered list of permissions the user has revoked
/// (microphone before bluetooth, mirroring the watcher's emission). The
/// list is unmodifiable so subscribers can compare with `==` for change
/// detection. The cubit clears this state by emitting [SessionDiscovery]
/// (or [SessionOnboarding] for a fresh install) once the watcher reports
/// an empty list — recovering room state mid-session is intentionally not
/// attempted (see issue #57's acceptance criteria: re-grant returns the
/// user to Discovery, not the previous room).
final class SessionPermissionDenied extends FrequencySessionState {
  /// Ordered, deduped list of currently-missing permissions.
  final List<AppPermission> missing;

  /// Persisted display name, threaded through so the recovery transition
  /// back to [SessionDiscovery] doesn't have to round-trip through the
  /// identity store. Null when the app hadn't completed onboarding before
  /// the revocation (revoking during the onboarding permission step is
  /// handled by the onboarding screen itself, not by this state — but
  /// the field is nullable as a defensive measure).
  final String? myName;

  SessionPermissionDenied({
    required List<AppPermission> missing,
    this.myName,
  }) : missing = List<AppPermission>.unmodifiable(missing);

  @override
  List<Object?> get props => [missing, myName];
}

/// Tracks whether the guest's BLE link to the host is healthy.
///
/// [online] — established and receiving heartbeats (default for hosts, whose
///   link is always considered healthy since they *are* the host).
/// [reconnecting] — a transient drop was detected; [ReconnectController] is
///   retrying in the background and the UI shows a "Reconnecting…" pill.
/// [lost] — all retries exhausted; [FrequencySessionCubit.leaveRoom] is
///   called immediately after emitting this phase.
enum ConnectionPhase { online, reconnecting, lost }

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

  /// Snapshot of what's playing as established by `JoinAccepted` (or
  /// self-seeded for hosts). Null until set — guests treat null as
  /// "host hasn't told me yet, render the local queue's first track
  /// and wait for the snapshot to land."
  ///
  /// This field is **not** advanced by later echoed `MediaCommand`s in
  /// the current implementation: the cubit lacks queue access and
  /// can't correctly resolve trackIdx for `skip` / `prev`. The room
  /// screen owns queue-aware advancement and treats this as the
  /// initial / rejoin reseed only. See `applyHostMediaEcho` for the
  /// rationale.
  final MediaState? mediaState;

  /// BT MAC of the host this guest is connected to, carried through from
  /// Discovery. Null on the host side (the local user *is* the host, so
  /// there's no remote to dial) and on Recent / cosmetic-only entries before
  /// BLE is wired. The GATT-client transport reads this to dial the host.
  final String? macAddress;

  /// Low 8 bytes of the host's session UUID, in hex (16 chars). Carried
  /// alongside [macAddress] so the BLE control plane can correlate the room
  /// with the advertised session — multiple hosts on different sessions can
  /// share a MAC if the same physical device hops sessions, so MAC alone
  /// isn't a stable session key. Null in the same cases as [macAddress].
  final String? sessionUuidLow8;

  /// Current BLE link health between this guest and the host. Always
  /// [ConnectionPhase.online] for host-role sessions. Updated by
  /// [FrequencySessionCubit.notifyDrop] and cleared back to [online] by
  /// [FrequencySessionCubit.applyJoinAccepted] on a successful rejoin.
  final ConnectionPhase connectionPhase;

  const SessionRoom({
    required this.myName,
    required this.roomFreq,
    required this.roomIsHost,
    this.hostPeerId,
    this.roster = const [],
    this.mediaState,
    this.macAddress,
    this.sessionUuidLow8,
    this.connectionPhase = ConnectionPhase.online,
  });

  /// `??` would conflate "argument omitted" with "argument explicitly set
  /// to null" for the nullable fields (`hostPeerId`, `mediaState`), so a
  /// rejoin where the host has nothing playing — `applyJoinAccepted` with
  /// `msg.mediaState == null` — would silently retain the stale snapshot.
  /// The `_unset` sentinel lets callers distinguish the two: an omitted
  /// param keeps the existing value, an explicit null clears it.
  ///
  /// Incoming `roster` lists are wrapped in `List.unmodifiable` so a
  /// caller hanging onto the original (e.g. `JoinAccepted.roster` from
  /// the wire decoder, which is mutable) can't retroactively mutate
  /// past states and break Equatable's diffing or UI rebuild
  /// assumptions. `this.roster` is already either a const empty list
  /// (from the constructor default) or a previously-wrapped
  /// unmodifiable, so passing it through is safe.
  SessionRoom copyWith({
    String? myName,
    String? roomFreq,
    bool? roomIsHost,
    Object? hostPeerId = _unset,
    List<ProtocolPeer>? roster,
    Object? mediaState = _unset,
    Object? macAddress = _unset,
    Object? sessionUuidLow8 = _unset,
    ConnectionPhase? connectionPhase,
  }) =>
      SessionRoom(
        myName: myName ?? this.myName,
        roomFreq: roomFreq ?? this.roomFreq,
        roomIsHost: roomIsHost ?? this.roomIsHost,
        hostPeerId: identical(hostPeerId, _unset)
            ? this.hostPeerId
            : hostPeerId as String?,
        roster: roster == null
            ? this.roster
            : List<ProtocolPeer>.unmodifiable(roster),
        mediaState: identical(mediaState, _unset)
            ? this.mediaState
            : mediaState as MediaState?,
        macAddress: identical(macAddress, _unset)
            ? this.macAddress
            : macAddress as String?,
        sessionUuidLow8: identical(sessionUuidLow8, _unset)
            ? this.sessionUuidLow8
            : sessionUuidLow8 as String?,
        connectionPhase: connectionPhase ?? this.connectionPhase,
      );

  @override
  List<Object?> get props => [
        myName,
        roomFreq,
        roomIsHost,
        hostPeerId,
        roster,
        mediaState,
        macAddress,
        sessionUuidLow8,
        connectionPhase,
      ];
}
