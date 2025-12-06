import 'package:equatable/equatable.dart';

/// Represents a Bluetooth device
class BluetoothDevice extends Equatable {
  final String macAddress;
  final String displayName;
  final bool isConnected;
  final bool isActive;
  final double audioLevel;

  const BluetoothDevice({
    required this.macAddress,
    required this.displayName,
    this.isConnected = false,
    this.isActive = false,
    this.audioLevel = 0.0,
  });

  BluetoothDevice copyWith({
    String? macAddress,
    String? displayName,
    bool? isConnected,
    bool? isActive,
    double? audioLevel,
  }) {
    return BluetoothDevice(
      macAddress: macAddress ?? this.macAddress,
      displayName: displayName ?? this.displayName,
      isConnected: isConnected ?? this.isConnected,
      isActive: isActive ?? this.isActive,
      audioLevel: audioLevel ?? this.audioLevel,
    );
  }

  @override
  List<Object?> get props => [
    macAddress,
    displayName,
    isConnected,
    isActive,
    audioLevel,
  ];
}
