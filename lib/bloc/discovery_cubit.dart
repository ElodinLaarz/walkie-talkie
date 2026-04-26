import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../protocol/discovery.dart';
import '../services/bluetooth_discovery_service.dart';
import 'discovery_state.dart';

class DiscoveryCubit extends Cubit<DiscoveryState> {
  final DiscoveryService _discoveryService;
  StreamSubscription? _subscription;

  DiscoveryCubit(this._discoveryService) : super(DiscoveryInitial());

  Future<void> startDiscovery() async {
    emit(const DiscoveryScanning());
    await _subscription?.cancel();
    _subscription = _discoveryService.results.listen((sessions) {
      emit(DiscoveryScanning(sessions: sessions));
    });
    try {
      await _discoveryService.startScan();
    } catch (_) {
      await _subscription?.cancel();
      _subscription = null;
      final sessions = state is DiscoveryScanning
          ? (state as DiscoveryScanning).sessions
          : (state is DiscoveryStopped
              ? (state as DiscoveryStopped).sessions
              : const <DiscoveredSession>[]);
      emit(DiscoveryStopped(sessions: sessions));
    }
  }

  Future<void> stopDiscovery() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await _discoveryService.stopScan();
    emit(const DiscoveryStopped());
  }

  @override
  Future<void> close() async {
    await _discoveryService.stopScan();
    await _subscription?.cancel();
    return super.close();
  }
}
