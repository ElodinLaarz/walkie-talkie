import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../bloc/frequency_session_cubit.dart';
import '../bloc/frequency_session_state.dart';
import '../services/audio_service.dart';
import '../services/voice_telemetry_monitor.dart';
import '../theme/app_theme.dart';

/// In-app voice debug dashboard.
///
/// Polls per-peer link telemetry from the native `PeerAudioManager` on a timer,
/// feeds it through a [VoiceTelemetryMonitor], and renders the live picture a
/// human watching a struggling call wants: receive throughput (should sit near
/// 50/s), the current head-of-stream seq, end-to-end staleness (lag) now and on
/// a rolling sparkline, and how many frames we're shedding as stale. The
/// "Export last minute" action dumps the retained window to a JSON file that can
/// be pulled off the device and attached to a bug report — so we're not limited
/// to live `adb logcat`.
///
/// This is a diagnostics surface, not a user-facing screen: copy is plain
/// (un-localized) on purpose.
class VoiceDebugDashboardScreen extends StatefulWidget {
  final AudioService audioService;
  final FrequencySessionCubit cubit;

  /// How often to sample native telemetry. 1 s matches the lifetime-counter
  /// cadence the monitor differences into rates; faster just adds JNI churn.
  final Duration pollInterval;

  /// Injectable for tests; defaults to a fresh 60 s-window monitor.
  final VoiceTelemetryMonitor? monitor;

  const VoiceDebugDashboardScreen({
    super.key,
    required this.audioService,
    required this.cubit,
    this.pollInterval = const Duration(seconds: 1),
    this.monitor,
  });

  @override
  State<VoiceDebugDashboardScreen> createState() =>
      _VoiceDebugDashboardScreenState();
}

class _VoiceDebugDashboardScreenState extends State<VoiceDebugDashboardScreen> {
  // Mirrors native audio_config::kStaleDropBudgetMs (200 ms): the threshold
  // above which a frame is shed as too stale. Drawn as a reference line on the
  // lag sparkline so you can see when staleness crosses the drop budget.
  static const double _staleBudgetMs = 200;

  late final VoiceTelemetryMonitor _monitor;
  final Map<String, String> _labels = {}; // peerId -> displayName
  Timer? _timer;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _monitor = widget.monitor ?? VoiceTelemetryMonitor();
    _timer = Timer.periodic(widget.pollInterval, (_) => unawaited(_poll()));
    unawaited(_poll()); // seed immediately rather than after one interval
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling) return; // skip if the previous sample is still in flight
    _polling = true;
    try {
      final state = widget.cubit.state;
      final active = <String>{};
      if (state is SessionRoom) {
        for (final peer in state.roster) {
          // Resolve each roster peer to a MAC. Our own entry (and peers we
          // have no L2CAP link to) resolve to null and are skipped, so the
          // dashboard naturally shows only the streams we actually receive.
          final mac = widget.cubit.macForPeerId(peer.peerId);
          if (mac == null) continue;
          active.add(peer.peerId);
          final snap = await widget.audioService.getLinkTelemetry(mac);
          if (!mounted) return;
          if (snap != null) {
            // Stamp per-snapshot, not once before the loop: getLinkTelemetry is
            // awaited serially, so a shared pre-loop timestamp would record
            // later peers with too-early a time and skew their derived rates.
            final sampleMs = DateTime.now().millisecondsSinceEpoch;
            _monitor.add(peer.peerId, snap, sampleMs);
            _labels[peer.peerId] = peer.displayName;
          }
        }
      }
      // Drop peers that have left the room (or whose link dropped) so the
      // dashboard doesn't keep rendering their last, now-frozen sample — the
      // monitor only ages points out on add(), which never fires for a peer
      // we've stopped polling.
      for (final id in _monitor.peers.toList()) {
        if (!active.contains(id)) {
          _monitor.forgetPeer(id);
          _labels.remove(id);
        }
      }
      if (mounted) setState(() {});
    } finally {
      _polling = false;
    }
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final json = _monitor.exportJson();
      // App-specific external dir on Android is user-reachable (file manager /
      // `adb pull`) without storage permissions; fall back to the documents
      // dir. getExternalStorageDirectory() is Android-only and *throws* (not
      // returns null) elsewhere, so guard the platform before calling it.
      final dir = Platform.isAndroid
          ? (await getExternalStorageDirectory() ??
                await getApplicationDocumentsDirectory())
          : await getApplicationDocumentsDirectory();
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${dir.path}/voice-telemetry-$ts.json');
      await file.writeAsString(json);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Exported to ${file.path}'),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FrequencyTheme.of(context).colors;
    final peers = _monitor.peers.toList()..sort();

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bg,
        foregroundColor: c.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        title: Text(
          'Voice debug',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: c.ink,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export last minute',
            onPressed: peers.isEmpty ? null : () => unawaited(_export()),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: c.line),
        ),
      ),
      body: peers.isEmpty
          ? _EmptyState(c: c)
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                for (final peerId in peers)
                  _PeerCard(
                    c: c,
                    label: _labels[peerId] ?? peerId,
                    latest: _monitor.latest(peerId),
                    avgLagMs: _monitor.avgLagMs(peerId),
                    points: _monitor.points(peerId),
                    staleBudgetMs: _staleBudgetMs,
                    windowSeconds: _monitor.window.inSeconds,
                  ),
              ],
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final FrequencyColors c;
  const _EmptyState({required this.c});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'No active voice streams.\nJoin a room and start talking to see '
          'per-peer throughput, lag, and staleness here.',
          textAlign: TextAlign.center,
          style: TextStyle(fontFamily: 'Inter', fontSize: 14, color: c.ink3),
        ),
      ),
    );
  }
}

