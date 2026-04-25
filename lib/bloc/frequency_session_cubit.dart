import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../services/identity_store.dart';
import 'frequency_session_state.dart';

/// Owns session-level Frequency state and the side-effects that mutate it:
/// reading and persisting the user's display name, advancing the navigation
/// stage, and tracking which frequency the user joined.
///
/// Created by `WalkieTalkieApp` and provided to the widget tree via
/// `BlocProvider`. Screens read state with `BlocBuilder` and dispatch via
/// the cubit's methods (no setState in `FrequencyApp`).
///
/// Side-effects through the [identityStore] (a filesystem boundary) are
/// wrapped in try/catch: persistence failures are logged but never block
/// the UI from advancing — the rename takes effect in memory and surfaces
/// the divergence on next launch when the previous value loads back.
class FrequencySessionCubit extends Cubit<FrequencySessionState> {
  final IdentityStore identityStore;

  FrequencySessionCubit({required this.identityStore})
      : super(const FrequencySessionState.booting());

  /// Reads the persisted display name; routes the user to Discovery if one
  /// exists, otherwise into Onboarding. Always exits the booting stage —
  /// even if the read throws, so we never strand the user on the splash.
  Future<void> bootstrap() async {
    String? persisted;
    try {
      persisted = await identityStore.getDisplayName();
    } catch (error, stackTrace) {
      debugPrint('Failed to load persisted display name: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (persisted != null) {
      emit(state.copyWith(
        stage: SessionStage.discovery,
        myName: persisted,
      ));
    } else {
      emit(state.copyWith(stage: SessionStage.onboarding));
    }
  }

  /// Persists [name] and advances to Discovery. The in-memory name updates
  /// even if the write fails so the user isn't stranded on the name screen.
  Future<void> completeOnboarding(String name) async {
    try {
      await identityStore.setDisplayName(name);
    } catch (error, stackTrace) {
      debugPrint('Failed to persist display name: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    emit(state.copyWith(stage: SessionStage.discovery, myName: name));
  }

  /// Persists the new [name] without changing the current stage. Same
  /// failure semantics as [completeOnboarding].
  Future<void> rename(String name) async {
    try {
      await identityStore.setDisplayName(name);
    } catch (error, stackTrace) {
      debugPrint('Failed to persist display name: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    emit(state.copyWith(myName: name));
  }

  /// Enters the Room stage on [freq]. [isHost] is true when the user
  /// created the frequency, false when they tuned in to someone else's.
  void joinRoom({required String freq, required bool isHost}) {
    emit(state.copyWith(
      stage: SessionStage.room,
      roomFreq: freq,
      roomIsHost: isHost,
    ));
  }

  /// Drops the user back on Discovery and clears the current-room fields.
  void leaveRoom() {
    emit(state.copyWith(
      stage: SessionStage.discovery,
      clearRoom: true,
    ));
  }
}
