import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/frequency_session_cubit.dart';
import '../bloc/frequency_session_state.dart';
import '../data/frequency_models.dart';
import '../protocol/messages.dart';
import '../protocol/peer.dart';
import '../services/audio_service.dart';
import '../theme/app_theme.dart';
import '../widgets/frequency_atoms.dart';
import '../widgets/frequency_toast_host.dart';

enum AudioOutput { bluetooth, earpiece, speaker }

extension on AudioOutput {
  String get label => switch (this) {
        AudioOutput.bluetooth => 'Bluetooth headphones',
        AudioOutput.earpiece => 'Phone earpiece',
        AudioOutput.speaker => 'Phone speaker',
      };

  IconData get icon => switch (this) {
        AudioOutput.bluetooth => Icons.bluetooth,
        AudioOutput.earpiece => Icons.mic_none,
        AudioOutput.speaker => Icons.volume_up,
      };

  String subFor(String bt) => switch (this) {
        AudioOutput.bluetooth => bt.isEmpty ? 'Paired headphones' : bt,
        AudioOutput.earpiece => 'Private, held to ear',
        AudioOutput.speaker => 'Loud · everyone nearby hears',
      };
}

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
  final Set<String> _peerMuted = {};
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
  bool _playing = true;
  int _progress = 37;
  late _LastAction _lastAction;
  AudioOutput _output = AudioOutput.bluetooth;

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
          if (newOutput != _output) {
            setState(() => _output = newOutput);
          }
        }
      } else if (type == 'leaveRoom') {
        widget.onLeave();
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
    try {
      final peerId = await context.read<FrequencySessionCubit>().identityStore.getPeerId();
      if (!mounted) return;
      // Stored without setState — the field only affects attribution in
      // the next [_onMediaCommand], which sets state itself.
      _myPeerId = peerId;
    } catch (_) {
      // Identity store failure is non-fatal here: if this one-time read
      // fails, attribution falls back to "remote sender" for this
      // screen session, which doesn't matter for in-frame UX.
    }
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
  /// snapshot is the only ground truth for source + track index, and
  /// title/artwork metadata isn't on the wire yet (#TBD adds it). We
  /// surface the host's source verbatim and render a single placeholder
  /// "Track N" entry; the protocol-level `trackIdx` rides through as the
  /// queue position so subsequent media commands keep agreeing with the
  /// host's view.
  void _applyMediaSnapshot(MediaState snapshot) {
    if (_appliedSnapshot == snapshot) return;
    _appliedSnapshot = snapshot;
    final positionSec = (snapshot.positionMs / 1000).round();
    setState(() {
      _source = snapshot.source;
      _lib = emptyMediaLib;
      _trackIdx = 0;
      _playing = snapshot.playing;
      _progress = positionSec.clamp(0, _lib.queue[0].durationSeconds);
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
            _trackIdx = cmd.trackIdx!;
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
      if (!_playing || !mounted) return;
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

  String _outputName() {
    return _output == AudioOutput.bluetooth ? 'headphones' : _output.label;
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
                    _NowPlayingCard(
                      track: _track,
                      source: source,
                      isPodcast: _source == 'Podcasts',
                      playing: _playing,
                      progress: _progress,
                      lastAction: _lastAction,
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
                                      _PeerRow(
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
            _PushToTalkButton(
              holding: _holdingPtt,
              onChange: _setPttHolding,
            )
          else
            SizedBox(
              width: 102,
              child: _meMuted
                  ? FreqButton(
                      icon: Icons.mic_off,
                      label: 'Unmute',
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      fontSize: 13,
                      onPressed: () => _setOpenMicMuted(false),
                    )
                  : PrimaryButton(
                      icon: Icons.mic,
                      label: 'Mute',
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      fontSize: 13,
                      onPressed: () => _setOpenMicMuted(true),
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
        return _PeerDrawer(
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
        );
      },
    );
  }

  Future<void> _showQueueSheet() async {
    final c = FrequencyTheme.of(context).colors;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _QueueSheet(
        lib: _lib,
        currentIdx: _trackIdx,
        onPlay: (i) {
          _playAt(i);
          Navigator.pop(ctx);
        },
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
      builder: (_) => _InviteSheet(freq: widget.freq),
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
      builder: (_) => _OutputSheet(current: _output, btName: _me.btDevice),
    );
    if (picked != null && mounted) {
      // Apply the audio routing change at the native layer
      final outputStr = picked.name; // "bluetooth", "earpiece", or "speaker"
      final success = await _audio.setAudioOutput(outputStr);

      if (success) {
        setState(() => _output = picked);
      } else {
        // If routing failed (e.g., no Bluetooth device available), keep
        // the current selection and optionally show a toast. For now, we
        // silently keep the previous output rather than updating the UI
        // to a non-functional state.
        if (kDebugMode) debugPrint('Failed to route audio to $outputStr, keeping current output');
      }
    }
  }
}

class _LastAction {
  final String by;
  final String action;
  final String when;
  const _LastAction({required this.by, required this.action, required this.when});
}

// ── Now playing card ────────────────────────────────────────

class _NowPlayingCard extends StatelessWidget {
  final Track track;
  final String source;
  final bool isPodcast;
  final bool playing;
  final int progress;
  final _LastAction lastAction;
  final VoidCallback onPlay;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final ValueChanged<double> onScrub;
  final VoidCallback onOpenQueue;

  const _NowPlayingCard({
    required this.track,
    required this.source,
    required this.isPodcast,
    required this.playing,
    required this.progress,
    required this.lastAction,
    required this.onPlay,
    required this.onNext,
    required this.onPrev,
    required this.onScrub,
    required this.onOpenQueue,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return FreqCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'LISTENING TOGETHER · ${source.toUpperCase()}',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.0,
                    color: c.ink3,
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VuMeter(active: playing),
                  const SizedBox(width: 5),
                  Text(
                    playing ? 'Live' : 'Paused',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.0,
                      color: c.ink3,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Artwork(isPodcast: isPodcast),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.tag,
                      style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.16,
                        color: c.ink,
                      ),
                    ),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 13,
                        color: c.ink2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Slider(
            value: progress.toDouble().clamp(0.0, track.durationSeconds.toDouble()).toDouble(),
            min: 0,
            max: track.durationSeconds.toDouble(),
            onChanged: onScrub,
          ),
          Row(
            children: [
              Text(formatTime(progress), style: kMonoStyle.copyWith(fontSize: 11, color: c.ink3)),
              const Spacer(),
              Text('-${formatTime(track.durationSeconds - progress)}',
                  style: kMonoStyle.copyWith(fontSize: 11, color: c.ink3)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              GhostButton(icon: Icons.skip_previous, onPressed: onPrev),
              const SizedBox(width: 4),
              _PlayCircle(playing: playing, onTap: onPlay),
              const SizedBox(width: 4),
              GhostButton(icon: Icons.skip_next, onPressed: onNext),
              const Spacer(),
              FreqButton(
                icon: Icons.queue_music,
                label: 'Queue',
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                fontSize: 13,
                onPressed: onOpenQueue,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
                      children: [
                        TextSpan(
                          text: lastAction.by,
                          style: TextStyle(color: c.ink2, fontWeight: FontWeight.w500),
                        ),
                        TextSpan(text: ' ${lastAction.action}'),
                      ],
                    ),
                  ),
                ),
                Text(
                  lastAction.when,
                  style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  final bool isPodcast;
  const _Artwork({required this.isPodcast});

  @override
  Widget build(BuildContext context) {
    final base = isPodcast
        ? const [Color(0xFFEFD8C3), Color(0xFFF6E6D6)]
        : const [Color(0xFFD4D5EE), Color(0xFFE2E3F4)];
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          colors: base,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          tileMode: TileMode.repeated,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        isPodcast ? Icons.podcasts : Icons.music_note,
        size: 22,
        color: isPodcast ? const Color(0xFF704D2A) : const Color(0xFF3F3F73),
      ),
    );
  }
}

class _PlayCircle extends StatelessWidget {
  final bool playing;
  final VoidCallback onTap;
  const _PlayCircle({required this.playing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Material(
      color: c.ink,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            playing ? Icons.pause : Icons.play_arrow,
            size: 22,
            color: c.bg,
          ),
        ),
      ),
    );
  }
}

// ── Push-to-talk ────────────────────────────────────────────

class _PushToTalkButton extends StatelessWidget {
  final bool holding;
  final ValueChanged<bool> onChange;
  const _PushToTalkButton({required this.holding, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Listener(
      onPointerDown: (_) => onChange(true),
      onPointerUp: (_) => onChange(false),
      onPointerCancel: (_) => onChange(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: holding ? c.accent : c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: holding ? Colors.transparent : c.line),
        ),
        constraints: const BoxConstraints(minWidth: 104),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.mic, size: 14, color: holding ? c.accentInk : c.ink),
            const SizedBox(width: 6),
            Text(
              holding ? 'On air' : 'Hold to talk',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: holding ? c.accentInk : c.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Peer row ────────────────────────────────────────────────

class _PeerRow extends StatelessWidget {
  final Person person;
  final bool first;
  final bool talking;
  final bool muted;
  final double volume;
  final VoidCallback onTap;

  const _PeerRow({
    super.key,
    required this.person,
    required this.first,
    required this.talking,
    required this.muted,
    required this.volume,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Material(
      color: c.surface,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              top: first ? BorderSide.none : BorderSide(color: c.line),
            ),
          ),
          child: Row(
            children: [
              FreqAvatar(person: person, size: 36, talking: talking, muted: muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      person.name,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink,
                      ),
                    ),
                    Row(
                      children: [
                        Icon(Icons.bluetooth, size: 10, color: c.ink3),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            person.btDevice,
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
              if (talking)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    VuMeter(color: c.accent),
                    const SizedBox(width: 5),
                    Text('talking', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.accent)),
                  ],
                )
              else if (muted)
                Text('muted', style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3))
              else
                Text(
                  '${(volume * 100).round()}%',
                  style: kMonoStyle.copyWith(fontSize: 11, color: c.ink3),
                ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 16, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Peer drawer ────────────────────────────────────────────

class _PeerDrawer extends StatefulWidget {
  final Person person;
  final bool isHost;
  final double initialVolume;
  final bool initialMuted;
  final void Function(double volume, bool muted) onChanged;
  final VoidCallback onRemove;

  const _PeerDrawer({
    required this.person,
    required this.isHost,
    required this.initialVolume,
    required this.initialMuted,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<_PeerDrawer> createState() => _PeerDrawerState();
}

class _PeerDrawerState extends State<_PeerDrawer> {
  late double _volume = widget.initialVolume;
  late bool _muted = widget.initialMuted;

  void _emit() => widget.onChanged(_volume, _muted);

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        MediaQuery.of(context).viewInsets.bottom + 28,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 14),
              decoration: BoxDecoration(
                color: c.line2,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Row(
            children: [
              FreqAvatar(person: widget.person, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.person.name,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                    Row(
                      children: [
                        Icon(Icons.bluetooth, size: 11, color: c.ink3),
                        const SizedBox(width: 4),
                        Text(
                          widget.person.btDevice,
                          style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              GhostButton(icon: Icons.close, onPressed: () => Navigator.pop(context)),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Mute from your side',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: c.ink,
                        ),
                      ),
                      Text(
                        'Only you stop hearing them',
                        style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                      ),
                    ],
                  ),
                ),
                FreqSwitch(
                  value: _muted,
                  onChanged: (v) {
                    setState(() => _muted = v);
                    _emit();
                  },
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(
                        'Their voice volume',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: c.ink,
                        ),
                      ),
                    ),
                    Text(
                      '${(_volume * 100).round()}%',
                      style: kMonoStyle.copyWith(fontSize: 12, color: c.ink3),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.volume_up, size: 16, color: c.ink3),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Slider(
                        value: _volume,
                        onChanged: (v) {
                          setState(() => _volume = v);
                          _emit();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (widget.isHost) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.only(top: 14),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
              child: Column(
                children: [
                  FreqButton(
                    label: 'Remove from frequency',
                    block: true,
                    labelColor: c.danger,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    onPressed: widget.onRemove,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'As host, only you can remove people.',
                    style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Queue sheet ─────────────────────────────────────────────

class _QueueSheet extends StatelessWidget {
  final MediaSourceLib lib;
  final int currentIdx;
  final ValueChanged<int> onPlay;

  const _QueueSheet({required this.lib, required this.currentIdx, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, controller) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8, bottom: 14),
                  decoration: BoxDecoration(
                    color: c.line2,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Shared queue',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: c.ink,
                          ),
                        ),
                        Text(
                          'From ${lib.name} · everyone can reorder',
                          style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                        ),
                      ],
                    ),
                  ),
                  GhostButton(icon: Icons.close, onPressed: () => Navigator.pop(context)),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: lib.queue.length,
                  itemBuilder: (_, i) {
                    final t = lib.queue[i];
                    final current = i == currentIdx;
                    return InkWell(
                      onTap: () => onPlay(i),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                        decoration: BoxDecoration(
                          border: Border(
                            top: i == 0 ? BorderSide.none : BorderSide(color: c.line),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 28,
                              child: Center(
                                child: current
                                    ? VuMeter(color: c.accent)
                                    : Text(
                                        (i + 1).toString().padLeft(2, '0'),
                                        style: kMonoStyle.copyWith(fontSize: 12, color: c.ink3),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 14,
                                      fontWeight: current ? FontWeight.w600 : FontWeight.w500,
                                      color: c.ink,
                                    ),
                                  ),
                                  Text(
                                    t.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 12,
                                      color: c.ink3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              formatTime(t.durationSeconds),
                              style: kMonoStyle.copyWith(fontSize: 12, color: c.ink3),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              FreqButton(
                icon: Icons.add,
                label: 'Add from ${lib.name}',
                block: true,
                padding: const EdgeInsets.symmetric(vertical: 12),
                onPressed: () {},
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Invite sheet ────────────────────────────────────────────

class _InviteSheet extends StatefulWidget {
  final String freq;
  const _InviteSheet({required this.freq});

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  bool _copied = false;
  Timer? _copiedReset;

  @override
  void dispose() {
    _copiedReset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 8, bottom: 14),
            decoration: BoxDecoration(
              color: c.line2,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          Text(
            'INVITE NEARBY',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.1,
              color: c.ink3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.freq,
            style: kMonoStyle.copyWith(
              fontSize: 48,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.96,
              color: c.ink,
              height: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'MHz · your Frequency',
            style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
          ),
          const SizedBox(height: 20),
          Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.line),
            ),
            padding: const EdgeInsets.all(10),
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 9,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: 81,
              itemBuilder: (_, i) {
                final on = ((i * 37 + 7) % 3) == 0 ||
                    [0, 1, 7, 8, 9, 17, 63, 64, 65, 71, 72].contains(i);
                return Container(
                  decoration: BoxDecoration(
                    color: on ? c.ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          FreqButton(
            block: true,
            icon: _copied ? Icons.check : Icons.copy,
            label: _copied ? 'Copied invite' : 'Copy invite link',
            padding: const EdgeInsets.symmetric(vertical: 12),
            onPressed: () {
              setState(() => _copied = true);
              _copiedReset?.cancel();
              _copiedReset = Timer(const Duration(milliseconds: 1600), () {
                if (mounted) setState(() => _copied = false);
              });
            },
          ),
          const SizedBox(height: 12),
          Text(
            'Anyone within ~30m can tune in.',
            style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
          ),
        ],
      ),
    );
  }
}

// ── Output sheet ───────────────────────────────────────────

class _OutputSheet extends StatelessWidget {
  final AudioOutput current;
  final String btName;
  const _OutputSheet({required this.current, required this.btName});

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 14),
              decoration: BoxDecoration(
                color: c.line2,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Play sound on',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                    Text(
                      'Where voice and media come out',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                    ),
                  ],
                ),
              ),
              GhostButton(icon: Icons.close, onPressed: () => Navigator.pop(context)),
            ],
          ),
          const SizedBox(height: 14),
          FreqCard(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (int i = 0; i < AudioOutput.values.length; i++)
                  _OutputRow(
                    output: AudioOutput.values[i],
                    selected: AudioOutput.values[i] == current,
                    first: i == 0,
                    btName: btName,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              "Pair new headphones in your phone's Bluetooth settings.",
              style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
            ),
          ),
        ],
      ),
    );
  }
}

class _OutputRow extends StatelessWidget {
  final AudioOutput output;
  final bool selected;
  final bool first;
  final String btName;
  const _OutputRow({
    required this.output,
    required this.selected,
    required this.first,
    required this.btName,
  });

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    return Material(
      color: selected ? c.surface2 : c.surface,
      child: InkWell(
        onTap: () => Navigator.pop(context, output),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            border: Border(
              top: first ? BorderSide.none : BorderSide(color: c.line),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: selected ? c.accentSoft : c.surface2,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(
                  output.icon,
                  size: 16,
                  color: selected ? c.accentInk : c.ink2,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      output.label,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.ink,
                      ),
                    ),
                    Text(
                      output.subFor(btName),
                      style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: c.ink3),
                    ),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check, size: 16, color: c.accent),
            ],
          ),
        ),
      ),
    );
  }
}
