import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/frequency_session_cubit.dart';
import '../bloc/frequency_session_state.dart';
import '../data/frequency_models.dart';
import '../protocol/messages.dart';
import '../protocol/peer.dart';
import '../services/audio_service.dart';
import '../services/blocked_peers_store.dart';
import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';
import '../widgets/frequency_toast_host.dart';
import '../widgets/invite_sheet.dart';
import '../widgets/now_playing_card.dart';
import '../widgets/output_sheet.dart';
import '../widgets/peer_drawer.dart';
import '../widgets/peer_row.dart';
import '../widgets/push_to_talk_button.dart';
import '../widgets/media_source_sheet.dart';
import '../widgets/queue_sheet.dart';

/// Main "On air" room — voice + now playing.
class FrequencyRoomScreen extends StatefulWidget {
  final String freq;
  final MediaKind mediaKind;
  final bool pttMode;
  final bool isHost;
  final String myName;
  final VoidCallback onLeave;

  /// Native audio bridge. Optional so widget tests that want to inject a
  /// mock or fake can pass one explicitly; production wiring should pass
  /// `context.read<AudioService>()` so the screen shares the singleton the
  /// rest of the app sees (see #129). When omitted, the screen falls back
  /// to `context.read<AudioService>()` — never a fresh instance — to
  /// guarantee one `AudioService` per process at runtime.
  final AudioService? audioService;

  const FrequencyRoomScreen({
    super.key,
    required this.freq,
    required this.mediaKind,
    required this.pttMode,
    required this.isHost,
    required this.myName,
    required this.onLeave,
    this.audioService,
  });

  @override
  State<FrequencyRoomScreen> createState() => _FrequencyRoomScreenState();
}

class _FrequencyRoomScreenState extends State<FrequencyRoomScreen> {
  late Person _me;

  bool _meMuted = false;
  bool _holdingPtt = false;
  /// Per-peer playback volume, keyed by peerId. Populated lazily —
  /// only entries the user has explicitly adjusted exist; everything
  /// else reads through [_volumeFor] which falls back to
  /// [_kDefaultPeerVolume]. Null-asserting (`_volumes[peerId]!`) on
  /// a cubit-driven peer will throw because the entry doesn't exist
  /// yet, so always go through the helper instead of the raw map.
  final Map<String, double> _volumes = {};
  static const double _kDefaultPeerVolume = 0.7;
  double _volumeFor(String peerId) => _volumes[peerId] ?? _kDefaultPeerVolume;
  /// Mirrors the contents of [BlockedPeersStore] for the lifetime of
  /// this screen. Hydrated on initState (asynchronously — until the
  /// first read resolves the set is empty, which means a freshly-joined
  /// room renders unmuted-by-default for a frame or two before the
  /// persisted choices land). Mutations here are mirrored back to the
  /// store so the user's mute survives leave/rejoin and app restart
  /// (#125). Keyed by stable peerId; `_me`'s 'me' sentinel is never
  /// persisted (we early-return before touching the store).
  final Set<String> _peerMuted = {};
  late final BlockedPeersStore _blockedPeersStore;
  final Set<String> _removed = {};

  Timer? _progressTimer;
  StreamSubscription<MediaCommand>? _mediaSub;
  StreamSubscription<Map<String, dynamic>>? _audioEventsSub;
  StreamSubscription<({String peerId, String displayName})>?
      _weakSignalSub;

  /// Local peer's stable id, resolved once asynchronously from the
  /// identity store. Until it lands, originator-vs-remote attribution
  /// in [_onMediaCommand] falls back to "treat as remote." That's
  /// safe — the identity-store read returns within a couple of frames
  /// in practice, and any commands that arrive earlier are loopback
  /// from the local user anyway.
  String? _myPeerId;

  /// The last `MediaState` snapshot we snapped the local player to.
  /// Used by [_applyMediaSnapshot] to short-circuit redundant applies —
  /// `didChangeDependencies` can fire on rotation / keyboard inset
  /// changes / route restorations, and we don't want to clobber the
  /// player's own progress on every one of those.
  MediaState? _appliedSnapshot;

  /// One-shot guard for the initial snapshot read in
  /// [didChangeDependencies]. Subsequent rejoin snapshots come through
  /// the `BlocListener` in [build].
  bool _didReadInitialSnapshot = false;

  int _trackIdx = 0;
  bool _playing = false;
  int _progress = 0;
  late _LastAction _lastAction;
  AudioOutput _output = AudioOutput.speaker;

  /// The canonical media source for this session — the `source` string
  /// the protocol uses (`'Podcasts'`, `'YouTube Music'`, etc). Seeded
  /// from `widget.mediaKind` and replaced wholesale by
  /// [_applyMediaSnapshot] when the host's view differs (e.g. rejoining
  /// a room whose host switched sources). Build text and every outgoing
  /// `sendMediaCommand` reads from this so post-snapshot commands carry
  /// the host's source rather than the screen's initial intent.
  late String _source;
  late MediaSourceLib _lib;
  Track get _track => _lib.queue[_trackIdx];

