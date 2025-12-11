import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/bluetooth_bloc.dart';
import '../bloc/bluetooth_event.dart';
import '../bloc/bluetooth_state.dart';
import '../models/bluetooth_device.dart';
import 'discovery_screen.dart';

/// Main dashboard showing connected devices in orbital layout
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Start the audio service when the app launches
    context.read<BluetoothBloc>().audioService.startService();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      body: SafeArea(
        child: BlocBuilder<BluetoothBloc, BluetoothState>(
          builder: (context, state) {
            if (state is BluetoothConnectedState) {
              return _buildConnectedView(state.connectedDevices);
            } else if (state is BluetoothLoadingState) {
              return const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.deepPurple),
                    SizedBox(height: 20),
                    Text(
                      'Connecting...',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              );
            } else if (state is BluetoothErrorState) {
              return _buildErrorView(state.message);
            } else {
              return _buildEmptyView();
            }
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const DiscoveryScreen()),
          );
        },
        icon: const Icon(Icons.bluetooth_searching),
        label: const Text('Add Device'),
        backgroundColor: Colors.deepPurple,
      ),
    );
  }

  Widget _buildConnectedView(List<BluetoothDevice> devices) {
    return Column(
      children: [
        const SizedBox(height: 40),
        Text(
          'Command Center',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // Central phone icon
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Colors.deepPurple, Colors.purpleAccent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.deepPurple.withValues(alpha: 0.5),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.phone_android,
                    size: 50,
                    color: Colors.white,
                  ),
                ),
                // Orbiting devices
                ...List.generate(devices.length, (index) {
                  return _buildOrbitingDevice(
                    devices[index],
                    index,
                    devices.length,
                  );
                }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOrbitingDevice(BluetoothDevice device, int index, int total) {
    // Avoid division by zero
    if (total == 0) total = 1;

    // Calculate angle for circular positioning
    final angle = (2 * 3.14159 * index) / total;
    final radius = 150.0;
    final x = radius * math.cos(angle);
    final y = radius * math.sin(angle);

    // Position relative to the center of the 100x100 stack
    // Stack center is at (50, 50)
    // Device widget size is 80x80, so we subtract 40 to center it
    final left = 50 + x - 40;
    final top = 50 + y - 40;

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: () => _showDeviceDrawer(device),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: device.isConnected ? Colors.green : Colors.grey,
            border: Border.all(
              color: device.isActive ? Colors.yellowAccent : Colors.transparent,
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color: (device.isConnected ? Colors.green : Colors.grey)
                    .withValues(alpha: 0.5),
                blurRadius: 15,
                spreadRadius: 3,
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // VU Meter ring
              CircularProgressIndicator(
                value: device.audioLevel,
                strokeWidth: 6,
                backgroundColor: Colors.transparent,
                color: Colors.greenAccent,
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.headset, color: Colors.white, size: 30),
                  const SizedBox(height: 4),
                  Text(
                    device.displayName.length > 8
                        ? '${device.displayName.substring(0, 8)}...'
                        : device.displayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bluetooth_disabled, size: 100, color: Colors.grey[700]),
          const SizedBox(height: 20),
          Text(
            'No devices connected',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(color: Colors.grey[600]),
          ),
          const SizedBox(height: 10),
          Text(
            'Tap the button below to add devices',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey[700]),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 100, color: Colors.red[400]),
          const SizedBox(height: 20),
          Text(
            'Error',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(color: Colors.red[400]),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  void _showDeviceDrawer(BluetoothDevice device) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _DeviceDrawer(device: device),
    );
  }
}

class _DeviceDrawer extends StatefulWidget {
  final BluetoothDevice device;

  const _DeviceDrawer({required this.device});

  @override
  State<_DeviceDrawer> createState() => _DeviceDrawerState();
}

class _DeviceDrawerState extends State<_DeviceDrawer> {
  late TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.device.displayName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Device Settings',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _nameController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Device Name',
              labelStyle: TextStyle(color: Colors.grey[400]),
              suffixIcon: IconButton(
                icon: const Icon(Icons.check, color: Colors.green),
                onPressed: () {
                  context.read<BluetoothBloc>().add(
                    RenameDeviceEvent(
                      widget.device.macAddress,
                      _nameController.text,
                    ),
                  );
                  Navigator.pop(context);
                },
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey[700]!),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey[700]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.deepPurple),
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Volume Slider
          Row(
            children: [
              Icon(Icons.volume_up, color: Colors.grey[400]),
              const SizedBox(width: 16),
              Expanded(
                child: Slider(
                  value: 0.8, // Initial placeholder
                  onChanged: (value) {
                    // TODO: Implement native volume control
                  },
                  activeColor: Colors.deepPurple,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Phone Audio Toggle
          SwitchListTile(
            title: const Text(
              'Send Phone Audio',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              'Pipe YouTube/Music to this headset',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
            value: true,
            onChanged: (value) {
              // TODO: Implement native routing toggle
            },
            activeColor: Colors.deepPurple,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              context.read<BluetoothBloc>().add(
                DisconnectDeviceEvent(widget.device.macAddress),
              );
              Navigator.pop(context);
            },
            icon: const Icon(Icons.bluetooth_disabled),
            label: const Text('Disconnect'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
