import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/frequency_session_cubit.dart';
import '../bloc/frequency_session_state.dart';
import '../data/frequency_mock_data.dart';
import '../protocol/messages.dart';
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
        AudioOutput.bluetooth => bt,
        AudioOutput.earpiece => 'Private, held to ear',
        AudioOutput.speaker => 'Loud · everyone nearby hears',
      };
}

/// Main "On air" room — voice + now playing.
class FrequencyRoomScreen extends StatefulWidget {
  final String freq;
  final int groupSize;
  final MediaKind mediaKind;
  final bool pttMode;
  final bool isHost;
  final String myName;
  final VoidCallback onLeave;

  /// Native audio bridge. Optional so widget tests that don't care about the
  /// MethodChannel can omit it (the catch-blocks inside [AudioService]
  /// swallow `MissingPluginException`); production wiring constructs the
  /// default instance. Tests that *do* assert on audio engine calls can
  /// pass an instance whose channel handler they've registered.
  final AudioService? audioService;

  const FrequencyRoomScreen({
    super.key,
    required this.freq,
    required this.groupSize,
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
  late List<Person> _roster;

  bool _meMuted = false;
  bool _holdingPtt = false;
  late Map<String, double> _volumes;
  final Set<String> _peerMuted = {};
  final Set<String> _removed = {};

  String? _talkingId;
  Timer? _talkTicker;
  Timer? _progressTimer;
  Timer? _hostJoinDemoTimer;
  Timer? _weakSignalDemoTimer;
  StreamSubscription<MediaCommand>? _mediaSub;

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
      btDevice: kPeople.first.btDevice,
    );
    _roster = [_me, ...kPeople.skip(1).take(widget.groupSize - 1)];
    _meMuted = widget.pttMode;
    _volumes = {for (final p in _roster) p.id: 0.7};

    _source = widget.mediaKind == MediaKind.podcast ? 'Podcasts' : 'YouTube Music';
    _lib = kMedia[_source]!;
    _lastAction = const _LastAction(by: 'Devon', action: 'started playback', when: '12s ago');

    _audio = widget.audioService ?? AudioService();
    // Spin up the capture engine, then push the initial mute state. The
    // sequence matters: pushing `setMuted` before `startVoice` finishes
    // would race the encoder init on slower devices and the first toggle
    // would silently no-op.
    final initialMuted = _meEffectivelyMuted;
    unawaited(_audio.startVoice().then((_) {
      _audio.setMuted(initialMuted);
    }));

    _resolveMyPeerId();
    _startTalkSimulation();
    _startProgressTick();

    if (widget.isHost) {
      _hostJoinDemoTimer = Timer(const Duration(milliseconds: 2800), () {
        if (!mounted) return;
        final newcomer = kPeople.length > widget.groupSize
            ? kPeople[widget.groupSize]
            : kPeople.last;
        FrequencyToastHost.of(context).push(FrequencyToastSpec(
          tone: ToastTone.request,
          person: newcomer,
          title: '${newcomer.name} wants to tune in',
          description: "They're right nearby",
          autoDismiss: null, // sticky — host must choose
          // Demo only: real accept/deny dispatch waits on the BT mesh +
          // state container. The toast surface is the deliverable for now.
          actions: [
            ToastAction(label: 'Deny', onTap: () {}),
            ToastAction(label: 'Let in', primary: true, onTap: () {}),
          ],
        ));
      });
    }

    _weakSignalDemoTimer = Timer(const Duration(milliseconds: 7200), () {
      if (!mounted) return;
      final p = _roster.last;
      // Don't surface a weak-signal toast for someone who's already left.
      if (p.id == 'me' || _removed.contains(p.id)) return;
      FrequencyToastHost.of(context).push(FrequencyToastSpec(
        tone: ToastTone.warn,
        title: "${p.name}'s signal is weak",
        description: 'Ask them to move closer',
        autoDismiss: const Duration(milliseconds: 3600),
      ));
    });
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
  /// If `snapshot.source` is a key we don't recognize in `kMedia`, we
  /// skip the snapshot entirely (don't mutate `_source`/`_lib`). This
  /// keeps the UI's queue and the source string we'd ship in outgoing
  /// `sendMediaCommand`s in sync — desync would mean the next play /
  /// seek / skip carries an unknown source the host then ignores.
  void _applyMediaSnapshot(MediaState snapshot) {
    if (_appliedSnapshot == snapshot) return;
    final lib = kMedia[snapshot.source];
    if (lib == null) {
      debugPrint(
        'Ignoring media snapshot for unknown source "${snapshot.source}"',
      );
      return;
    }
    _appliedSnapshot = snapshot;
    final clampedIdx = snapshot.trackIdx.clamp(0, lib.queue.length - 1);
    final positionSec = (snapshot.positionMs / 1000).round();
    setState(() {
      _source = snapshot.source;
      _lib = lib;
      _trackIdx = clampedIdx;
      _playing = snapshot.playing;
      _progress = positionSec.clamp(0, lib.queue[clampedIdx].durationSeconds);
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
      unawaited(_audio.setMuted(_meEffectivelyMuted));
    }
  }

  @override
  void dispose() {
    _talkTicker?.cancel();
    _progressTimer?.cancel();
    _hostJoinDemoTimer?.cancel();
    _weakSignalDemoTimer?.cancel();
    _mediaSub?.cancel();
    unawaited(_audio.stopVoice());
    super.dispose();
  }

  /// Open-mic mute toggle. Updates the local UI state and pushes the new
  /// mute flag to the native audio engine in one step so they can't drift.
  void _setOpenMicMuted(bool muted) {
    setState(() => _meMuted = muted);
    unawaited(_audio.setMuted(muted));
  }

  /// PTT press/release. While held the mic is unmuted; on release we
  /// re-mute so a stuck pointer or a missed `onPointerCancel` can't leave
  /// the user open-mic'd against their intent.
  void _setPttHolding(bool holding) {
    setState(() => _holdingPtt = holding);
    unawaited(_audio.setMuted(!holding));
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
            _progress = (effectiveMs / 1000).round();
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
  /// Priority: it's me, it's in the protocol roster (the
  /// `JoinAccepted`/`RosterUpdate`-sourced `SessionRoom.roster`),
  /// it's in the mock roster (v1 demo until BLE-backed peers land),
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
    for (final p in _roster) {
      if (p.id == peerId) return p.name;
    }
    return 'Someone';
  }

  void _startTalkSimulation() {
    _talkTicker?.cancel();
    _talkTicker = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (!mounted) return;
      final active = _roster
          .where((p) => p.id != 'me' && !_peerMuted.contains(p.id) && !_removed.contains(p.id))
          .map((p) => p.id)
          .toList();
      setState(() {
        if (active.isEmpty) {
          _talkingId = null;
        } else if (Random().nextDouble() < 0.3) {
          _talkingId = null;
        } else {
          _talkingId = active[Random().nextInt(active.length)];
        }
      });
    });
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

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final source = _source;
    final peers = _roster.skip(1).where((p) => !_removed.contains(p.id)).toList();

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
              _buildChrome(context),
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
                    FreqCard(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (int i = 0; i < peers.length; i++)
                            _PeerRow(
                              key: ValueKey(peers[i].id),
                              person: peers[i],
                              first: i == 0,
                              talking: _talkingId == peers[i].id && !_peerMuted.contains(peers[i].id),
                              muted: _peerMuted.contains(peers[i].id),
                              volume: _volumes[peers[i].id]!,
                              onTap: () => _showPeerDrawer(peers[i]),
                            ),
                        ],
                      ),
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

  Widget _buildChrome(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
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
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PulseDot(size: 6),
                const SizedBox(width: 6),
                Text(
                  'On air · ',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    color: c.accentInk,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(widget.freq, style: kMonoStyle.copyWith(fontSize: 11, color: c.accentInk)),
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
                        _output == AudioOutput.bluetooth ? _me.btDevice : _output.label,
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
          initialVolume: _volumes[person.id]!,
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
    if (picked != null && mounted) setState(() => _output = picked);
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