  bool get _meEffectivelyMuted => widget.pttMode ? !_holdingPtt : _meMuted;

  late final AudioService _audio;

  @override
  void initState() {
    super.initState();
    final firstName = widget.myName.isEmpty ? 'You' : widget.myName;
    final initials = (firstName.length >= 2 ? firstName.substring(0, 2) : firstName).toUpperCase();
    _me = Person(
      id: 'me',
      name: firstName,
      initials: initials,
      hue: 145,
      // Filled in once a real audio-route is reported by the platform; until
      // then the row reads the audio-output label rather than this string,
      // so an empty placeholder is safe and avoids leaking a hard-coded
      // device name to real users.
      btDevice: '',
    );
    _meMuted = widget.pttMode;

    _source = widget.mediaKind == MediaKind.podcast ? 'Podcasts' : 'YouTube Music';
    _lib = emptyMediaLib;
    _lastAction = const _LastAction(by: '', action: '', when: '');

    _audio = widget.audioService ?? context.read<AudioService>();
    _blockedPeersStore = context.read<BlockedPeersStore>();
    unawaited(_hydratePersistedMutes());
    // Guard against a future caller silently constructing a second
    // AudioService and passing it through `widget.audioService` while a
    // different instance is also wired into the provider — their
    // audioEvents/controlBytes stream caches diverge and event-routing
    // bugs become very hard to trace (#129). The provider is the single
    // source of truth.
    assert(identical(_audio, context.read<AudioService>()));
    // Start the foreground service first so the OS elevates process priority
    // before AudioRecord opens — avoids the mic being killed when the screen
    // turns off during the capture-engine init window. Then spin up voice and
    // push the initial mute state + audio routing. The sequence matters:
    // pushing `setMuted`/`setAudioOutput` before `startVoice` finishes would
    // race the engine init on slower devices.
    //
    // The `mounted` check guards against the user leaving the room before
    // startVoice resolves — without it, the trailing calls would land after
    // dispose has fired stopVoice and tell a torn-down engine to change state.
    final cubit = context.read<FrequencySessionCubit>();
    // Seed _myPeerId from the cubit's already-cached localPeerId so the
    // roster filter is correct from frame 0, eliminating the flash where
    // the local user briefly appears as a peer (issue #222).
    _myPeerId = cubit.localPeerId;
    unawaited(() async {
      final serviceStarted = await _audio.startService(freq: widget.freq);
      if (!mounted || !serviceStarted) return;
      final started = await _audio.startVoice();
      if (!mounted || !started) return;

      // Re-read mute state after await in case user toggled during startup
      final currentMuted = _meEffectivelyMuted;
      await _audio.setMuted(currentMuted);
      // Broadcast initial mute state to peers via the BLE control plane
      // (once wired). Until then, this is a no-op.
      unawaited(cubit.broadcastMute(currentMuted));

      // Set initial audio output routing. If it fails (e.g., no Bluetooth
      // device when _output is bluetooth), keep the UI selection but log it.
      final routed = await _audio.setAudioOutput(_output.name);
      if (!routed) {
        if (kDebugMode) debugPrint('Failed to route to ${_output.name}, device may be unavailable');
      }
    }());

    // Listen for audio device changes from the native layer (e.g., AirPods
    // connecting/disconnecting). The native AudioRoutingManager auto-routes
    // when a Bluetooth device appears and notifies us here so the UI can
    // reflect the change.
    _audioEventsSub = _audio.audioEvents.listen((event) {
      if (!mounted) return;
      final type = event['type'] as String?;
      if (type == 'audioOutputChanged') {
        final outputStr = event['output'] as String?;
        if (outputStr != null) {
          final newOutput = AudioOutput.values.firstWhere(
            (e) => e.name == outputStr,
            orElse: () => _output,
          );
          setState(() {
            _output = newOutput;
            if (newOutput == AudioOutput.bluetooth) {
              // Record that a BT device is active. Use the name from the event
              // if provided; otherwise keep the current known name or fall back
              // to a generic placeholder so the row in the output sheet is
              // shown as enabled (not greyed-out).
              final btNameFromEvent = event['btName'] as String?;
              if (btNameFromEvent != null && btNameFromEvent.isNotEmpty) {
                _me = Person(
                  id: _me.id, name: _me.name,
                  initials: _me.initials, hue: _me.hue,
                  btDevice: btNameFromEvent,
                );
              } else if (_me.btDevice.isEmpty) {
                _me = Person(
                  id: _me.id, name: _me.name,
                  initials: _me.initials, hue: _me.hue,
                  btDevice: 'Bluetooth',
                );
              }
            } else if (_me.btDevice.isNotEmpty) {
              // Native routed away from Bluetooth (device disconnected or
              // switched by the system). Clear btDevice so the BT row in
              // the output picker is shown as disabled.
              _me = Person(
                id: _me.id, name: _me.name,
                initials: _me.initials, hue: _me.hue,
                btDevice: '',
              );
            }
          });
        }
      } else if (type == 'leaveRoom') {
        widget.onLeave();
      } else if (type == 'pttToggle' || type == 'muteToggle') {
        // Notification action button or wired/Bluetooth headset
        // play/pause. PTT and Mute on the lock screen both flip the
        // user's *effective* voice state (issue #97):
        //   - PTT mode → toggle the held flag (a single hardware
        //     button can't express press-and-hold).
        //   - Open-mic mode → toggle the persistent mute.
        // Distinct labels in the notification are for affordance only;
        // either button reaches the same toggle.
        if (widget.pttMode) {
          _setPttHolding(!_holdingPtt);
        } else {
          _setOpenMicMuted(!_meMuted);
        }
      }
    });

    _resolveMyPeerId();
    _startProgressTick();

    // Subscribe to host-side weak-signal events from the cubit. Only the
    // host emits; on guests the stream is silent so the subscription is
    // a no-op. The cubit owns the threshold + rate-limit; the screen
    // just renders. Subscribing here (not in didChangeDependencies)
    // keeps the lifecycle symmetric with the other initState wiring.
    _weakSignalSub = context
        .read<FrequencySessionCubit>()
        .weakSignalEvents
        .listen(_onWeakSignal);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final cubit = context.read<FrequencySessionCubit>();
    _mediaSub ??= cubit.mediaCommands.listen(_onMediaCommand);
    // Apply any mediaState snapshot that landed in `JoinAccepted` before
    // this screen mounted. Gated by a one-shot so theme/locale-driven
    // re-fires of `didChangeDependencies` don't yank the player back —
    // rejoin updates after this point arrive via the BlocListener in
    // [build].
    if (!_didReadInitialSnapshot) {
      _didReadInitialSnapshot = true;
      final current = cubit.state;
      if (current is SessionRoom && current.mediaState != null) {
        _applyMediaSnapshot(current.mediaState!);
      }
    }
  }

