import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../protocol/discovery.dart';

/// DiscoveryService scans for nearby Frequency hosts using Bluetooth LE.
class DiscoveryService {
  /// How long a host can go un-advertised before it's considered out of range
  /// and pruned from the emitted list. Hosts advertise on the order of
  /// 100-1000 ms, so 10 s tolerates a couple of dropped windows without
  /// blanking a still-present session.
  static const Duration freshnessWindow = Duration(seconds: 10);

  final StreamController<List<DiscoveredSession>> _resultsController =
      StreamController<List<DiscoveredSession>>.broadcast();

  Stream<List<DiscoveredSession>> get results => _resultsController.stream;

  final Map<String, ({DiscoveredSession session, DateTime lastSeen})>
  _discovered = {};
  StreamSubscription? _scanSubscription;

  /// Fires [_emit] on a fixed cadence so stale entries are pruned even when
  /// no BLE advertisements arrive (e.g. every host went silent simultaneously).
  Timer? _pruneTimer;

  /// Signature of the last set pushed to [results]. Used to coalesce the
  /// high-frequency scan callbacks (see [_emit]) so we don't rebuild the UI on
  /// every advertisement when the visible set hasn't actually changed.
  String? _lastEmittedSig;

  // Timeout for Bluetooth pre-flight checks. Long enough for a healthy stack,
  // short enough to unblock discovery on flaky OEM stacks (#432).
  static const Duration _kBtCheckTimeout = Duration(seconds: 3);

