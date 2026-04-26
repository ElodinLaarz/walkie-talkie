import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../protocol/messages.dart';
import '../services/identity_store.dart';
import 'frequency_session_state.dart';

/// Owns session-level Frequency state and the side-effects that mutate it:
/// reading and persisting the user's display name, advancing the
/// navigation stage, tracking which frequency the user joined, and
/// surfacing the wire-protocol's media plane to the UI.
///
/// Created by `WalkieTalkieApp` and provided to the widget tree via
/// `BlocProvider`. Screens read state with `BlocBuilder` and dispatch via
/// the cubit's methods.
///
/// Side-effects through the [identityStore] (a filesystem boundary) are
/// wrapped in try/catch: persistence failures are logged but never block
/// the UI from advancing — the rename takes effect in memory and surfaces
/// the divergence on next launch when the previous value loads back.
///
/// **Protocol surface.** Three methods bridge the BLE wire protocol into
/// session state. They're the hooks the BLE transport will call once it
/// lands; until then, the in-memory loopback in [sendMediaCommand]
/// exercises the same code paths so widget tests stay realistic:
///
///   * [applyJoinAccepted] — caller hands in a `JoinAccepted` from the
///     host (or a self-issued one when the local user is the host).
///     Replaces the room's snapshot (roster + hostPeerId + mediaState)
///     and resets the per-peer sequence counter per the protocol's
///     reconnect rule.
///   * [sendMediaCommand] — originator path. Builds a `MediaCommand`
///     with the local peerId, applies it **optimistically** to the
///     local UI by emitting on [mediaCommands] so the tap feels
///     responsive, AND would write it to the host's GATT REQUEST
///     characteristic when the BLE transport is wired.
///   * [applyHostMediaEcho] — host echo path. The host (or the loopback
///     in v1) calls this to forward the host-approved command onto
///     [mediaCommands] so listeners can react to the canonical wire
///     event. This currently does **not** mutate
///     `SessionRoom.mediaState`; the cubit's room snapshot only
///     changes when room state is replaced (e.g. via
///     [applyJoinAccepted]). The room screen owns queue-aware
///     advancement against the echo — see the per-method doc on
///     [applyHostMediaEcho] for why mediaState advancement isn't in
///     the cubit.
class FrequencySessionCubit extends Cubit<FrequencySessionState> {
  final IdentityStore identityStore;

  final _mediaCommandsController = StreamController<MediaCommand>.broadcast();

  /// Stream of media commands relevant to the local peer's UI. Emits both
  /// the originator's optimistic command (so taps render immediately) and
  /// host echoes (so non-originators react to remote actions). Listeners
  /// can dedupe using the originator's `peerId` if needed; for v1's
  /// idempotent ops a duplicate apply is a no-op.
  Stream<MediaCommand> get mediaCommands => _mediaCommandsController.stream;