  Future<void> _resolveMyPeerId() async {
    // Fast path: cubit already cached the id during bootstrap (the normal
    // production case). Skip the extra identity-store round-trip entirely.
    if (_myPeerId != null) return;
    try {
      final peerId = await context.read<FrequencySessionCubit>().identityStore.getPeerId();
      if (!mounted) return;
      // setState triggers a re-render so the roster filter uses the
      // resolved id (only reached when bootstrap hadn't completed yet).
      setState(() => _myPeerId = peerId);
    } catch (_) {
      // Identity store failure is non-fatal here: if this one-time read
      // fails, attribution falls back to "remote sender" for this
      // screen session, which doesn't matter for in-frame UX.
    }
  }

  /// Mirrors a peer-drawer mute toggle to [BlockedPeersStore]. The
  /// 'me' sentinel is never persisted — it isn't a real peerId and
  /// would corrupt the table for any other peer that happens to share
  /// the literal id. Errors are swallowed so a transient sqflite hiccup
  /// can't crash the screen from the drawer's `onChanged` callback;
  /// the in-memory set already reflects the user's intent for this
  /// session.
  Future<void> _persistMute(String peerId, bool muted) async {
    if (peerId == _me.id) return;
    try {
      if (muted) {
        await _blockedPeersStore.block(peerId);
      } else {
        await _blockedPeersStore.unblock(peerId);
      }
    } catch (_) {
      // Best-effort write; see doc above.
    }
  }

  /// Pulls the persisted blocked-peer set into [_peerMuted] on first
  /// build. Failures are non-fatal — a sqflite read error means the
  /// session simply renders without prior blocks (the next user-driven
  /// toggle still tries to write through, which is the right behaviour
  /// for a transient open failure).
  Future<void> _hydratePersistedMutes() async {
    try {
      final persisted = await _blockedPeersStore.getAll();
      if (!mounted || persisted.isEmpty) return;
      setState(() {
        _peerMuted.addAll(persisted);
      });
    } catch (_) {
      // Same rationale as [_resolveMyPeerId]: a one-time read miss
      // doesn't justify aborting the room render.
    }
  }

  /// Build a placeholder [MediaSourceLib] sized to cover [trackIdx]
  /// (i.e. with `trackIdx + 1` `Track 1 … Track N` entries) for the
  /// given [source].
  ///
  /// Used by both [_applyMediaSnapshot] and [_onMediaCommand]'s
  /// `queuePlay` branch so any protocol-level `trackIdx` the host
  /// hands us is guaranteed to land inside `_lib.queue` — without
  /// this, a `queuePlay(trackIdx: 5)` against a 1-element placeholder
  /// queue would `RangeError` on the next read of `_track` /
  /// `_lib.queue[_trackIdx]` (Copilot review on PR #153).
  ///
  /// Track duration is generous (`max(60s, 2 × positionSec)`) so the
  /// slider has room without claiming a precise length we don't have
  /// (title/artwork metadata isn't on the wire yet — #TBD).
  MediaSourceLib _buildPlaceholderLib({
    required String source,
    required int trackIdx,
    int positionSec = 0,
  }) {
    final clampedIdx = trackIdx < 0 ? 0 : trackIdx;
    final placeholderDurationSec =
        positionSec * 2 < 60 ? 60 : positionSec * 2;
    return MediaSourceLib(
      name: source,
      kind: emptyMediaLib.kind,
      queue: [
        for (var i = 0; i <= clampedIdx; i++)
          Track(
            title: 'Track ${i + 1}',
            artist: source,
            durationSeconds: placeholderDurationSec,
            tag: '',
          ),
      ],
    );
  }

