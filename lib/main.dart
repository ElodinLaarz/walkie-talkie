import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'bloc/bluetooth_bloc.dart';
import 'data/frequency_mock_data.dart';
import 'screens/frequency_discovery_screen.dart';
import 'screens/frequency_onboarding_screen.dart';
import 'screens/frequency_room_screen.dart';
import 'services/audio_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  runApp(const WalkieTalkieApp());
}

class WalkieTalkieApp extends StatelessWidget {
  const WalkieTalkieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => BluetoothBloc(audioService: AudioService()),
      child: MaterialApp(
        title: 'Frequency',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        home: const FrequencyApp(),
      ),
    );
  }
}

/// Root navigator for the prototype: Onboarding → Discovery → Room.
class FrequencyApp extends StatefulWidget {
  const FrequencyApp({super.key});

  @override
  State<FrequencyApp> createState() => _FrequencyAppState();
}

enum _Stage { onboarding, discovery, room }

class _FrequencyAppState extends State<FrequencyApp> {
  _Stage _stage = _Stage.onboarding;
  String _myName = '';
  String _freq = '104.3';
  bool _isHost = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      child: KeyedSubtree(
        key: ValueKey(_stage),
        child: _buildStage(),
      ),
    );
  }

  Widget _buildStage() {
    switch (_stage) {
      case _Stage.onboarding:
        return FrequencyOnboardingScreen(
          onDone: (name) => setState(() {
            _myName = name;
            _stage = _Stage.discovery;
          }),
        );
      case _Stage.discovery:
        return FrequencyDiscoveryScreen(
          onPick: (result) => setState(() {
            _freq = result.freq;
            _isHost = result.isHost;
            _stage = _Stage.room;
          }),
        );
      case _Stage.room:
        return FrequencyRoomScreen(
          freq: _freq,
          isHost: _isHost,
          myName: _myName,
          groupSize: 5,
          mediaKind: MediaKind.music,
          pttMode: false,
          onLeave: () => setState(() => _stage = _Stage.discovery),
        );
    }
  }
}