  int _seq = 0;

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
      case final SessionRoom room:
        emit(room.copyWith(myName: name));
      case SessionBooting():
      case SessionOnboarding():
        break;
    }
  }

  /// Enters Room on [freq]. [isHost] is true when the user created the
  /// frequency, false when they tuned in to an existing one. No-op if
  /// the user isn't on Discovery (shouldn't happen — Discovery is the
  /// only screen that triggers it).
  ///
  /// Resets the per-link sequence counter to 0 so the next sent message
  /// starts at `seq = 1` per the protocol's reconnect rule.
  void joinRoom({required String freq, required bool isHost}) {
    final current = state;
    if (current is! SessionDiscovery) return;
    _seq = 0;
    emit(SessionRoom(
      myName: current.myName,
      roomFreq: freq,
      roomIsHost: isHost,
    ));
  }

  /// Drops back to Discovery and forgets the room. No-op if not in a
  /// room (e.g. duplicate leave triggered during a transition). Resets
  /// the sequence counter so the next room starts fresh.
  void leaveRoom() {
    final current = state;
    if (current is! SessionRoom) return;
    _seq = 0;
    emit(SessionDiscovery(myName: current.myName));
  }

  /// Apply a `JoinAccepted` from the host. Replaces the room's snapshot
  /// (roster + hostPeerId + mediaState) with the host's view of the
  /// world, and resets the per-link sequence counter — both halves of
  /// the protocol's reconnect contract. No-op outside `SessionRoom`,
  /// or after the cubit is closed (BLE callbacks can fire post-dispose).
  ///
  /// On the guest side, the room screen reacts to the new `mediaState`
  /// by seeking the local player and resuming if `playing == true`,
  /// satisfying the rejoin smoke-test acceptance criterion.
  void applyJoinAccepted(JoinAccepted msg) {
    if (isClosed) return;
    final current = state;
    if (current is! SessionRoom) return;
    _seq = 0;
    emit(current.copyWith(
      hostPeerId: msg.hostPeerId,
      roster: msg.roster,
      mediaState: msg.mediaState,
    ));
  }

  /// Broadcasts a media command originated by the local peer.
  ///
  /// Per the protocol's host-as-authority pattern:
  ///
  ///   1. Build the command with the local peerId and a fresh seq.
  ///   2. Apply it **optimistically** by emitting on [mediaCommands] so
  ///      the UI updates instantly.
  ///   3. (Once the BLE transport lands) write it to the host's REQUEST
  ///      characteristic. The host validates, applies, and echoes a
  ///      canonical version to all peers via [applyHostMediaEcho].
  ///
  /// In v1 the BLE transport isn't wired yet, so step 3 is a no-op and
  /// the originator's optimistic apply is the only apply that fires.
  /// When the transport lands, the originator's [applyHostMediaEcho]
  /// callback will reconcile any disagreement (host wins).
  Future<void> sendMediaCommand({
    required MediaOp op,
    required String source,
    int? trackIdx,
    int? positionMs,
  }) async {
    final String peerId;
    try {
      peerId = await identityStore.getPeerId();
    } catch (error, stackTrace) {
      // Callers from the room screen fire-and-forget, so an exception
      // here would surface as an unhandled async error. Log and bail —
      // the user re-tapping is a fine recovery path.
      debugPrint('Failed to resolve peer id for media command: $error');
      debugPrintStack(stackTrace: stackTrace);
      return;
    }
    // Re-check both gates after the await: a `close()` racing with this
    // method can flip the controller's `isClosed` synchronously while
    // the cubit's own `isClosed` (which awaits state-stream drain)
    // hasn't caught up yet. Add-after-close throws — short-circuit
    // cleanly instead.
    if (isClosed || _mediaCommandsController.isClosed) return;
    final cmd = MediaCommand(
      peerId: peerId,
      seq: ++_seq,
      atMs: DateTime.now().millisecondsSinceEpoch,
      op: op,
      source: source,
      trackIdx: trackIdx,
      positionMs: positionMs,
    );
    _mediaCommandsController.add(cmd);
  }

  /// Apply a host-echoed `MediaCommand`. The canonical apply path:
  /// non-originators react to remote actions here, and originators
  /// reconcile their optimistic local state against the host's view.
  /// Re-emits on [mediaCommands] with the host's `peerId` so UI
  /// listeners can render "X paused" attribution from the echo.
  ///
  /// **What this method does *not* do.** It does not advance
  /// `SessionRoom.mediaState`. The cubit doesn't have access to the
  /// queue (`MediaSourceLib.queue.length`), so it can't correctly
  /// resolve the trackIdx for `skip` / `prev`. The room screen owns
  /// queue-aware advancement; the cubit's `mediaState` is the
  /// `JoinAccepted` bootstrap snapshot only. Once the BLE host
  /// implementation lands, the host side will track canonical
  /// mediaState (with queue access) and snapshot it into every
  /// outgoing `JoinAccepted` for guests to seed from.
  ///
  /// No-op outside `SessionRoom`, or after the cubit is closed.
  void applyHostMediaEcho(MediaCommand cmd) {
    if (isClosed || _mediaCommandsController.isClosed) return;
    final current = state;
    if (current is! SessionRoom) return;
    _mediaCommandsController.add(cmd);
  }

  @override
  Future<void> close() async {
    // Order matters. `super.close()` flips the cubit's `isClosed`; the
    // suspended `await` in `sendMediaCommand` resumes after it sees
    // `isClosed == true` and bails before touching the controller. If
    // we closed the controller *first*, an in-flight `sendMediaCommand`
    // could resume in the microtask window between
    // `_mediaCommandsController.isClosed = true` and
    // `cubit.isClosed = true` and throw on `add`.
    await super.close();
    await _mediaCommandsController.close();
  }
}