  /// Snap the local player to the canonical state the host published.
  /// Called on initial entry (snapshot from the JoinAccepted in
  /// SessionRoom) and on every subsequent SessionRoom emission whose
  /// mediaState changes (rejoin reconciliation).
  ///
  /// Idempotent: re-applying the same snapshot is a no-op so a
  /// `didChangeDependencies` fired by an unrelated InheritedWidget
  /// change (rotation, keyboard inset, route restore) doesn't yank
  /// the player back to `positionMs` and erase local progress.
  ///
  /// The room screen no longer ships a hard-coded media catalog: the
  /// snapshot is the only ground truth for source + track index. We
  /// surface the host's source verbatim and synthesize the placeholder
  /// queue via [_buildPlaceholderLib] so the protocol-level `trackIdx`
  /// rides through unchanged — outgoing `sendMediaCommand`s keep
  /// referencing the same index the host published.
  void _applyMediaSnapshot(MediaState snapshot) {
    if (_appliedSnapshot == snapshot) return;
    _appliedSnapshot = snapshot;
    final positionSec = (snapshot.positionMs / 1000).round();
    final lib = _buildPlaceholderLib(
      source: snapshot.source,
      trackIdx: snapshot.trackIdx,
      positionSec: positionSec,
    );
    setState(() {
      _source = snapshot.source;
      _lib = lib;
      _trackIdx = snapshot.trackIdx;
      _playing = snapshot.playing;
      _progress = positionSec.clamp(0, lib.queue[_trackIdx].durationSeconds);
    });
  }

  @override
  void didUpdateWidget(covariant FrequencyRoomScreen old) {
    super.didUpdateWidget(old);
    if (old.pttMode != widget.pttMode) {
      setState(() {
        _meMuted = widget.pttMode;
        _holdingPtt = false;
      });
      // Switching pttMode resets effective mute (open mic ⇒ unmuted,
      // PTT ⇒ muted-until-held), so the engine needs the new state.
      final effectiveMuted = _meEffectivelyMuted;
      unawaited(_audio.setMuted(effectiveMuted));
      unawaited(context.read<FrequencySessionCubit>().broadcastMute(effectiveMuted));
    }
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _mediaSub?.cancel();
    _audioEventsSub?.cancel();
    _weakSignalSub?.cancel();
    unawaited(_audio.stopVoice().then((_) => _audio.stopService()));
    super.dispose();
  }

  /// Render a real "X's signal is weak" toast in response to the
  /// cubit's host-side detector tripping. Mirrors the demo timer's
  /// copy + tone (kept gated under [debugDemoTimers]) so design and
  /// production match without duplicating the spec.
  void _onWeakSignal(({String peerId, String displayName}) e) {
    if (!mounted) return;
    FrequencyToastHost.of(context).push(FrequencyToastSpec(
      tone: ToastTone.warn,
      title: "${e.displayName}'s signal is weak",
      description: 'Ask them to move closer',
      autoDismiss: const Duration(milliseconds: 3600),
    ));
  }

  /// Open-mic mute toggle. Updates the local UI state and pushes the new
  /// mute flag to the native audio engine in one step so they can't drift.
  void _setOpenMicMuted(bool muted) {
    setState(() => _meMuted = muted);
    unawaited(_audio.setMuted(muted));
    unawaited(context.read<FrequencySessionCubit>().broadcastMute(muted));
  }

  /// PTT press/release. While held the mic is unmuted; on release we
  /// re-mute so a stuck pointer or a missed `onPointerCancel` can't leave
  /// the user open-mic'd against their intent.
  void _setPttHolding(bool holding) {
    setState(() => _holdingPtt = holding);
    final muted = !holding;
    unawaited(_audio.setMuted(muted));
    unawaited(context.read<FrequencySessionCubit>().broadcastMute(muted));
  }

