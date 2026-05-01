import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../protocol/frequency_session.dart';
import '../protocol/messages.dart';
import '../protocol/peer.dart';
import '../protocol/uuid.dart';
import '../services/audio_service.dart';
import '../services/bitrate_adapter.dart';
import '../services/ble_control_transport.dart';
import '../services/heartbeat_scheduler.dart';
import '../services/identity_store.dart';
import '../services/link_quality_reporter.dart';
import '../services/permission_watcher.dart';
import '../services/recent_frequencies_store.dart';
import '../services/reconnect_controller.dart';
import '../services/signal_reporter.dart';
import '../services/weak_signal_detector.dart';
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

  /// Optional permission watcher. When provided, the cubit subscribes during
  /// [bootstrap] and transitions to [SessionPermissionDenied] whenever the
  /// watcher reports a non-empty missing-permissions list — covering the
  /// case where the user revokes mic / Bluetooth from system Settings while
  /// the app is running. Null in tests / loopback builds that don't exercise
  /// the permission surface.
  final PermissionWatcher? _permissionWatcher;

  /// Delay schedule injected into [ReconnectController]. Defaults to the
  /// production schedule; tests pass short delays to avoid slow test runs.
  final List<Duration>? _reconnectDelays;

  /// Mint the per-session UUID on the host bootstrap path. Indirection so
  /// tests can pin a deterministic UUID and assert the derived `roomFreq`.
  /// Defaults to the cryptographic [generateUuidV4] for production builds.
  final String Function() _mintSessionUuid;

  /// Drives the protocol's `ping` plane. Started on room entry, stopped
  /// on leave / close. The cubit owns the role-specific reaction to a
  /// lost peer (host: drop from roster + broadcast `RosterUpdate`;
  /// guest: notify a host drop via [notifyDrop]).
  final HeartbeatScheduler _heartbeats;

  /// Drives the protocol's `signal_report` plane. Started on room entry
  /// **on the guest side only** (the host receives reports rather than
  /// sending them) and stopped on leave / close.
  final SignalReporter _signalReporter;

  /// Host-side gate: keeps per-neighbor consecutive-weak counters and
  /// rate-limits toasts for the same neighbor. Lives for the cubit
  /// lifetime; cleared on `leaveRoom` and on per-peer drop / removal.
  final WeakSignalDetector _weakSignalDetector;

  /// Drives the protocol's `link_quality` plane on the **guest** side.
  /// Started on room entry, stopped on leave / close. The cubit polls
  /// the native `PeerAudioManager` telemetry on each tick, deltas it
  /// against the previous snapshot, and writes a `LinkQuality` to the
  /// host. Skipped on the host side — the host is a receiver of these
  /// reports, not a sender.
  final LinkQualityReporter _linkQualityReporter;

  /// Host-side: per-peer hysteresis state machine that consumes incoming
  /// `LinkQuality` reports and decides when to step a peer's encoder
  /// up or down. Cleared on `leaveRoom`.
  final BitrateAdapter _bitrateAdapter;

  /// Per-peer previous telemetry snapshot, keyed by Bluetooth MAC. Used
  /// by the guest's link-quality tick to compute deltas. Cleared on
  /// leave / close along with the rest of the per-session state.
  final Map<String, LinkTelemetrySnapshot> _prevTelemetry = {};

  /// Wall-clock of the previous link-quality sample, keyed by MAC.
  /// Tracked alongside [_prevTelemetry] so a tick that's late (e.g.
  /// because the OS suspended the timer) computes rates against actual
  /// elapsed time rather than the nominal interval.
  final Map<String, DateTime> _prevTelemetryAt = {};

  /// Re-entrancy guard for [_sendLinkQuality]. The reporter tick is
  /// `unawaited`-launched, so a slow telemetry round-trip plus transport
  /// write could otherwise overlap a subsequent tick. Same rationale as
  /// [_signalReportSendInFlight].
  bool _linkQualitySendInFlight = false;

  /// Re-entrancy guard for [_sendHeartbeat]. The scheduler tick is
  /// `unawaited`-launched, so a slow GATT write could otherwise overlap
  /// the next tick and let two `send()` calls interleave on the same
  /// transport. When a send is in flight, later ticks become no-ops
  /// (and the seq counter stays put — the dropped tick effectively
  /// merges with the in-flight one).
  bool _heartbeatSendInFlight = false;

  /// Re-entrancy guard for [_sendSignalReport]. Same rationale as
  /// [_heartbeatSendInFlight]: the reporter tick is `unawaited`-launched
  /// and `getCurrentRssi` plus `transport.send` can stretch across the
  /// next 10 s tick on a slow link.
  bool _signalReportSendInFlight = false;

  StreamSubscription<FrequencyMessage>? _transportSubscription;
  StreamSubscription<bool>? _localTalkingSubscription;
  StreamSubscription<List<AppPermission>>? _permissionSubscription;
  ReconnectController? _reconnectController;

  /// Default watchdog duration after a successful GATT reconnect: how long
  /// we wait for the host's JoinAccepted before bailing to lost + Discovery.
  /// Tests can shorten this via the constructor parameter.
  static const Duration defaultJoinAcceptedTimeout = Duration(seconds: 10);

  final Duration _joinAcceptedTimeout;

  /// Watchdog timer started after a successful GATT reconnect to detect when
  /// the host never sends a JoinAccepted. Fires after [_joinAcceptedTimeout]
  /// and transitions to ConnectionPhase.lost if still reconnecting.
  /// Cancelled by applyJoinAccepted or any state transition that exits
  /// SessionRoom.
  Timer? _joinAcceptedWatchdog;

  final _mediaCommandsController = StreamController<MediaCommand>.broadcast();

  /// Stream of media commands relevant to the local peer's UI. Emits both
  /// the originator's optimistic command (so taps render immediately) and
  /// host echoes (so non-originators react to remote actions). Listeners
  /// can dedupe using the originator's `peerId` if needed; for v1's
  /// idempotent ops a duplicate apply is a no-op.
  Stream<MediaCommand> get mediaCommands => _mediaCommandsController.stream;

  final _weakSignalEventsController =
      StreamController<({String peerId, String displayName})>.broadcast();

  /// Host-only stream of "neighbor X is weak" events that have already
  /// passed the consecutive-reports threshold and the per-peer rate-limit.
  /// The room screen subscribes and renders a toast.
  ///
  /// `displayName` is resolved against the current roster; when the
  /// neighbor isn't in the roster (e.g. a stale report after `RemovePeer`)
  /// the event is dropped before it reaches the stream rather than
  /// surfacing a generic-sounding toast.
  Stream<({String peerId, String displayName})> get weakSignalEvents =>
      _weakSignalEventsController.stream;

  int _seq = 0;
  String? _localPeerId;

  /// Expose the current sequence number for testing. Tests use this to verify
  /// that seq advances even when the transport is null or when errors occur.
  @visibleForTesting
  int get debugSeq => _seq;

  FrequencySessionCubit({
    required this.identityStore,
    required this.recentFrequenciesStore,
    BleControlTransport? transport,
    AudioService? audio,
    PermissionWatcher? permissionWatcher,
    List<Duration>? reconnectDelays,
    HeartbeatScheduler? heartbeats,
    SignalReporter? signalReporter,
    WeakSignalDetector? weakSignalDetector,
    LinkQualityReporter? linkQualityReporter,
    BitrateAdapter? bitrateAdapter,
    String Function()? mintSessionUuid,
    Duration joinAcceptedTimeout = defaultJoinAcceptedTimeout,
  })  : _transport = transport,
        _audio = audio,
        _permissionWatcher = permissionWatcher,
        _reconnectDelays = reconnectDelays,
        _heartbeats = heartbeats ?? HeartbeatScheduler(),
        _signalReporter = signalReporter ?? SignalReporter(),
        _weakSignalDetector = weakSignalDetector ?? WeakSignalDetector(),
        _linkQualityReporter = linkQualityReporter ?? LinkQualityReporter(),
        _bitrateAdapter = bitrateAdapter ?? BitrateAdapter(),
        _mintSessionUuid = mintSessionUuid ?? generateUuidV4,
        _joinAcceptedTimeout = joinAcceptedTimeout,
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
    // Subscribe to runtime permission changes so a mid-session revoke
    // (user toggling mic / Bluetooth in system Settings) tears down voice +
    // BLE cleanly and the UI shows an explanatory screen instead of
    // crashing on the next AudioRecord / GATT call. The watcher emits an
    // initial snapshot on subscription, so a fresh launch with already-
    // revoked perms is handled too.
    _permissionSubscription =
        _permissionWatcher?.watch().listen(_onPermissionsChanged);

    // Cache peerId to avoid async resolution in hot path (voice activity)
    try {
      _localPeerId = await identityStore.getPeerId();
    } catch (error, stackTrace) {
      if (kDebugMode) debugPrint('Failed to load peer ID: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
    }

    String? persisted;
    try {
      persisted = await identityStore.getDisplayName();
    } catch (error, stackTrace) {
      if (kDebugMode) debugPrint('Failed to load persisted display name: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
    }
    if (isClosed) return;
    if (persisted == null) {
      emit(const SessionOnboarding());
    } else {
      final recent = await _loadRecentFrequencies();
      if (isClosed) return;
      emit(SessionDiscovery(
        myName: persisted,
        recentHostedFrequencies: recent,
      ));
    }
    // Defensive replay of the latest permission state. The watcher's
    // initial sample is emitted before bootstrap finishes (cubit is still
    // in [SessionBooting] when the listener runs), and
    // [_onPermissionsChanged] intentionally ignores Booting because
    // onboarding owns its own permission flow. Without this re-check, an
    // initial revoked state would be swallowed by the watcher's de-dup
    // and never re-surface — a fresh launch with mic / BT already revoked
    // would land on Discovery instead of the denied screen. Apply the
    // latest sample through the same handler now that we've left Booting.
    final watcher = _permissionWatcher;
    if (watcher != null && !isClosed) {
      unawaited(() async {
        try {
          final missing = await watcher.checkNow();
          if (isClosed) return;
          _onPermissionsChanged(missing);
        } catch (error, stackTrace) {
          debugPrint('Initial permission check failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        }
      }());
    }
  }

  void _onTransportMessage(FrequencyMessage msg) {
    // Any inbound activity from a peer counts as a sign-of-life — refresh
    // the heartbeat watermark before dispatching, so a peer that's actively
    // sending control messages won't be declared lost just because a
    // dedicated `ping` was delayed.
    _heartbeats.notePingFrom(msg.peerId);
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
          _heartbeats.forgetPeer(m.peerId);
          _weakSignalDetector.forgetPeer(m.peerId);
          _bitrateAdapter.forgetPeer(m.peerId);
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
        _heartbeats.forgetPeer(m.target);
        _weakSignalDetector.forgetPeer(m.target);
        _bitrateAdapter.forgetPeer(m.target);
      case Heartbeat():
        // Already noted above; no further dispatch — the heartbeat plane
        // is purely a liveness signal, not a state-changing event.
        break;
      case SignalReport m:
        _onSignalReport(m);
      case LinkQuality m:
        _onLinkQuality(m);
      case BitrateHint m:
        _onBitrateHint(m);
      // These message types are handled by future issues
      // (voice-activity detection, join request flow). Silently drop.
      case TalkingState():
      case MuteState():
      case JoinRequest():
      case JoinDenied():
        break;
    }
  }

  /// Host-only ingress for `SignalReport`. Guests currently send
  /// reports but never consume them — only the host owns the toast
  /// surface for "X's signal is weak."
  ///
  /// Reports are passed to [_weakSignalDetector] which keeps the
  /// per-neighbor consecutive-weak counter and the per-neighbor toast
  /// rate-limit. Each tripped neighbor is resolved against the current
  /// roster for a display name; if the neighbor isn't in the roster
  /// (e.g. a stale report after a `RemovePeer`) the event is dropped
  /// before it reaches [weakSignalEvents]. This keeps the room screen
  /// from rendering toasts for ghosts.
  void _onSignalReport(SignalReport report) {
    if (isClosed) return;
    final current = state;
    if (current is! SessionRoom || !current.roomIsHost) return;
    if (_weakSignalEventsController.isClosed) return;
    final fired = _weakSignalDetector.onReport(report);
    if (fired.isEmpty) return;
    // Build the lookup once per report rather than scanning the roster
    // per neighbor — a single weak report could trip several at once,
    // and the per-call cost otherwise grows as the room fills up.
    final namesByPeerId = <String, String>{
      for (final p in current.roster) p.peerId: p.displayName,
    };
    for (final neighborId in fired) {
      // Don't surface a toast for our own peerId — a guest's report
      // includes its observation of every neighbor it can sample, which
      // can include the host. The host toasting itself is noise.
      if (neighborId == current.hostPeerId) continue;
      final displayName = namesByPeerId[neighborId];
      if (displayName == null) continue;
      _weakSignalEventsController.add(
        (peerId: neighborId, displayName: displayName),
      );
    }
  }

  /// Tick callback wired into [SignalReporter.start] on the guest side.
  /// Samples local RSSI via the audio service, builds a [SignalReport],
  /// and writes it to the transport. No-op when no neighbors have an
  /// RSSI to report (e.g. before the GATT client has a connection),
  /// which keeps the wire quiet during link bring-up.
  ///
  /// **Seq accounting.** Two distinct skip cases, with different rules:
  ///   * Transport / audio absent, RSSI sample throws, peerId resolve
  ///     fails — the seq counter still advances. These are failure
  ///     paths where another producer may have already used a seq, so
  ///     the next valid report needs the next number to stay monotonic.
  ///     Same defensive pattern as [_sendHeartbeat].
  ///   * Empty sample list — the seq counter does **not** advance. An
  ///     empty report is a non-event (nothing to send), so the next
  ///     report with samples picks up where we left off instead of
  ///     skipping wire-level numbers the host's SequenceFilter would
  ///     have to tolerate gaps in.
  Future<void> _sendSignalReport() async {
    final t = _transport;
    final audio = _audio;
    if (t == null || audio == null) {
      _seq++;
      return;
    }
    if (_signalReportSendInFlight) return;
    _signalReportSendInFlight = true;
    try {
      final List<({String peerId, int rssi})> samples;
      try {
        samples = await audio.getCurrentRssi();
      } catch (error, stackTrace) {
        if (kDebugMode) debugPrint('Failed to sample RSSI: $error');
        if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
        _seq++;
        return;
      }
      if (isClosed) return;
      // Empty sample list — nothing to report. Do *not* advance the seq
      // counter: an empty report is a non-event, and a future report
      // with samples should pick up where we left off rather than
      // skipping numbers (which the host's SequenceFilter tolerates but
      // is wasteful on the wire).
      if (samples.isEmpty) return;
      final String peerId;
      try {
        peerId = await identityStore.getPeerId();
      } catch (error, stackTrace) {
        if (kDebugMode) debugPrint('Failed to resolve peer id for signal report: $error');
        if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
        _seq++;
        return;
      }
      if (isClosed) return;
      final msg = SignalReport(
        peerId: peerId,
        seq: ++_seq,
        atMs: DateTime.now().millisecondsSinceEpoch,
        neighbors: [
          for (final s in samples)
            NeighborSignal(peerId: s.peerId, rssi: s.rssi),
        ],
      );
      try {
        await t.send(msg);
      } catch (error, stackTrace) {
        if (kDebugMode) debugPrint('SignalReport send failed: $error');
        if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
      }
    } finally {
      _signalReportSendInFlight = false;
    }
  }

  /// Tick callback wired into [LinkQualityReporter.start] on the guest
  /// side. Polls per-peer telemetry from the native `PeerAudioManager`,
  /// computes deltas against the previous snapshot, and writes a
  /// `LinkQuality` to the host.
  ///
  /// **Skipped paths.**
  ///   * No transport, no audio, or local user is the host → no-op.
  ///   * No `macAddress` recorded on the room state (unusual — guest
  ///     entered without a discovered host MAC) → no-op.
  ///   * First sample for this peer (no previous snapshot to delta
  ///     against) → record the snapshot and bail; the *next* tick
  ///     produces the first `LinkQuality`.
  ///   * Native side returns null telemetry (peer not registered,
  ///     handler not wired) → no-op; reset the previous snapshot so we
  ///     re-seed on the next non-null sample.
  ///
  /// **Seq accounting.** Unlike `_sendSignalReport` and `_sendHeartbeat`,
  /// this method does **not** advance the seq counter on skipped paths.
  /// The first-sample case in particular is a normal startup transient,
  /// not a failure path — burning a seq for it would put a permanent
  /// gap at the top of every guest's wire log. The other skips (missing
  /// audio / transport / host role) are static — they fire every tick
  /// while the cubit is in that mode and would burn a seq per tick if
  /// we incremented.
  Future<void> _sendLinkQuality() async {
    final current = state;
    if (isClosed || current is! SessionRoom) return;
    if (current.roomIsHost) return;
    final t = _transport;
    final audio = _audio;
    final mac = current.macAddress;
    if (t == null || audio == null || mac == null) return;
    if (_linkQualitySendInFlight) return;
    _linkQualitySendInFlight = true;
    try {
      final snapshot = await audio.getLinkTelemetry(mac);
      if (isClosed) return;
      // Re-check the room snapshot after the await: the user could have
      // left the room (or left + rejoined a different room) between the
      // tick start and the telemetry response. Mutating `_prevTelemetry`
      // after a leave would re-seed an entry the room teardown just
      // cleared; sending after a leave would write to a transport whose
      // peer we already forgot. Bail if anything changed.
      if (!_stillSameGuestRoomFor(mac)) return;
      final now = DateTime.now();
      if (snapshot == null) {
        // Native side unavailable — drop any seeded snapshot so the next
        // successful sample re-seeds rather than computing rates against
        // ancient data.
        _prevTelemetry.remove(mac);
        _prevTelemetryAt.remove(mac);
        return;
      }
      final prev = _prevTelemetry[mac];
      final prevAt = _prevTelemetryAt[mac];
      _prevTelemetry[mac] = snapshot;
      _prevTelemetryAt[mac] = now;
      if (prev == null || prevAt == null) {
        // First sample — nothing to delta against. Seed and exit.
        return;
      }
      final elapsed = now.difference(prevAt);
      // Negative or zero elapsed (clock skew) — skip computation rather
      // than throwing inside computeLinkQuality.
      if (elapsed <= Duration.zero) return;
      final rates = computeLinkQuality(
        previous: prev,
        current: snapshot,
        elapsed: elapsed,
      );
      // Prefer the cached peerId (populated during bootstrap) — this
      // tick fires every 2 s and an identityStore round-trip is a
      // measurable Hive disk hit. Fall back to the store only if the
      // cache is empty (a startup race we can't otherwise reach from
      // a guest in a SessionRoom).
      String? peerId = _localPeerId;
      if (peerId == null) {
        try {
          peerId = await identityStore.getPeerId();
          _localPeerId = peerId;
        } catch (error, stackTrace) {
          if (kDebugMode) debugPrint('Failed to resolve peer id for link quality: $error');
          if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
          return;
        }
        if (isClosed) return;
        // Same race re-check after the second possible await.
        if (!_stillSameGuestRoomFor(mac)) return;
      }
      final msg = LinkQuality(
        peerId: peerId,
        seq: ++_seq,
        atMs: now.millisecondsSinceEpoch,
        lossPct: rates.lossPct,
        jitterMs: rates.jitterMs,
        underrunsPerSec: rates.underrunsPerSec,
      );
      try {
        await t.send(msg);
      } catch (error, stackTrace) {
        if (kDebugMode) debugPrint('LinkQuality send failed: $error');
        if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
      }
    } finally {
      _linkQualitySendInFlight = false;
    }
  }

  /// True iff the cubit is still in a guest [SessionRoom] whose
  /// `macAddress` matches [mac]. Used by [_sendLinkQuality] to bail when
  /// the user left or switched rooms during a telemetry / identity
  /// await — a simple `isClosed` check would let post-await mutations
  /// poison the next room's telemetry baseline.
  bool _stillSameGuestRoomFor(String mac) {
    if (isClosed) return false;
    final s = state;
    if (s is! SessionRoom) return false;
    if (s.roomIsHost) return false;
    return s.macAddress == mac;
  }

  /// Host-only ingress for `LinkQuality`. Feeds the per-peer
  /// [BitrateAdapter]; if the adapter decides to step the level, sends
  /// a `BitrateHint` to the reporting peer **and** locally calls
  /// `setPeerBitrate` for the same peer's MAC so the host's own encoder
  /// toward that guest also tracks the new level.
  ///
  /// On a guest, `LinkQuality` from a host is silently dropped — only
  /// the host owns adapter state.
  void _onLinkQuality(LinkQuality report) {
    if (isClosed) return;
    final current = state;
    if (current is! SessionRoom || !current.roomIsHost) return;
    // Pass the host-local clock so adapter dwell windows are immune to
    // sender clock drift / spoofing (see BitrateAdapter dwell docs).
    final newLevel = _bitrateAdapter.feed(
      report,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (newLevel == null) return;
    // Adjust the host's own outbound encoder toward the reporter (best
    // effort — the audio side returns null on missing peer / handler).
    final audio = _audio;
    final macForPeer = _macForPeerId(report.peerId, current);
    if (audio != null && macForPeer != null) {
      unawaited(audio.setPeerBitrate(macForPeer, newLevel.bps));
    }
    unawaited(_sendBitrateHint(report.peerId, newLevel.bps));
  }

  /// Guest-only ingress for `BitrateHint`. Applies the hinted bitrate to
  /// the local outbound encoder (toward the host) **only if the hint
  /// targets this peer** — the host broadcasts on the GATT RESPONSE
  /// characteristic, so every connected guest receives every hint and
  /// must filter by `target == localPeerId`. Mirrors the `RemovePeer`
  /// dispatch pattern. On the host, hints are silently dropped — the
  /// host is the source of hints, not a sink.
  void _onBitrateHint(BitrateHint hint) {
    if (isClosed) return;
    final current = state;
    if (current is! SessionRoom || current.roomIsHost) return;
    final audio = _audio;
    final mac = current.macAddress;
    if (audio == null || mac == null) return;
    final localPeerId = _localPeerId;
    // No cached peerId yet → can't tell whether the hint is for us. The
    // bootstrap path always populates it before joinRoom emits a
    // SessionRoom, so this branch is defensive only.
    if (localPeerId == null || hint.target != localPeerId) return;
    unawaited(audio.setPeerBitrate(mac, hint.bps));
  }

  /// Resolve a peer's BLE MAC from the current room snapshot. Returns
  /// null when the peer isn't on the roster or has no `btDevice`
  /// recorded — both cases are treated as "skip the local
  /// `setPeerBitrate` call" rather than poisoning the adapter step.
  String? _macForPeerId(String peerId, SessionRoom room) {
    for (final p in room.roster) {
      if (p.peerId == peerId) {
        final mac = p.btDevice;
        if (mac == null || mac.isEmpty) return null;
        return mac;
      }
    }
    return null;
  }

  /// Build and send a `BitrateHint` to [targetPeerId]. Best-effort:
  /// transport-level failures are logged and swallowed so a single bad
  /// adapter step doesn't poison the rest of the dispatch loop.
  Future<void> _sendBitrateHint(String targetPeerId, int bps) async {
    final t = _transport;
    if (t == null) return;
    // Use the cached peerId (populated during bootstrap) — adapter
    // steps fire on every incoming `LinkQuality`, and an identityStore
    // round-trip per step would add a Hive disk hit per host-side adapter
    // decision. Fall back to the store only if the cache is empty.
    String? hostPeerId = _localPeerId;
    if (hostPeerId == null) {
      try {
        hostPeerId = await identityStore.getPeerId();
        _localPeerId = hostPeerId;
      } catch (error, stackTrace) {
        if (kDebugMode) debugPrint('Failed to resolve peer id for bitrate hint: $error');
        if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
        return;
      }
      if (isClosed) return;
    }
    // The envelope `peerId` is the sender's (host's) peerId per the
    // protocol convention; the wire's `target` field carries the
    // intended recipient so guests other than [targetPeerId] drop the
    // hint on receive (see [_onBitrateHint]) — the underlying GATT
    // notification broadcasts to every subscribed central, so the host
    // can't unicast at the transport layer today.
    if (kDebugMode) debugPrint('BitrateHint -> $targetPeerId: $bps bps');
    final msg = BitrateHint(
      peerId: hostPeerId,
      seq: ++_seq,
      atMs: DateTime.now().millisecondsSinceEpoch,
      target: targetPeerId,
      bps: bps,
    );
    try {
      await t.send(msg);
    } catch (error, stackTrace) {
      if (kDebugMode) debugPrint('BitrateHint send failed: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// Tick callback wired into [HeartbeatScheduler.start] on room entry.
  /// Builds + sends a single `Heartbeat` over the transport. The native
  /// layer decides whether `send` broadcasts to all subscribed centrals
  /// (host) or unicasts to the connected host (guest).
  ///
  /// The seq counter advances even when the transport is null so it
  /// stays monotonic once the BLE link comes up — same defensive pattern
  /// as [broadcastMute].
  Future<void> _sendHeartbeat() async {
    final t = _transport;
    if (t == null) {
      _seq++;
      return;
    }
    // Coalesce overlapping ticks: a slow link must not fan out into
    // concurrent transport writes that interleave fragments on the wire.
    // The flag is set *synchronously* before the first `await` below — if
    // it's set after the await on getPeerId, two ticks could both pass
    // this check, both await the peerId, and then both reach the send.
    if (_heartbeatSendInFlight) return;
    _heartbeatSendInFlight = true;
    try {
      final String peerId;
      try {
        peerId = await identityStore.getPeerId();
      } catch (error, stackTrace) {
        if (kDebugMode) debugPrint('Failed to resolve peer id for heartbeat: $error');
        if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
        _seq++;
        return;
      }
      if (isClosed) return;
      final msg = Heartbeat(
        peerId: peerId,
        seq: ++_seq,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      try {
        await t.send(msg);
      } catch (error, stackTrace) {
        // Transport-layer failures are already logged inside
        // BleControlTransport; swallow here so a single bad tick doesn't
        // poison the timer.
        if (kDebugMode) debugPrint('Heartbeat send failed: $error');
        if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
      }
    } finally {
      _heartbeatSendInFlight = false;
    }
  }

  /// Fired by [HeartbeatScheduler] when [missThreshold] elapses without
  /// a `notePingFrom` for [peerId]. Role-specific behaviour:
  ///
  ///   * **Host** — drop the peer from the local roster, clean up
  ///     transport state, and broadcast a `RosterUpdate` to the
  ///     remaining guests. Mirrors the protocol's host-as-authority
  ///     dirty-disconnect contract.
  ///   * **Guest** — only react if the lost peer is the host. Routes
  ///     into [notifyDrop] (which starts the reconnect loop) when a
  ///     MAC is on the room state, or to [leaveRoom] as a fallback
  ///     when there's nothing to dial.
  ///
  /// No-op outside `SessionRoom` (e.g. a late tick after the user has
  /// already left), or after the cubit is closed.
  void _onHeartbeatPeerLost(String peerId) {
    if (isClosed) return;
    final current = state;
    if (current is! SessionRoom) return;
    if (current.roomIsHost) {
      // Defensive guard: never react to a "lost" event for the local
      // host's own peerId — a stale watermark must not self-delete the
      // host roster entry or emit a `RosterUpdate` that erases it.
      // The host's own peerId shouldn't end up in `_lastSeen` in
      // production (we never receive our own messages back through the
      // wire), but the guard is cheap and removes the failure mode.
      if (peerId == current.hostPeerId) return;
      final updated =
          current.roster.where((p) => p.peerId != peerId).toList();
      if (updated.length == current.roster.length) return;
      emit(current.copyWith(roster: updated));
      _transport?.forgetPeer(peerId);
      _weakSignalDetector.forgetPeer(peerId);
      final t = _transport;
      if (t == null) return;
      // Best-effort RosterUpdate to remaining guests. We need a peerId
      // for the envelope; resolve lazily and fire-and-forget.
      unawaited(_broadcastRosterUpdate(updated));
    } else {
      // Guest: only the host's silence matters. A guest going quiet is
      // the host's problem to handle and broadcast — we'd just hear
      // about it via a `RosterUpdate`.
      if (peerId != current.hostPeerId) return;
      // Drop the transport's idempotency state for the host before the
      // reconnect attempt: the fresh `JoinAccepted` after reconnect
      // restarts seq at 1 per protocol, and a stale watermark of, say, 7
      // from this session would otherwise swallow the new session's seqs
      // 1–7.
      _transport?.forgetPeer(peerId);
      _heartbeats.forgetPeer(peerId);
      final mac = current.macAddress;
      if (mac != null) {
        unawaited(notifyDrop(macAddress: mac));
      } else {
        unawaited(leaveRoom());
      }
    }
  }

  Future<void> _broadcastRosterUpdate(List<ProtocolPeer> roster) async {
    final t = _transport;
    if (t == null) return;
    final String peerId;
    try {
      peerId = await identityStore.getPeerId();
    } catch (error, stackTrace) {
      if (kDebugMode) debugPrint('Failed to resolve peer id for roster update: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
      return;
    }
    if (isClosed) return;
    final msg = RosterUpdate(
      peerId: peerId,
      seq: ++_seq,
      atMs: DateTime.now().millisecondsSinceEpoch,
      roster: roster,
    );
    unawaited(t.send(msg));
  }

  /// Called when local voice activity detection triggers. Sends a [TalkingState]
  /// message over the BLE control transport to notify other peers about the
  /// local user's speaking state.
  ///
  /// Only sends when in a room and when the transport is wired. If the transport
  /// is absent, the seq counter still advances so messages stay monotonic once
  /// the transport connects. Uses cached [_localPeerId] to avoid async resolution
  /// and ensure sequence numbers are assigned at event time (no race).
  ///
  /// Wire ordering — preventing fragments from a flapping VAD detector
  /// interleaving on the wire — is enforced by [BleControlTransport.send]
  /// itself, which serialises concurrent callers through an internal
  /// chain. This handler can therefore stay a fire-and-forget
  /// `unawaited` while still satisfying the protocol's strict-monotonic
  /// per-producer seq contract.
  void _onLocalTalking(bool talking) {
    final current = state;
    if (isClosed || current is! SessionRoom) return;

    final t = _transport;
    final peerId = _localPeerId;

    // Assign seq synchronously at event time. The listener runs to
    // completion before the next VAD edge dispatches, so seq numbers
    // strictly track the order edges were observed.
    final seq = ++_seq;

    if (t == null || peerId == null) {
      return; // seq already incremented; talking-state isn't sendable
    }

    final msg = TalkingState(
      peerId: peerId,
      seq: seq,
      atMs: DateTime.now().millisecondsSinceEpoch,
      talking: talking,
    );
    // Fire-and-forget send — the transport's internal chain serialises
    // wire writes so seq order is preserved even under flapping VAD.
    // `catchError` swallows transport-level failures (e.g. a write that
    // throws on a closing GATT link) so an unawaited reject doesn't
    // bubble to the unhandled-async-error handler.
    unawaited(t.send(msg).catchError((Object error, StackTrace stackTrace) {
      if (kDebugMode) debugPrint('TalkingState send failed: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
      return false;
    }));
  }

  /// Persists [name] and advances to Discovery. The state changes even if
  /// the write fails so the user isn't stranded on the name screen.
  Future<void> completeOnboarding(String name) async {
    try {
      await identityStore.setDisplayName(name);
    } catch (error, stackTrace) {
      if (kDebugMode) debugPrint('Failed to persist display name: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
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
      if (kDebugMode) debugPrint('Failed to persist display name: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
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
      case SessionPermissionDenied():
        break;
    }
  }

  /// Enters Room. [isHost] is true when the user created the frequency,
  /// false when they tuned in to an existing one. The [freq] argument is
  /// required on the guest path (it carries the discovered MHz string)
  /// and ignored on the host path (the room frequency is derived from a
  /// freshly-minted sessionUuid). No-op if the user isn't on Discovery
  /// (shouldn't happen — Discovery is the only screen that triggers it).
  ///
  /// **Host path.** Mints a fresh `sessionUuid`, derives the room's
  /// cosmetic [roomFreq] from its low 12 bits (the same mapping guests
  /// use when decoding the advertisement), self-seeds the roster with
  /// the local user, and asks the audio service to start LE advertising
  /// + the GATT server so other phones can see and dial the room. The
  /// [freq] argument is ignored on this path — the freshly-minted UUID
  /// is the source of truth for both the cosmetic display and what
  /// guests will eventually see in their discovery list. Recorded to
  /// the recent-hosted list as a side-effect.
  ///
  /// **Guest path.** Uses [freq] as the room's cosmetic display (it
  /// already matches the advertised UUID's mhzDisplay since both flow
  /// from the same protocol mapping). [macAddress] and [sessionUuidLow8]
  /// come from the discovered advertisement and are stored on
  /// `SessionRoom` so the GATT-client transport can dial the host later
  /// (the actual `connectToHost` call lands in #43). On the host path
  /// both are null — the local user *is* the host, so there's no remote
  /// to dial.
  ///
  /// Resets the per-link sequence counter to 0 so the next sent message
  /// starts at `seq = 1` per the protocol's reconnect rule.
  ///
  /// Recent-frequency persistence runs in the background — a failure or
  /// slow disk shouldn't block the transition into the room. The updated
  /// list shows up the next time the user lands on Discovery (via
  /// [leaveRoom]'s re-read).
  Future<void> joinRoom({
    required bool isHost,
    String? freq,
    String? macAddress,
    String? sessionUuidLow8,
  }) async {
    final current = state;
    if (current is! SessionDiscovery) return;
    _seq = 0;
    final SessionRoom room;
    if (isHost) {
      // Mint the canonical session identity. Everything else on the host
      // path (advertised manufacturer payload, cosmetic mhz, hostPeerId
      // self-seed) flows from this UUID + the local peerId.
      final sessionUuid = _mintSessionUuid();
      // Resolve the local peerId for the self-seed. The cache covers
      // the common case where bootstrap has already run; falls back to
      // the store otherwise. A hard failure aborts the host path —
      // hostPeerId is load-bearing for the protocol's message
      // attribution, and seeding the room without it would just put the
      // user into a broken state they'd have to leave anyway.
      String? hostPeerId = _localPeerId;
      if (hostPeerId == null) {
        try {
          hostPeerId = await identityStore.getPeerId();
          _localPeerId = hostPeerId;
        } catch (error, stackTrace) {
          if (kDebugMode) debugPrint('Failed to load peerId for host bootstrap: $error');
          if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
          return;
        }
      }
      if (isClosed) return;
      // Re-read state after the await — `rename()` could have fired in
      // the gap, and the captured `current.myName` would be stale.
      // `leaveRoom()` isn't possible from Discovery, but a state
      // transition out of Discovery still means the user no longer wants
      // this room and we should bail.
      final afterAwait = state;
      if (afterAwait is! SessionDiscovery) return;
      final myName = afterAwait.myName;
      final session = FrequencySession(
        sessionUuid: sessionUuid,
        hostPeerId: hostPeerId,
      );
      final roomFreq = session.mhzDisplay;
      // Fire-and-forget: the user has already committed to entering the
      // room, so we shouldn't await disk I/O before emitting. Errors are
      // logged on the future and surfaced on next launch as a missing
      // entry; nothing else depends on success here.
      unawaited(_recordRecentFrequency(roomFreq));
      room = SessionRoom(
        myName: myName,
        roomFreq: roomFreq,
        roomIsHost: true,
        hostPeerId: hostPeerId,
        roster: [ProtocolPeer(peerId: hostPeerId, displayName: myName)],
      );
      emit(room);
      // Kick off the BLE side. Both calls return false on permission /
      // OEM rejection; we don't block the room transition on either,
      // matching the existing pattern for non-fatal native-side failures.
      // The native implementations land in #41 (advertiser) and the
      // existing #38 (GATT server, already wired). Symmetric teardown
      // happens in [leaveRoom] and [close].
      final audio = _audio;
      if (audio != null) {
        unawaited(audio.startAdvertising(
          sessionUuid: sessionUuid,
          displayName: myName,
        ));
        unawaited(audio.startGattServer());
      }
    } else {
      if (freq == null) {
        if (kDebugMode) debugPrint('joinRoom guest path requires a freq; refusing to enter the room.');
        return;
      }
      room = SessionRoom(
        myName: current.myName,
        roomFreq: freq,
        roomIsHost: false,
        macAddress: macAddress,
        sessionUuidLow8: sessionUuidLow8,
      );
      emit(room);
    }
    // Begin the heartbeat plane for the lifetime of the room. Pings the
    // wire every interval and watches inbound activity for silent peers
    // (host) / a silent host (guest). Calling start() is idempotent —
    // re-entry into a fresh room will reset its watermarks.
    //
    // Skipped when no transport is wired: there's no wire to ping and no
    // peers to detect silence on. Avoids leaking a long-running periodic
    // timer in widget tests that exercise the cubit in loopback mode.
    if (_transport != null) {
      _heartbeats.start(
        onTick: () => unawaited(_sendHeartbeat()),
        onPeerLost: _onHeartbeatPeerLost,
      );
    }
    // Begin the signal-report plane on the guest side. The host receives
    // reports from guests and turns them into weak-signal toasts; it
    // doesn't send reports to itself. Audio is required to sample RSSI;
    // skipped when audio or transport is absent, same rationale as the
    // heartbeat skip above.
    if (!isHost && _transport != null && _audio != null) {
      _signalReporter.start(
        onTick: () => unawaited(_sendSignalReport()),
      );
      // Begin the link-quality plane on the guest side. Same gating as
      // the signal reporter — needs a transport to write to and an
      // audio service to poll telemetry from. The host doesn't run the
      // reporter (it consumes incoming `LinkQuality` reports instead;
      // see [_onLinkQuality]).
      _linkQualityReporter.start(
        onTick: () => unawaited(_sendLinkQuality()),
      );
    }
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
    // Symmetric teardown of the host BLE surfaces booted in joinRoom.
    // Without this the device keeps advertising and serving GATT after
    // the host backs out — strangers nearby would still see the room and
    // could connect to a phantom session. Guests don't own these so we
    // gate on roomIsHost. Both calls are unawaited to mirror the start
    // pattern; failures log on the audio service.
    if (current.roomIsHost) {
      final audio = _audio;
      if (audio != null) {
        unawaited(audio.stopAdvertising());
        unawaited(audio.stopGattServer());
      }
    }
    // Stop any in-progress reconnect so BLE retries halt promptly when
    // the user manually leaves rather than waiting for the next delay tick.
    _reconnectController?.cancel();
    _reconnectController = null;
    _joinAcceptedWatchdog?.cancel();
    _joinAcceptedWatchdog = null;
    // Cancel the heartbeat timer so it doesn't keep ticking against an
    // empty roster (and incidentally trigger a phantom RosterUpdate if
    // a stale watermark expires post-leave).
    _heartbeats.stop();
    // Cancel the signal reporter so a guest leaving doesn't keep pinging
    // RSSI samples at the (now disconnected) GATT link.
    _signalReporter.stop();
    // Cancel the link-quality reporter for the same reason — and wipe
    // the per-peer telemetry baseline so a fresh room doesn't compute
    // bogus deltas against the previous session's last sample.
    _linkQualityReporter.stop();
    _prevTelemetry.clear();
    _prevTelemetryAt.clear();
    _bitrateAdapter.clear();
    // Wipe per-neighbor weak-signal state so a fresh room starts with a
    // clean detector — no stale rate-limit cooldowns, no inherited
    // consecutive-weak counters from the previous session.
    _weakSignalDetector.clear();
    // Wipe transport-side idempotency state for *every* peer of the
    // departing room. A re-join (same room or different) restarts the
    // protocol's seq counters at 1; held-over watermarks from this room
    // would otherwise swallow the next session's first messages.
    _transport?.forgetAllPeers();
    _seq = 0;
    final recent = await _loadRecentFrequencies();
    if (isClosed) return;
    emit(SessionDiscovery(
      myName: current.myName,
      recentHostedFrequencies: recent,
    ));
  }

  /// Reacts to a [PermissionWatcher] emission. Three cases:
  ///
  ///   * **Missing → empty**: the user re-granted everything (typically by
  ///     coming back from Settings). If we're sitting in
  ///     [SessionPermissionDenied], transition back to [SessionDiscovery]
  ///     (or [SessionOnboarding] for a fresh install). Otherwise leave the
  ///     state alone — the user might be mid-onboarding and the watcher's
  ///     resume sample is just confirming what onboarding already knows.
  ///
  ///   * **Empty → missing**: the user revoked while the app was running.
  ///     Tear down voice + BLE so the next OS callback can't fault on a
  ///     missing permission, then emit [SessionPermissionDenied] carrying
  ///     the displayName so recovery can route back to Discovery without
  ///     re-reading the identity store.
  ///
  ///   * **Missing → different missing**: e.g. the user re-granted mic but
  ///     left bluetooth off. Just refresh the missing list so the screen
  ///     shows the current state.
  ///
  /// Onboarding is left untouched — that screen owns its own permission
  /// flow and would fight a state transition mid-grant. Once onboarding
  /// completes the cubit lands on Discovery, where the watcher's next
  /// emission can take over.
  void _onPermissionsChanged(List<AppPermission> missing) {
    if (isClosed) return;
    final current = state;
    if (missing.isEmpty) {
      // Recovered — only meaningful when we're already showing the denied
      // screen. From any other stage, an "all granted" event is a no-op.
      if (current is SessionPermissionDenied) {
        unawaited(_recoverFromPermissionDenied(current));
      }
      return;
    }
    // Onboarding owns its own permission flow; don't yank the user out
    // mid-grant. Booting is a transient pre-bootstrap blip — let bootstrap
    // finish and the next watcher tick will catch it.
    if (current is SessionOnboarding || current is SessionBooting) {
      return;
    }
    // Already showing the denied screen — just refresh the missing list
    // (e.g. mic was re-granted but bluetooth still off).
    if (current is SessionPermissionDenied) {
      emit(SessionPermissionDenied(
        missing: missing,
        myName: current.myName,
      ));
      return;
    }
    // Discovery or Room — tear down audio/BLE and surface the denied screen.
    final myName = switch (current) {
      SessionDiscovery(:final myName) => myName,
      SessionRoom(:final myName) => myName,
      _ => null,
    };
    unawaited(_teardownForPermissionRevoke());
    if (isClosed) return;
    emit(SessionPermissionDenied(missing: missing, myName: myName));
  }

  /// Stop voice + BLE side-effects on revoke without going through
  /// [leaveRoom] (which would emit an intermediate [SessionDiscovery]).
  /// Mirrors [leaveRoom]'s cleanup minus the state transition; see that
  /// method for the per-step rationale.
  Future<void> _teardownForPermissionRevoke() async {
    _reconnectController?.cancel();
    _reconnectController = null;
    _joinAcceptedWatchdog?.cancel();
    _joinAcceptedWatchdog = null;
    _heartbeats.stop();
    _signalReporter.stop();
    _linkQualityReporter.stop();
    _prevTelemetry.clear();
    _prevTelemetryAt.clear();
    _bitrateAdapter.clear();
    _weakSignalDetector.clear();
    _transport?.forgetAllPeers();
    _seq = 0;
    // Best-effort native teardown — failures are already logged inside
    // AudioService and must not block the state transition.
    final audio = _audio;
    if (audio != null) {
      try {
        await audio.stopVoice();
      } catch (error, stackTrace) {
        debugPrint('stopVoice during permission revoke failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      try {
        await audio.stopService();
      } catch (error, stackTrace) {
        debugPrint('stopService during permission revoke failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  /// Transition out of [SessionPermissionDenied] now that the watcher has
  /// reported all permissions granted. Routes to [SessionDiscovery] when
  /// a display name is on hand (the typical case — the user had already
  /// onboarded), or to [SessionOnboarding] otherwise.
  ///
  /// Identity-checks the current state right before the final emit: between
  /// the watcher's "all granted" signal and the recent-frequencies disk
  /// read, the user could have toggled a permission off again and the
  /// watcher could have pushed a fresh denied state through. Each
  /// [_onPermissionsChanged] call emits a *new* [SessionPermissionDenied]
  /// instance, so checking `identical(state, current)` rather than
  /// `state is! SessionPermissionDenied` correctly distinguishes "same
  /// denied state we entered recovery from" (safe to emit Discovery) from
  /// "a newer denied state replaced it during the await" (don't clobber).
  Future<void> _recoverFromPermissionDenied(
    SessionPermissionDenied current,
  ) async {
    final myName = current.myName;
    if (myName == null) {
      if (isClosed) return;
      if (!identical(state, current)) return;
      emit(const SessionOnboarding());
      return;
    }
    final recent = await _loadRecentFrequencies();
    if (isClosed) return;
    if (!identical(state, current)) return;
    emit(SessionDiscovery(
      myName: myName,
      recentHostedFrequencies: recent,
    ));
  }

  /// Asks the [PermissionWatcher] to re-sample now. Wired to the "Retry"
  /// button on the permission-denied screen so the user doesn't have to
  /// wait up to one poll interval after re-granting in Settings. No-op when
  /// no watcher was injected (loopback / test builds).
  Future<void> recheckPermissions() async {
    await _permissionWatcher?.checkNow();
  }

  Future<List<RecentFrequency>> _loadRecentFrequencies() async {
    try {
      return await recentFrequenciesStore.getRecentDetailed();
    } catch (error, stackTrace) {
      if (kDebugMode) debugPrint('Failed to load recent frequencies: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
      return const [];
    }
  }

  Future<void> _recordRecentFrequency(String freq) async {
    try {
      await recentFrequenciesStore.record(freq);
    } catch (error, stackTrace) {
      if (kDebugMode) debugPrint('Failed to record recent frequency: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// Persists [nickname] (or clears it when null/empty) for the recent
  /// frequency [freq], then re-emits [SessionDiscovery] so the Discovery
  /// list updates without waiting for a leave/rejoin to refresh state.
  /// No-op when the cubit is not in [SessionDiscovery] — naming a recent
  /// only makes sense from the screen that renders them.
  ///
  /// Failures from the store are logged and swallowed so the user isn't
  /// blocked on a transient sqlite error; the in-memory state is rolled
  /// back to whatever the next read sees by re-loading the list.
  Future<void> setRecentNickname(String freq, String? nickname) async {
    final current = state;
    if (current is! SessionDiscovery) return;
    try {
      await recentFrequenciesStore.setNickname(freq, nickname);
    } catch (error, stackTrace) {
      if (kDebugMode) debugPrint('Failed to set recent nickname: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
    }
    if (isClosed) return;
    final refreshed = await _loadRecentFrequencies();
    if (isClosed) return;
    if (state is! SessionDiscovery) return;
    emit(SessionDiscovery(
      myName: current.myName,
      recentHostedFrequencies: refreshed,
    ));
  }

  /// Pins or unpins [freq] in the persisted recents, then re-emits
  /// [SessionDiscovery] so the Discovery list resorts (pinned rows float
  /// to the top). Same scope and failure behavior as [setRecentNickname].
  Future<void> setRecentPinned(String freq, bool pinned) async {
    final current = state;
    if (current is! SessionDiscovery) return;
    try {
      await recentFrequenciesStore.setPinned(freq, pinned);
    } catch (error, stackTrace) {
      if (kDebugMode) debugPrint('Failed to set recent pinned: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
    }
    if (isClosed) return;
    final refreshed = await _loadRecentFrequencies();
    if (isClosed) return;
    if (state is! SessionDiscovery) return;
    emit(SessionDiscovery(
      myName: current.myName,
      recentHostedFrequencies: refreshed,
    ));
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
    _joinAcceptedWatchdog?.cancel();
    _joinAcceptedWatchdog = null;
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
      return;
    }

    // On success: GATT link is re-established, but we still need the host's
    // JoinAccepted to complete the rejoin. Start a 10 s watchdog: if the
    // host never sends JoinAccepted (host died, session UUID changed, GATT
    // subscription failed silently, ...), bail to lost + Discovery rather
    // than waiting forever.
    _joinAcceptedWatchdog?.cancel();
    _joinAcceptedWatchdog = Timer(_joinAcceptedTimeout, () async {
      if (isClosed) return;
      final watchdogState = state;
      // Guard: applyJoinAccepted already fired and cleared to online, or the
      // user manually left. Don't overwrite a healthy or exited state.
      if (watchdogState is! SessionRoom ||
          watchdogState.connectionPhase != ConnectionPhase.reconnecting) {
        return;
      }
      // Host never sent JoinAccepted after native reconnect succeeded —
      // treat it like a full connection loss.
      emit(watchdogState.copyWith(connectionPhase: ConnectionPhase.lost));
      await leaveRoom();
    });
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
      if (kDebugMode) debugPrint('Failed to resolve peer id for media command: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
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
      if (kDebugMode) debugPrint('Failed to resolve peer id for mute broadcast: $error');
      if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
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
    // Tear down the host BLE surfaces if the cubit is closing while the
    // local user is still the host. Without this, killing the cubit
    // (e.g. test teardown, app disposal mid-session) leaves the platform
    // advertiser + GATT server running until the OS reaps the
    // foreground service. Mirrors the leaveRoom path; same gating on
    // roomIsHost.
    final current = state;
    if (current is SessionRoom && current.roomIsHost) {
      final audio = _audio;
      if (audio != null) {
        unawaited(audio.stopAdvertising());
        unawaited(audio.stopGattServer());
      }
    }
    // Cancel an in-progress reconnect before closing so the attempt loop
    // won't call emit() or leaveRoom() after the cubit is disposed.
    _reconnectController?.cancel();
    _joinAcceptedWatchdog?.cancel();
    // Stop the heartbeat timer before super.close() so a tick suspended
    // mid-microtask can't try to emit() against a closing cubit.
    _heartbeats.stop();
    // Same rationale: stop the signal reporter before super.close() so a
    // tick mid-await can't reach _onSignalReport or transport.send on a
    // disposed cubit.
    _signalReporter.stop();
    // And the link-quality reporter — same pre-close rationale.
    _linkQualityReporter.stop();
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
    // Drop the permission subscription before closing the broadcast
    // controllers so a final watcher tick can't try to emit() against the
    // closing cubit. The watcher itself is owned by the caller (not the
    // cubit) — the same instance survives across re-bootstraps in tests,
    // so we don't dispose it here.
    await _permissionSubscription?.cancel();
    await _mediaCommandsController.close();
    await _weakSignalEventsController.close();
  }
}