  /// Starts scanning for Frequency advertisements.
  Future<void> startScan() async {
    // 1. Check if Bluetooth is available and on.
    final supported = await FlutterBluePlus.isSupported.timeout(
      _kBtCheckTimeout,
      onTimeout: () => false,
    );
    if (!supported) {
      throw Exception('Bluetooth LE is not supported on this device');
    }

    // Apply the timeout to the stream before .first so the subscription is
    // cancelled on timeout (Future.timeout() cannot cancel a stream sub, #432).
    final adapterState = await FlutterBluePlus.adapterState
        .timeout(
          _kBtCheckTimeout,
          onTimeout: (sink) {
            sink.add(BluetoothAdapterState.unknown);
            sink.close();
          },
        )
        .first;
    if (adapterState != BluetoothAdapterState.on) {
      throw Exception('Bluetooth adapter is not on');
    }

    // Check runtime permissions.
    final scanStatus = await Permission.bluetoothScan.request();
    final connectStatus = await Permission.bluetoothConnect.request();
    if (!scanStatus.isGranted || !connectStatus.isGranted) {
      throw Exception('Bluetooth permissions denied');
    }

    _discovered.clear();
    _lastEmittedSig = null;
    _emit();

    // 2. Listen for scan results.
    // onScanResults is preferred over scanResults: it does not replay stale
    // results after scanning stops, avoiding a spurious re-emission on the
    // next startScan() call before the new results arrive.
    await _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
      for (ScanResult r in results) {
        final session = parseResult(r);
        if (session != null) {
          final existing = _discovered[session.sessionUuidLow8];
          final resolvedHostName =
              (session.hostName.isEmpty && existing != null)
              ? existing.session.hostName
              : session.hostName;

          final resolvedSession = resolvedHostName == session.hostName
              ? session
              : DiscoveredSession(
                  protocolVersion: session.protocolVersion,
                  isHost: session.isHost,
                  sessionUuidLow8: session.sessionUuidLow8,
                  flags: session.flags,
                  hostName: resolvedHostName,
                  rssi: session.rssi,
                  macAddress: session.macAddress,
                );

          _discovered[session.sessionUuidLow8] = (
            session: resolvedSession,
            lastSeen: DateTime.now(),
          );
        }
      }
      // Coalesced emit: pushes only when the visible set changed (see [_emit]).
      // continuousUpdates:true forwards a host's advertisement several times a
      // second, but the NEARBY list rarely changes that fast — gating here
      // avoids rebuilding the UI on every packet. Time-based pruning and RSSI
      // refresh are handled by the prune timer's forced emit below.
      _emit();
    });
    // Auto-cancel the subscription if the OS stops the scan unexpectedly
    // (e.g. adapter turned off, or platform scan timeout).
    FlutterBluePlus.cancelWhenScanComplete(_scanSubscription!);

    // 3. Start scanning with a manufacturer-data ScanFilter (NOT a UUID one).
    //
    // Two constraints have to be satisfied at once:
    //
    //  a) The scan MUST be filtered. Android demotes an *unfiltered* scan to
    //     opportunistic mode after a timeout (logcat: BtScan.ScanManager
    //     "Moving unfiltered scan to opportunistic scan"). Once demoted, the
    //     host's advertisements stop arriving and the session is pruned from
    //     NEARBY — discovery silently dies a minute or two into a session, so
    //     tune-in and rejoin become impossible. A ScanFilter keeps the scan in
    //     regular (non-opportunistic) mode and additionally permits screen-off
    //     scanning.
    //
    //  b) The filter must NOT be a 128-bit service-UUID filter. Some OEM BLE
    //     stacks (MediaTek-based Motorola devices) advertise the UUID in
    //     non-standard byte order, so a withServices filter silently drops
    //     their advertisements before parseResult ever sees them (#361).
    //
    // Filtering on the manufacturer-data payload satisfies both: it keeps the
    // scan filtered while matching the actual bytes the host controls, which is
    // encoding-order agnostic. We match the manufacturer id plus the fixed
    // [version=0x01, role=0x01] prefix; parseResult still does the full
    // software validation (see DiscoveredSession.fromManufacturerData).
    await FlutterBluePlus.startScan(
      // No timeout — user controls start/stop; avoids silent timeout failures.
      withMsd: [
        MsdFilter(
          0xFFFF, // HostAdvertiser.MANUFACTURER_ID
          data: [0x01, 0x01], // protocol v1 + host role
          mask: [0xFF, 0xFF],
        ),
      ],
      // Process EVERY matching advertisement, not just the first.
      //
      // The host's manufacturer payload is static, and FlutterBluePlus's default
      // (continuousUpdates: false) forwards a given device to onScanResults only
      // once — on first discovery. With a static payload behind a hardware
      // ScanFilter the controller stops re-reporting, so lastSeen is never
      // refreshed and the freshnessWindow prunes a host that is still in range.
      // continuousUpdates keeps lastSeen ticking on every received advertisement,
      // which is what keeps a present host on the NEARBY list.
      continuousUpdates: true,
    );

    // Start prune timer only after scan starts successfully. This prevents a
    // resource leak where a failed startScan leaves the timer firing into a
    // scan-less void.
    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(
      freshnessWindow ~/ 2,
      (_) => _emit(force: true),
    );
  }

  /// Stops the active scan.
  Future<void> stopScan() async {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    await FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
  }

  /// Prunes stale entries and pushes the current set to [results].
  ///
  /// Scan callbacks call this unforced: it pushes only when the visible set's
  /// identity changed since the last emit (membership, host name, role or
  /// flags), coalescing the per-advertisement churn that `continuousUpdates`
  /// produces. RSSI is deliberately excluded from the signature — it fluctuates
  /// on every packet and would defeat the coalescing.
  ///
  /// The prune timer calls this with [force] `true` on a fixed cadence so stale
  /// entries are still removed (and RSSI refreshed) even while membership is
  /// steady or every host has gone silent.
  void _emit({bool force = false}) {
    final cutoff = DateTime.now().subtract(freshnessWindow);
    _discovered.removeWhere((_, entry) => entry.lastSeen.isBefore(cutoff));
    final sessions = _discovered.values.map((e) => e.session).toList();
    final sig =
        (_discovered.values
              .map(
                (e) =>
                    '${e.session.sessionUuidLow8}|${e.session.isHost}'
                    '|${e.session.flags}|${e.session.hostName}',
              )
              .toList()
            ..sort())
            .join(',');
    if (!force && sig == _lastEmittedSig) return;
    _lastEmittedSig = sig;
    _resultsController.add(sessions);
  }

  @visibleForTesting
  DiscoveredSession? parseResult(ScanResult r) {
    // Manufacturer data is a Map<int, List<int>>.
    for (final entry in r.advertisementData.manufacturerData.entries) {
      final data = Uint8List.fromList(entry.value);
      final session = DiscoveredSession.fromManufacturerData(
        data,
        hostName: r.advertisementData.advName,
        rssi: r.rssi,
        macAddress: r.device.remoteId.str,
      );
      if (session != null) return session;
    }
    return null;
  }

  Future<void> dispose() async {
    // stopScan() touches the platform adapter and the scan subscription, both
    // of which can throw (e.g. FlutterBluePlus.stopScan() rejecting on a
    // disposed adapter). Close the controller in a finally so a throwing
    // stopScan never leaks the broadcast controller.
    try {
      await stopScan();
    } finally {
      await _resultsController.close();
    }
  }
}