  void _onMediaCommand(MediaCommand cmd) {
    if (!mounted) return;
    setState(() {
      final senderName = _resolveSenderName(cmd.peerId);

      switch (cmd.op) {
        case MediaOp.play:
          _playing = true;
          _lastAction = _LastAction(by: senderName, action: 'resumed', when: 'just now');
          break;
        case MediaOp.pause:
          _playing = false;
          _lastAction = _LastAction(by: senderName, action: 'paused', when: 'just now');
          break;
        case MediaOp.skip:
          _trackIdx = (_trackIdx + 1) % _lib.queue.length;
          _progress = 0;
          _lastAction = _LastAction(by: senderName, action: 'skipped', when: 'just now');
          break;
        case MediaOp.prev:
          _trackIdx = (_trackIdx - 1 + _lib.queue.length) % _lib.queue.length;
          _progress = 0;
          _lastAction = _LastAction(by: senderName, action: 'went back', when: 'just now');
          break;
        case MediaOp.seek:
          if (cmd.positionMs != null) {
            // Anchor scrub seeks to peer clocks
            final deltaMs = DateTime.now().millisecondsSinceEpoch - cmd.atMs;
            final effectiveMs = cmd.positionMs! + (deltaMs > 0 ? deltaMs : 0);
            _progress = (effectiveMs / 1000)
                .round()
                .clamp(0, _track.durationSeconds);
            _lastAction = _LastAction(by: senderName, action: 'scrubbed', when: 'just now');
          }
          break;
        case MediaOp.queuePlay:
          if (cmd.trackIdx != null) {
            final nextSource = cmd.source;
            final nextIdx = cmd.trackIdx!;
            // When the host switches source, rebuild the placeholder lib for
            // the new source; otherwise grow the existing one if the incoming
            // trackIdx exceeds the current queue length (Copilot review #153).
            if (nextSource != _source || nextIdx >= _lib.queue.length) {
              _source = nextSource;
              _lib = _buildPlaceholderLib(source: nextSource, trackIdx: nextIdx);
            }
            _trackIdx = nextIdx;
            _progress = 0;
            _playing = true;
            _lastAction = _LastAction(by: senderName, action: 'queued up track', when: 'just now');
          }
          break;
      }
    });
  }

  /// Resolves a `peerId` from a wire message to a display name.
  /// Priority: it's me, it's in the cubit-driven protocol roster (the
  /// `JoinAccepted`/`RosterUpdate`-sourced `SessionRoom.roster`),
  /// otherwise generic fallback.
  ///
  /// `_myPeerId` is resolved asynchronously on init; before it lands,
  /// commands attributed to the local user fall through to the
  /// "Someone" fallback rather than being guessed at.
  String _resolveSenderName(String peerId) {
    if (_myPeerId != null && peerId == _myPeerId) {
      return widget.myName.isEmpty ? 'You' : widget.myName;
    }
    final session = context.read<FrequencySessionCubit>().state;
    if (session is SessionRoom) {
      for (final p in session.roster) {
        if (p.peerId == peerId) return p.displayName;
      }
    }
    return 'Someone';
  }