class _PeerCard extends StatelessWidget {
  final FrequencyColors c;
  final String label;
  final VoiceTelemetryPoint? latest;
  final double? avgLagMs;
  final List<VoiceTelemetryPoint> points;
  final double staleBudgetMs;
  final int windowSeconds;

  const _PeerCard({
    required this.c,
    required this.label,
    required this.latest,
    required this.avgLagMs,
    required this.points,
    required this.staleBudgetMs,
    required this.windowSeconds,
  });

  @override
  Widget build(BuildContext context) {
    final p = latest;
    final lagNow = p?.lagMs ?? 0;
    // Red once staleness is over the shed budget; amber as it approaches.
    final lagColor = lagNow > staleBudgetMs
        ? const Color(0xFFE5484D)
        : (lagNow > staleBudgetMs * 0.5 ? const Color(0xFFFFB224) : c.ink);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 18,
            runSpacing: 10,
            children: [
              _Stat(
                c: c,
                label: 'lag',
                value: '$lagNow ms',
                valueColor: lagColor,
              ),
              _Stat(
                c: c,
                label: 'avg lag',
                value: avgLagMs == null ? '—' : '${avgLagMs!.round()} ms',
              ),
              _Stat(
                c: c,
                label: 'throughput',
                value: p == null
                    ? '—'
                    : '${p.throughputPerSec.toStringAsFixed(1)}/s',
              ),
              _Stat(
                c: c,
                label: 'stale drops',
                value: p == null
                    ? '—'
                    : '${p.staleDropsPerSec.toStringAsFixed(1)}/s',
              ),
              _Stat(
                c: c,
                label: 'depth',
                value: p == null ? '—' : '${p.depthFrames} fr',
              ),
              _Stat(
                c: c,
                label: 'bitrate',
                value: p == null ? '—' : '${(p.bitrateBps / 1000).round()}k',
              ),
              _Stat(c: c, label: 'seq', value: p == null ? '—' : '${p.lastSeq}'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'staleness (ms), last ${windowSeconds}s · '
            'dashed = ${staleBudgetMs.round()}ms drop budget',
            style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 64,
            width: double.infinity,
            child: CustomPaint(
              painter: _SparklinePainter(
                values: [for (final pt in points) pt.lagMs.toDouble()],
                budget: staleBudgetMs,
                lineColor: c.ink,
                budgetColor: const Color(0xFFE5484D),
                gridColor: c.line,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final FrequencyColors c;
  final String label;
  final String value;
  final Color? valueColor;

  const _Stat({
    required this.c,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: valueColor ?? c.ink,
          ),
        ),
        Text(
          label,
          style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: c.ink3),
        ),
      ],
    );
  }
}

/// Minimal dependency-free sparkline: plots [values] left→right, auto-scaled to
/// the larger of the data max and the [budget] line so the budget is always on
/// screen. Draws the budget as a dashed reference line.
class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final double budget;
  final Color lineColor;
  final Color budgetColor;
  final Color gridColor;

  _SparklinePainter({
    required this.values,
    required this.budget,
    required this.lineColor,
    required this.budgetColor,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Baseline.
    final axis = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      axis,
    );

    double maxV = budget;
    for (final v in values) {
      if (v > maxV) maxV = v;
    }
    maxV *= 1.15; // headroom so the peak isn't clipped to the top edge
    if (maxV <= 0) return;

    double yFor(double v) => size.height - (v / maxV) * size.height;

    // Dashed budget line.
    final budgetPaint = Paint()
      ..color = budgetColor.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    final by = yFor(budget);
    const dash = 5.0;
    for (double x = 0; x < size.width; x += dash * 2) {
      canvas.drawLine(Offset(x, by), Offset(x + dash, by), budgetPaint);
    }

    if (values.length < 2) return;

    final path = Path();
    final dx = size.width / (values.length - 1);
    for (var i = 0; i < values.length; i++) {
      final x = dx * i;
      final y = yFor(values[i]);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.budget != budget;
}
