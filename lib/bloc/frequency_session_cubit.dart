import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../protocol/messages.dart';
import '../services/audio_service.dart';
import '../services/ble_control_transport.dart';
import '../services/identity_store.dart';
import '../services/recent_frequencies_store.dart';
import '../services/reconnect_controller.dart';
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
  final RecentFrequenciesStore recentFrequenciesStore;

  /// Optional BLE control transport. When null the cubit operates in the
  /// same in-memory loopback mode as before the transport landed — useful
  /// for tests and early development builds.
  final BleControlTransport? _transport;

  /// Optional audio service. Required to drive [notifyDrop] — without it,
  /// reconnect attempts are silently skipped and the room stays in whatever
  /// [ConnectionPhase] was last emitted.
  final AudioService? _audio;

  /// Delay schedule injected into [ReconnectController]. Defaults to the
  /// production schedule; tests pass short delays to avoid slow test runs.
  final List<Duration>? _reconnectDelays;

  StreamSubscription<FrequencyMessage>? _transportSubscription;
  StreamSubscription<bool>? _localTalkingSubscription;
  ReconnectController? _reconnectController;

  final _mediaCommandsController = StreamController<MediaCommand>.broadcast();

  /// Stream of media commands relevant to the local peer's UI. Emits both
  /// the originator's optimistic command (so taps render immediately) and
  /// host echoes (so non-originators react to remote actions). Listeners
  /// can dedupe using the originator's `peerId` if needed; for v1's
  /// idempotent ops a duplicate apply is a no-op.
  Stream<MediaCommand> get mediaCommands => _mediaCommandsController.stream;

  int _seq = 0;

  FrequencySessionCubit({
    required this.identityStore,
    required this.recentFrequenciesStore,
    BleControlTransport? transport,
    AudioService? audio,
    List<Duration>? reconnectDelays,
  })  : _transport = transport,
        _audio = audio,
        _reconnectDelays = reconnectDelays,
        super(const SessionBooting());

  /// Reads the persisted display name; routes the user to Discovery if one
  /// exists, otherwise into Onboarding. Always exits Booting — even if the
  /// read throws — so the user never strands on the splash.
  ///
  /// Also wires the BLE transport's [BleControlTransport.incoming] stream
  /// so incoming wire messages drive state transitions for the lifetime of
  /// the cubit. Subscribes to voice activity detection from [_audio] to send
  /// TalkingState messages over the control transport.
  Future<void> bootstrap() async {
    _transportSubscription = _transport?.incoming.listen(_onTransportMessage);
    _localTalkingSubscription = _audio?.localTalking.listen(_onLocalTalking);

    String? persisted;
    try {
      persisted = await identityStore.getDisplayName();
    } catch (error, stackTrace) {
      debugPrint('Failed to load persisted display name: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (isClosed) return;
    if (persisted == null) {
      emit(const SessionOnboarding());
      return;
    }
    final recent = await _loadRecentFrequencies();
    if (isClosed) return;
    emit(SessionDiscovery(
      myName: persisted,
      recentHostedFrequencies: recent,
    ));
  }

  void _onTransportMessage(FrequencyMessage msg) {
    switch (msg) {
      case JoinAccepted m:
        applyJoinAccepted(m);
      case MediaCommand m:
        applyHostMediaEcho(m);
      case RosterUpdate m:
        final current = state;
        if (isClosed || current is! SessionRoom) return;
        emit(current.copyWith(roster: m.roster));
      case Leave m:
        // Host role: drop the leaving peer from the roster and clean up
        // transport state. Guest role: if the host leaves, leaveRoom().
        final current = state;
        if (isClosed || current is! SessionRoom) return;
        if (m.peerId == current.hostPeerId && !current.roomIsHost) {
          unawaited(leaveRoom());
        } else {
          final updated =
              current.roster.where((p) => p.peerId != m.peerId).toList();
          emit(current.copyWith(roster: updated));
          _transport?.forgetPeer(m.peerId);
        }
      case RemovePeer m:
        // Host-broadcasted peer removal. Drop the named peer from the roster
        // and clean up transport state, regardless of local role.
        final current = state;
        if (isClosed || current is! SessionRoom) return;
        final updated =
            current.roster.where((p) => p.peerId != m.target).toList();
        emit(current.copyWith(roster: updated));
        _transport?.forgetPeer(m.target);
      // These message types are handled by future issues (heartbeats,
      // signal reports, voice-activity detection). Silently drop for now.
      case TalkingState():
      case MuteState():
      case Heartbeat():
      case JoinRequest():
      case JoinDenied():
      case SignalReport():
        break;
    }
  }

  /// Called when local voice activity detection triggers. Sends a [TalkingState]
  /// message over the BLE control transport to notify other peers about the
  /// local user's speaking state.
  ///
  /// Only sends when in a room and when the transport is wired. If the transport
  /// is absent, the seq counter still advances so messages stay monotonic once
  /// the transport connects.
  void _onLocalTalking(bool talking) {
    final current = state;
    if (isClosed || current is! SessionRoom) return;

    final t = _transport;
    if (t == null) {
      _seq++;
      return;
    }

    // Resolve peerId asynchronously and send the message
    identityStore.getPeerId().then((peerId) {
      if (isClosed) return;
      final msg = TalkingState(
        peerId: peerId,
        seq: ++_seq,
        atMs: DateTime.now().millisecondsSinceEpoch,
        talking: talking,
      );
      unawaited(t.send(msg));
    }).catchError((error, stackTrace) {
      debugPrint('Failed to resolve peer id for talking state: $error');
      debugPrintStack(stackTrace: stackTrace);
      _seq++;
    });
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
    final recent = await _loadRecentFrequencies();
    if (isClosed) return;
    emit(SessionDiscovery(
      myName: name,
      recentHostedFrequencies: recent,
    ));
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
      case final SessionDiscovery discovery:
        // Preserve the loaded recent-frequencies list across renames —
        // re-reading would be a wasted disk hit and would briefly flicker
        // the Recent section if persistence is slow.
        emit(SessionDiscovery(
          myName: name,
          recentHostedFrequencies: discovery.recentHostedFrequencies,
        ));
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
  /// On the guest side, the caller passes [macAddress] and
  /// [sessionUuidLow8] from the discovered advertisement. Both are stored
  /// on `SessionRoom` so the GATT-client transport can dial the host
  /// later (the actual `connectToHost` call lands in the GATT-client
  /// issue). On the host side both are null — the local user *is* the
  /// host, so there's no remote to dial.
  ///
  /// Resets the per-link sequence counter to 0 so the next sent message
  /// starts at `seq = 1` per the protocol's reconnect rule.
  ///
  /// When [isHost] is true, the freq is recorded to the recent-hosted
  /// list as a side-effect. Persistence runs in the background — a
  /// failure or slow disk shouldn't block the transition into the room.
  /// The updated list shows up the next time the user lands on
  /// Discovery (via [leaveRoom]'s re-read).
  Future<void> joinRoom({
    required String freq,
    required bool isHost,
    String? macAddress,
    String? sessionUuidLow8,
  }) async {
    final current = state;
    if (current is! SessionDiscovery) return;
    _seq = 0;
    if (isHost) {
      // Fire-and-forget: the user has already committed to entering the
      // room, so we shouldn't await disk I/O before emitting. Errors are
      // logged on the future and surfaced on next launch as a missing
      // entry; nothing else depends on success here.
      unawaited(_recordRecentFrequency(freq));
    }
    emit(SessionRoom(
      myName: current.myName,
      roomFreq: freq,
      roomIsHost: isHost,
      // Guest path threads MAC + session UUID through to the room state so
      // the GATT-client transport can dial the host. Host path leaves them
      // null — the local user is the host.
      macAddress: isHost ? null : macAddress,
      sessionUuidLow8: isHost ? null : sessionUuidLow8,
    ));
  }

  /// Drops back to Discovery and forgets the room. No-op if not in a
  /// room (e.g. duplicate leave triggered during a transition). Resets
  /// the sequence counter so the next room starts fresh.
  ///
  /// Re-reads the recent-frequencies list so a freq the user just
  /// hosted appears at the top of the Recent section as soon as they
  /// return to Discovery.
  Future<void> leaveRoom() async {
    final current = state;
    if (current is! SessionRoom) return;
    // Stop any in-progress reconnect so BLE retries halt promptly when
    // the user manually leaves rather than waiting for the next delay tick.
    _reconnectController?.cancel();
    _reconnectController = null;
    _seq = 0;
    final recent = await _loadRecentFrequencies();
    if (isClosed) return;
    emit(SessionDiscovery(
      myName: current.myName,
      recentHostedFrequencies: recent,
    ));
  }

  Future<List<String>> _loadRecentFrequencies() async {
    try {
      return await recentFrequenciesStore.getRecent();
    } catch (error, stackTrace) {
      debugPrint('Failed to load recent frequencies: $error');
      debugPrintStack(stackTrace: stackTrace);
      return const [];
    }
  }

  Future<void> _recordRecentFrequency(String freq) async {
    try {
      await recentFrequenciesStore.record(freq);
    } catch (error, stackTrace) {
      debugPrint('Failed to record recent frequency: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
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
    // Clear any in-progress reconnect and return to online — the handshake
    // completing is the authoritative "connection is healthy" signal.
    _reconnectController?.cancel();
    _reconnectController = null;
    emit(current.copyWith(
      hostPeerId: msg.hostPeerId,
      roster: msg.roster,
      mediaState: msg.mediaState,
      connectionPhase: ConnectionPhase.online,
    ));
  }

  /// Called by heartbeat detection when the guest hasn't heard from the host
  /// for the heartbeat timeout. Transitions the room to
  /// [ConnectionPhase.reconnecting] and starts the exponential-backoff retry
  /// loop.
  ///
  /// No-op if the local user is the host, if [_audio] was not injected, or if
  /// a reconnect is already in progress. On success the transport will deliver
  /// a [JoinAccepted] that calls [applyJoinAccepted] and transitions back to
  /// [ConnectionPhase.online]. On failure the room drops to Discovery.
  Future<void> notifyDrop({required String macAddress}) async {
    final current = state;
    if (isClosed || current is! SessionRoom) return;
    if (current.roomIsHost) return;
    if (current.connectionPhase == ConnectionPhase.reconnecting) return;

    final audio = _audio;
    if (audio == null) return;

    emit(current.copyWith(connectionPhase: ConnectionPhase.reconnecting));

    _reconnectController?.cancel();
    final controller = ReconnectController(
      audio: audio,
      delays: _reconnectDelays,
    );
    _reconnectController = controller;
    final reconnected = await controller.attempt(macAddress: macAddress);

    if (isClosed) return;
    // Guard: if the room state has already moved on (applyJoinAccepted fired
    // and set connectionPhase back to online, or the user manually left), do
    // not overwrite that state with a failure-path transition.
    final postAttempt = state;
    if (postAttempt is! SessionRoom ||
        postAttempt.connectionPhase != ConnectionPhase.reconnecting) {
      return;
    }
    if (!reconnected) {
      // All retries exhausted — surface the lost phase briefly so the UI
      // can show a "Lost connection" indicator, then drop to Discovery.
      emit(postAttempt.copyWith(connectionPhase: ConnectionPhase.lost));
      await leaveRoom();
    }
    // On success: wait for the transport's JoinAccepted to call
    // applyJoinAccepted, which cancels the controller and resets to online.
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
    // Fire-and-forget the BLE write — a failure is already logged inside
    // BleControlTransport; the optimistic local apply stands regardless.
    final t = _transport;
    if (t != null) unawaited(t.send(cmd));
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

  /// Broadcasts a mute-state change originated by the local peer.
  ///
  /// Builds a `MuteState` message with the local peerId and a fresh seq,
  /// then sends it via the BLE control transport (if wired). When the
  /// transport is absent (no BLE connection yet) the seq counter still
  /// advances so it stays monotonic once the transport connects.
  ///
  /// The host will apply the mute state to its roster snapshot and echo
  /// it to all peers (including the originator) so UI indicators reflect
  /// the canonical view.
  Future<void> broadcastMute(bool muted) async {
    final t = _transport;
    if (t == null) {
      _seq++;
      return;
    }
    final String peerId;
    try {
      peerId = await identityStore.getPeerId();
    } catch (error, stackTrace) {
      debugPrint('Failed to resolve peer id for mute broadcast: $error');
      debugPrintStack(stackTrace: stackTrace);
      _seq++;
      return;
    }
    if (isClosed) return;
    final msg = MuteState(
      peerId: peerId,
      seq: ++_seq,
      atMs: DateTime.now().millisecondsSinceEpoch,
      muted: muted,
    );
    unawaited(t.send(msg));
  }

  @override
  Future<void> close() async {
    // Cancel an in-progress reconnect before closing so the attempt loop
    // won't call emit() or leaveRoom() after the cubit is disposed.
    _reconnectController?.cancel();
    // Order matters. `super.close()` flips the cubit's `isClosed`; the
    // suspended `await` in `sendMediaCommand` resumes after it sees
    // `isClosed == true` and bails before touching the controller. If
    // we closed the controller *first*, an in-flight `sendMediaCommand`
    // could resume in the microtask window between
    // `_mediaCommandsController.isClosed = true` and
    // `cubit.isClosed = true` and throw on `add`.
    await super.close();
    await _transportSubscription?.cancel();
    await _localTalkingSubscription?.cancel();
    await _mediaCommandsController.close();
  }
}