  void _startProgressTick() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_playing || !mounted || _track.durationSeconds <= 0) return;
      setState(() => _progress = (_progress + 1) % _track.durationSeconds);
    });
  }

  void _togglePlay() {
    context.read<FrequencySessionCubit>().sendMediaCommand(
      op: _playing ? MediaOp.pause : MediaOp.play,
      source: _source,
    );
  }

  void _next() {
    context.read<FrequencySessionCubit>().sendMediaCommand(
      op: MediaOp.skip,
      source: _source,
    );
  }

  void _prev() {
    context.read<FrequencySessionCubit>().sendMediaCommand(
      op: MediaOp.prev,
      source: _source,
    );
  }

  void _playAt(int i) {
    context.read<FrequencySessionCubit>().sendMediaCommand(
      op: MediaOp.queuePlay,
      source: _source,
      trackIdx: i,
    );
  }

  void _scrub(double v) {
    context.read<FrequencySessionCubit>().sendMediaCommand(
      op: MediaOp.seek,
      source: _source,
      positionMs: (v * 1000).round(),
    );
  }

  /// Maps a protocol-layer peer to the UI's presentation model.
  /// Hue is deterministic from peerId so the same peer always gets
  /// the same color across sessions.
  Person _protocolPeerToPerson(ProtocolPeer peer) {
    final displayName = peer.displayName.isEmpty ? 'Unknown' : peer.displayName;
    final initials = (displayName.length >= 2
            ? displayName.substring(0, 2)
            : displayName)
        .toUpperCase();
    final hue = (peer.peerId.hashCode % 360).toDouble();
    return Person(
      id: peer.peerId,
      name: displayName,
      initials: initials,
      hue: hue,
      btDevice: peer.btDevice ?? 'Unknown device',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final source = _source;

    return BlocListener<FrequencySessionCubit, FrequencySessionState>(
      listenWhen: (prev, next) {
        // Only react to mediaState transitions inside the room — entering /
        // leaving the room is handled at the WalkieTalkieApp router level.
        if (prev is! SessionRoom || next is! SessionRoom) return false;
        return prev.mediaState != next.mediaState;
      },
      listener: (context, state) {
        if (state is! SessionRoom) return;
        if (state.mediaState != null) {
          _applyMediaSnapshot(state.mediaState!);
          return;
        }
        // Host published a JoinAccepted with no mediaState — i.e.
        // "nothing is playing". Clear the cached snapshot and reset the
        // transport so the UI reflects that, instead of stranding on
        // whatever the previous snapshot was.
        setState(() {
          _appliedSnapshot = null;
          _playing = false;
          _progress = 0;
        });
      },
      child: Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: Column(
            children: [
              BlocBuilder<FrequencySessionCubit, FrequencySessionState>(
                buildWhen: (prev, next) {
                  // Rebuild chrome when connectionPhase changes or state type changes
                  if (prev is SessionRoom && next is SessionRoom) {
                    return prev.connectionPhase != next.connectionPhase;
                  }
                  // Also rebuild when transitioning to/from SessionRoom (initial build)
                  return true;
                },
                builder: (context, state) {
                  final phase = state is SessionRoom
                      ? state.connectionPhase
                      : ConnectionPhase.online;
                  return _buildChrome(context, phase);
                },
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                  children: [
                    NowPlayingCard(
                      track: _track,
                      source: source,
                      isPodcast: _source == 'Podcasts',
                      playing: _playing,
                      progress: _progress,
                      lastActionBy: _lastAction.by,
                      lastActionWhat: _lastAction.action,
                      lastActionWhen: _lastAction.when,
                      onPlay: _togglePlay,
                      onNext: _next,
                      onPrev: _prev,
                      onScrub: _scrub,
                      onOpenQueue: _showQueueSheet,
                    ),
                    BlocBuilder<FrequencySessionCubit, FrequencySessionState>(
                      buildWhen: (prev, next) {
                        // Rebuild when roster changes or when entering/leaving room
                        if (prev is SessionRoom && next is SessionRoom) {
                          return prev.roster != next.roster;
                        }
                        return prev.runtimeType != next.runtimeType;
                      },
                      builder: (context, state) {
                        // Cubit roster is the single source of truth for peers.
                        // Local peer is filtered out (rendered separately as the
                        // me-row); locally-removed peers (host kick) drop out
                        // until the cubit's roster reflects the change.
                        final List<Person> peers;
                        final Set<String> talkingIds;
                        if (state is SessionRoom && state.roster.isNotEmpty) {
                          final visible = state.roster
                              .where((p) => p.peerId != _myPeerId)
                              .where((p) => !_removed.contains(p.peerId))
                              .toList();
                          peers = visible.map(_protocolPeerToPerson).toList();
                          talkingIds = {
                            for (final p in visible)
                              if (p.talking) p.peerId,
                          };
                        } else {
                          peers = [];
                          talkingIds = const {};
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SectionLabel(
                              text: 'On this frequency · ${peers.length + 1}',
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(_output.icon, size: 11, color: c.ink3),
                                  const SizedBox(width: 4),
                                  Text(
                                    _outputName(),
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 11,
                                      color: c.ink3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            _buildMeRow(context),
                            const SizedBox(height: 8),
                            if (peers.isNotEmpty)
                              FreqCard(
                                clipBehavior: Clip.antiAlias,
                                child: Column(
                                  children: [
                                    for (int i = 0; i < peers.length; i++)
                                      PeerRow(
                                        key: ValueKey(peers[i].id),
                                        person: peers[i],
                                        first: i == 0,
                                        talking: talkingIds.contains(peers[i].id) && !_peerMuted.contains(peers[i].id),
                                        muted: _peerMuted.contains(peers[i].id),
                                        volume: _volumeFor(peers[i].id),
                                        onTap: () => _showPeerDrawer(peers[i]),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        widget.pttMode
                            ? 'Push-to-talk · hold the mic button to transmit'
                            : 'Open mic · everyone hears you when not muted',
                        style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChrome(BuildContext context, ConnectionPhase phase) {
    final c = FrequencyTheme.of(context).colors;

    // Choose pill color and text based on connection phase
    final Color pillBg;
    final Color pillText;
    final String statusText;
    final Widget statusIcon;

    switch (phase) {
      case ConnectionPhase.reconnecting:
        pillBg = c.warnSoft;
        pillText = c.warn;
        statusText = 'Reconnecting…';
        // Spinning progress indicator for reconnecting - size matches PulseDot
        statusIcon = SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(pillText),
          ),
        );
      case ConnectionPhase.lost:
        // Use danger color with reduced opacity for dark mode compatibility
        pillBg = c.danger.withValues(alpha: 0.15);
        pillText = c.danger;
        statusText = 'Lost connection';
        statusIcon = Icon(Icons.error_outline, size: 12, color: pillText);
      case ConnectionPhase.online:
        pillBg = c.accentSoft;
        pillText = c.accentInk;
        statusText = 'On air';
        // Wrap PulseDot in SizedBox for consistent icon sizing
        statusIcon = const SizedBox(
          width: 12,
          height: 12,
          child: Center(child: PulseDot(size: 6)),
        );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                statusIcon,
                const SizedBox(width: 6),
                Text(
                  statusText,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    color: pillText,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (phase == ConnectionPhase.online) ...[
                  Text(' · ', style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    color: pillText,
                    fontWeight: FontWeight.w500,
                  )),
                  Text(widget.freq, style: kMonoStyle.copyWith(fontSize: 11, color: pillText)),
                ],
              ],
            ),
          ),
          if (widget.isHost) ...[
            const SizedBox(width: 8),
            FreqChip(label: 'HOST'),
          ],
          const Spacer(),
          GhostButton(
            icon: _output.icon,
            onPressed: _showOutputSheet,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          ),
          GhostButton(
            icon: Icons.add,
            onPressed: _showInviteSheet,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          ),
          GhostButton(
            icon: Icons.logout,
            onPressed: widget.onLeave,
            color: c.danger,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          ),
        ],
      ),
    );
  }

  Widget _buildMeRow(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return FreqCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          FreqAvatar(
            person: _me,
            talking: !_meEffectivelyMuted && _holdingPtt,
            muted: _meEffectivelyMuted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _meEffectivelyMuted ? '${_me.name} · muted' : _me.name,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                Row(
                  children: [
                    Icon(_output.icon, size: 11, color: c.ink3),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        _output == AudioOutput.bluetooth && _me.btDevice.isNotEmpty
                            ? _me.btDevice
                            : _output.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: c.ink3,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (widget.pttMode)
            PushToTalkButton(
              holding: _holdingPtt,
              onChange: _setPttHolding,
            )
          else
            SizedBox(
              width: 102,
              child: Semantics(
                // toggled=true means "microphone is on/active" so screen
                // readers announce "on" when transmitting and "off" when muted.
                toggled: !_meMuted,
                label: 'Microphone',
                enabled: true,
                excludeSemantics: true,
                onTap: () => _setOpenMicMuted(!_meMuted),
                child: FreqButton(
                  icon: _meMuted ? Icons.mic_off : Icons.mic,
                  label: _meMuted ? 'Unmute' : 'Mute',
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  fontSize: 13,
                  labelColor: _meMuted ? c.danger : null,
                  onPressed: () => _setOpenMicMuted(!_meMuted),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Sheets ──────────────────────────────────────────────────

  Future<void> _showPeerDrawer(Person person) async {
    final c = FrequencyTheme.of(context).colors;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return PeerDrawer(
          person: person,
          isHost: widget.isHost,
          initialVolume: _volumeFor(person.id),
          initialMuted: _peerMuted.contains(person.id),
          onChanged: (vol, muted) {
            setState(() {
              _volumes[person.id] = vol;
              if (muted) {
                _peerMuted.add(person.id);
              } else {
                _peerMuted.remove(person.id);
              }
            });
            // Mirror the toggle to disk so the next session sees the
            // same mute state. Fire-and-forget: the in-memory set is
            // the source of truth for the current frame, the persisted
            // copy only matters across restarts. Failures here would
            // surface on the next session as a missed-block; we accept
            // that over blocking the UI on the write.
            unawaited(_persistMute(person.id, muted));
          },
          onRemove: () {
            setState(() {
              _removed.add(person.id);
            });
            Navigator.pop(ctx);
            FrequencyToastHost.of(context).push(FrequencyToastSpec(
              tone: ToastTone.leave,
              title: '${person.name} was removed',
            ));
          },
          onReport: () => _reportPeer(ctx, person),
        );
      },
    );
  }

  Future<void> _reportPeer(BuildContext drawerCtx, Person person) async {
    // Defensive guard: if _myPeerId failed to resolve, the local peer can leak
    // into the visible roster (the filter at the cubit-state branch skips
    // null), letting the user open their own drawer and self-block. Bail
    // without mutating mute or block state.
    if (person.id == _me.id || person.id == _myPeerId) {
      Navigator.pop(drawerCtx);
      return;
    }
    // Sanitize the display name once for every UI surface so a malicious peer
    // cannot inject newlines or zero-width chars into toasts / dialog titles.
    final safeName = _sanitizeField(person.name);
    // Capture prior mute state so we can revert accurately on failure without
    // accidentally unmuting a peer that was already muted before the report.
    final wasMuted = _peerMuted.contains(person.id);
    // Optimistically update in-memory mute state so the room UI responds
    // immediately; we revert below if the DB write fails.
    setState(() {
      _peerMuted.add(person.id);
    });
    Navigator.pop(drawerCtx);

    bool blocked = false;
    try {
      await _blockedPeersStore.block(person.id);
      blocked = true;
    } catch (_) {
      // Persistence failed — revert the optimistic change only if the peer
      // was not already muted before this report action.
      if (mounted && !wasMuted) setState(() => _peerMuted.remove(person.id));
    }

    if (!mounted) return;

    if (blocked) {
      FrequencyToastHost.of(context).push(FrequencyToastSpec(
        tone: ToastTone.warn,
        title: '$safeName blocked',
      ));
      final report = _buildSanitizedReport(person);
      showDialog<void>(
        context: context,
        builder: (ctx) => _ReportSentDialog(
          peerName: safeName,
          reportText: report,
        ),
      );
    } else {
      FrequencyToastHost.of(context).push(FrequencyToastSpec(
        tone: ToastTone.warn,
        title: 'Could not block $safeName — try again',
      ));
    }
  }

  String _buildSanitizedReport(Person person) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    return 'Walkie Talkie abuse report\n'
        'Time (UTC): $timestamp\n'
        'Frequency: ${_sanitizeField(widget.freq)}\n'
        'Peer display name: ${_sanitizeField(person.name)}\n'
        'Peer BLE device: ${_sanitizeField(person.btDevice)}\n';
  }

  // Strip control characters and Unicode line separators from user-controlled
  // strings so a malicious peer name or device name cannot inject extra lines
  // into the report (covers ASCII C0/C1 control chars and U+2028/U+2029).
  static String _sanitizeField(String s) => s
      .replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F\u2028\u2029]'), ' ')
      .replaceAll(RegExp(r' +'), ' ')
      .trim();

  Future<void> _showQueueSheet() async {
    final c = FrequencyTheme.of(context).colors;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => QueueSheet(
        lib: _lib,
        currentIdx: _trackIdx,
        onPlay: (i) {
          _playAt(i);
          Navigator.pop(ctx);
        },
        onChangeSource: widget.isHost
            ? () {
                Navigator.pop(ctx);
                _showSourceSheet();
              }
            : null,
      ),
    );
  }

  Future<void> _showInviteSheet() async {
    final c = FrequencyTheme.of(context).colors;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => InviteSheet(freq: widget.freq),
    );
  }

  Future<void> _showOutputSheet() async {
    final c = FrequencyTheme.of(context).colors;
    final picked = await showModalBottomSheet<AudioOutput>(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => OutputSheet(current: _output, btName: _me.btDevice),
    );
    if (picked != null && mounted) {
      // Apply the audio routing change at the native layer
      final outputStr = picked.name; // "bluetooth", "earpiece", or "speaker"
      final success = await _audio.setAudioOutput(outputStr);

      if (success) {
        setState(() => _output = picked);
      } else {
        if (kDebugMode) debugPrint('Failed to route audio to $outputStr, keeping current output');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                picked == AudioOutput.bluetooth
                    ? 'No Bluetooth device available — connect headphones first'
                    : "Couldn't switch to ${picked.label}",
              ),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }

  Future<void> _showSourceSheet() async {
    final c = FrequencyTheme.of(context).colors;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => MediaSourceSheet(current: _source),
    );
    if (picked != null && mounted && picked != _source) {
      _switchSource(picked);
    }
  }

  void _switchSource(String newSource) {
    final lib = _buildPlaceholderLib(source: newSource, trackIdx: 0);
    setState(() {
      _source = newSource;
      _lib = lib;
      _trackIdx = 0;
      _progress = 0;
      _playing = false;
    });
    // Broadcast the source switch to peers via a queuePlay at track 0.
    context.read<FrequencySessionCubit>().sendMediaCommand(
      op: MediaOp.queuePlay,
      source: newSource,
      trackIdx: 0,
    );
  }

  String _outputName() {
    return _output == AudioOutput.bluetooth ? 'headphones' : _output.label;
  }
}

class _LastAction {
  final String by;
  final String action;
  final String when;
  const _LastAction({required this.by, required this.action, required this.when});
}

class _ReportSentDialog extends StatefulWidget {
  final String peerName;
  final String reportText;

  const _ReportSentDialog({required this.peerName, required this.reportText});

  @override
  State<_ReportSentDialog> createState() => _ReportSentDialogState();
}

class _ReportSentDialogState extends State<_ReportSentDialog> {
  bool _copied = false;
  Timer? _copiedResetTimer;

  @override
  void dispose() {
    _copiedResetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // scrollable: true wraps the content in a SingleChildScrollView so a long
    // peer / device name or large accessibility text scale doesn't overflow
    // on small screens.
    return AlertDialog(
      scrollable: true,
      title: Text('${widget.peerName} blocked'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'They have been muted and blocked. To report this incident to support, copy the report below and email it to support@elodin.app.',
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              widget.reportText,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Dismiss'),
        ),
        FilledButton.icon(
          icon: Icon(_copied ? Icons.check : Icons.copy),
          label: Text(_copied ? 'Copied' : 'Copy report'),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await Clipboard.setData(ClipboardData(text: widget.reportText));
              if (!mounted) return;
              setState(() => _copied = true);
              // Revert the label so the user can copy again — the "Copied"
              // state is feedback, not a permanent disable.
              _copiedResetTimer?.cancel();
              _copiedResetTimer = Timer(const Duration(seconds: 2), () {
                if (mounted) setState(() => _copied = false);
              });
            } catch (_) {
              if (mounted) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('Could not copy to clipboard')),
                );
              }
            }
          },
        ),
      ],
    );
  }
}




