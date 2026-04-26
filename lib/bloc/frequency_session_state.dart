import 'package:equatable/equatable.dart';

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
final class SessionRoom extends FrequencySessionState {
  final String myName;
  final String roomFreq;
  final bool roomIsHost;
  const SessionRoom({
    required this.myName,
    required this.roomFreq,
    required this.roomIsHost,
  });

  @override
  List<Object?> get props => [myName, roomFreq, roomIsHost];
}
