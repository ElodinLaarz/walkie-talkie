import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/bluetooth_bloc.dart';
import '../bloc/bluetooth_event.dart';
import '../bloc/bluetooth_state.dart';
import '../models/bluetooth_device.dart';

/// Screen for discovering and connecting to Bluetooth LE Audio devices
class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    // Start scanning when the screen loads
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isDisposed && mounted) {
        context.read<BluetoothBloc>().add(const StartScanEvent());
      }
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    // Stop scanning when leaving the screen
    if (mounted) {
      context.read<BluetoothBloc>().add(const StopScanEvent());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<BluetoothBloc, BluetoothState>(
      listener: (context, state) {
        if (state is BluetoothConnectedState) {
          // Go back to home screen when connected
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0E27),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text(
            'Discover Devices',
            style: TextStyle(color: Colors.white),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: BlocBuilder<BluetoothBloc, BluetoothState>(
          builder: (context, state) {
            // Handle different states
            if (state is BluetoothScanningState) {
              return _buildScanningView(state.discoveredDevices);
            } else if (state is BluetoothLoadingState) {
              return _buildLoadingView();
            } else if (state is BluetoothConnectedState) {
              return _buildLoadingView(); // Show loading while popping
            } else if (state is BluetoothErrorState) {
              return _buildErrorView(state.message);
            } else {
              // Initial state - start scanning
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !_isDisposed) {
                  context.read<BluetoothBloc>().add(const StartScanEvent());
                }
              });
              return _buildEmptyView();
            }
          },
        ),
      ),
    );
  }

  Widget _buildScanningView(List<BluetoothDevice> devices) {
    return Column(
      children: [
        // Radar animation
        SizedBox(
          height: 200,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Radar circles
              ...List.generate(3, (index) {
                return AnimatedContainer(
                  duration: Duration(milliseconds: 1500 + (index * 300)),
                  width: 100.0 + (index * 50),
                  height: 100.0 + (index * 50),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.deepPurple.withValues(
                        alpha: 0.3 - (index * 0.1),
                      ),
                      width: 2,
                    ),
                  ),
                );
              }),
              // Center icon
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.deepPurple,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.deepPurple.withValues(alpha: 0.5),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.bluetooth_searching,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Scanning for devices...',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(color: Colors.white),
        ),
        const SizedBox(height: 30),
        Expanded(
          child: devices.isEmpty
              ? Center(
                  child: Text(
                    'No devices found yet',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    return _buildDeviceCard(devices[index]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDeviceCard(BluetoothDevice device) {
    return Card(
      color: const Color(0xFF1A1F3A),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [Colors.deepPurple, Colors.purpleAccent],
            ),
          ),
          child: const Icon(Icons.headset, color: Colors.white),
        ),
        title: Text(
          device.displayName,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          device.macAddress,
          style: TextStyle(color: Colors.grey[500]),
        ),
        trailing: ElevatedButton(
          onPressed: () {
            context.read<BluetoothBloc>().add(
              ConnectDeviceEvent(device.macAddress),
            );
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepPurple,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Connect'),
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.deepPurple),
          SizedBox(height: 20),
          Text('Connecting...', style: TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  Widget _buildErrorView(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 80, color: Colors.red[400]),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              message,
              style: TextStyle(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bluetooth, size: 80, color: Colors.grey[700]),
          const SizedBox(height: 20),
          Text('Ready to scan', style: TextStyle(color: Colors.grey[600])),
        ],
      ),
    );
  }
}
