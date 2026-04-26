import 'package:equatable/equatable.dart';
import '../protocol/discovery.dart';

abstract class DiscoveryState extends Equatable {
  const DiscoveryState();

  @override
  List<Object?> get props => [];
}

class DiscoveryInitial extends DiscoveryState {}

class DiscoveryScanning extends DiscoveryState {
  final List<DiscoveredSession> sessions;

  const DiscoveryScanning({this.sessions = const []});

  @override
  List<Object?> get props => [sessions];
}

class DiscoveryStopped extends DiscoveryState {
  final List<DiscoveredSession> sessions;

  const DiscoveryStopped({this.sessions = const []});

  @override
  List<Object?> get props => [sessions];
}
