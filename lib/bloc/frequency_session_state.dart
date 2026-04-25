import 'package:equatable/equatable.dart';

/// High-level navigation stages for the Frequency app.
enum SessionStage { booting, onboarding, discovery, room }

/// Single source of truth for session-level Frequency state: which screen
/// the user is on, who they are, and (when in a room) which frequency they
/// joined and whether they're the host.
///
/// Room-internal state (roster, mute, media playback, output selection) is
/// still owned by `FrequencyRoomScreen` for now and will migrate here in a
/// follow-up PR.
class FrequencySessionState extends Equatable {
  final SessionStage stage;
  final String myName;
  final String? roomFreq;
  final bool roomIsHost;

  const FrequencySessionState({
    required this.stage,
    required this.myName,
    this.roomFreq,
    this.roomIsHost = false,
  });

  /// Initial state: app just launched, identity store hasn't been read yet.
  const FrequencySessionState.booting()
      : stage = SessionStage.booting,
        myName = '',
        roomFreq = null,
        roomIsHost = false;

  /// Returns a copy with updated fields. Pass `clearRoom: true` to drop
  /// `roomFreq` / `roomIsHost` regardless of the corresponding parameters
  /// (used on `leaveRoom`).
  FrequencySessionState copyWith({
    SessionStage? stage,
    String? myName,
    String? roomFreq,
    bool? roomIsHost,
    bool clearRoom = false,
  }) {
    return FrequencySessionState(
      stage: stage ?? this.stage,
      myName: myName ?? this.myName,
      roomFreq: clearRoom ? null : (roomFreq ?? this.roomFreq),
      roomIsHost: clearRoom ? false : (roomIsHost ?? this.roomIsHost),
    );
  }

  @override
  List<Object?> get props => [stage, myName, roomFreq, roomIsHost];
}
