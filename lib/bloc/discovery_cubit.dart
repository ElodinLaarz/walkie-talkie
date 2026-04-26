import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../protocol/discovery.dart';
import '../services/bluetooth_discovery_service.dart';
import 'discovery_state.dart';

class DiscoveryCubit extends Cubit<DiscoveryState> {
  final DiscoveryService _discoveryService;
  StreamSubscription? _subscription;

  DiscoveryCubit(this._discoveryService) : super(DiscoveryInitial());

  void startDiscovery() {
    _subscription?.cancel();
    _subscription = _discoveryService.results.listen((sessions) {
      emit(DiscoveryScanning(sessions: sessions));
    });
    _discoveryService.startScan();
    emit(const DiscoveryScanning());
  }

  void stopDiscovery() {
    _discoveryService.stopScan();
    final sessions = state is DiscoveryScanning
        ? (state as DiscoveryScanning).sessions
        : (state is DiscoveryStopped
            ? (state as DiscoveryStopped).sessions
            : const <DiscoveredSession>[]);
    emit(DiscoveryStopped(sessions: sessions));
    _subscription?.cancel();
  }

  @override
  Future<void> close() {
    _subscription?.cancel();
    return super.close();
  }
}
