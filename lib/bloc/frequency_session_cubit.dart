import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../services/identity_store.dart';
import 'frequency_session_state.dart';

/// Owns session-level Frequency state and the side-effects that mutate it:
/// reading and persisting the user's display name, advancing the
/// navigation stage, and tracking which frequency the user joined.
///
/// Created by `WalkieTalkieApp` and provided to the widget tree via
/// `BlocProvider`. Screens read state with `BlocBuilder` and dispatch via
/// the cubit's methods.
///
/// Side-effects through the [identityStore] (a filesystem boundary) are
/// wrapped in try/catch: persistence failures are logged but never block
/// the UI from advancing — the rename takes effect in memory and surfaces
/// the divergence on next launch when the previous value loads back.
class FrequencySessionCubit extends Cubit<FrequencySessionState> {
  final IdentityStore identityStore;

  FrequencySessionCubit({required this.identityStore})
      : super(const SessionBooting());

  /// Reads the persisted display name; routes the user to Discovery if one
  /// exists, otherwise into Onboarding. Always exits Booting — even if the
  /// read throws — so the user never strands on the splash.
  Future<void> bootstrap() async {
    String? persisted;
    try {
      persisted = await identityStore.getDisplayName();
    } catch (error, stackTrace) {
      debugPrint('Failed to load persisted display name: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (isClosed) return;
    emit(persisted != null
        ? SessionDiscovery(myName: persisted)
        : const SessionOnboarding());
  }

  /// Persists [name] and advances to Discovery. The state changes even if
  /// the write fails so the user isn't stranded on the name screen.
  Future<void> completeOnboarding(String name) async {
    try {
      await identityStore.setDisplayName(name);
    } catch (error, stackTrace) {
      debugPrint('Failed to persist display name: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (isClosed) return;
    emit(SessionDiscovery(myName: name));
  }

  /// Persists the new [name] without changing the current stage. Same
  /// failure semantics as [completeOnboarding].
  ///
  /// Only makes sense after onboarding — calls in Booting/Onboarding are
  /// no-ops on the visible state (the next stage transition will pick up
  /// whatever the store now holds).
  Future<void> rename(String name) async {
    try {
      await identityStore.setDisplayName(name);
    } catch (error, stackTrace) {
      debugPrint('Failed to persist display name: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (isClosed) return;
    switch (state) {
      case SessionDiscovery():
        emit(SessionDiscovery(myName: name));
      case SessionRoom(:final roomFreq, :final roomIsHost):
        emit(SessionRoom(
          myName: name,
          roomFreq: roomFreq,
          roomIsHost: roomIsHost,
        ));
      case SessionBooting():
      case SessionOnboarding():
        break;
    }
  }

  /// Enters Room on [freq]. [isHost] is true when the user created the
  /// frequency, false when they tuned in to an existing one. No-op if
  /// the user isn't on Discovery (shouldn't happen — Discovery is the
  /// only screen that triggers it).
  void joinRoom({required String freq, required bool isHost}) {
    final current = state;
    if (current is! SessionDiscovery) return;
    emit(SessionRoom(
      myName: current.myName,
      roomFreq: freq,
      roomIsHost: isHost,
    ));
  }

  /// Drops back to Discovery and forgets the room. No-op if not in a
  /// room (e.g. duplicate leave triggered during a transition).
  void leaveRoom() {
    final current = state;
    if (current is! SessionRoom) return;
    emit(SessionDiscovery(myName: current.myName));
  }
}
