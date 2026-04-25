import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'data/frequency_mock_data.dart';
import 'screens/frequency_discovery_screen.dart';
import 'screens/frequency_onboarding_screen.dart';
import 'screens/frequency_room_screen.dart';
import 'services/identity_store.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  runApp(const WalkieTalkieApp());
}

class WalkieTalkieApp extends StatelessWidget {
  /// Override for tests; defaults to the Hive-backed implementation.
  final IdentityStore? identityStore;

  const WalkieTalkieApp({super.key, this.identityStore});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frequency',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: FrequencyApp(identityStore: identityStore ?? HiveIdentityStore()),
    );
  }
}

/// Root navigator for the prototype: Onboarding → Discovery → Room.
///
/// On startup we read a persisted display name from [identityStore]. If one is
/// present we skip onboarding and land on Discovery; otherwise the user is
/// taken through the onboarding flow and the chosen name is persisted.
class FrequencyApp extends StatefulWidget {
  final IdentityStore identityStore;

  const FrequencyApp({super.key, required this.identityStore});

  @override
  State<FrequencyApp> createState() => _FrequencyAppState();
}

enum _Stage { booting, onboarding, discovery, room }

class _FrequencyAppState extends State<FrequencyApp> {
  _Stage _stage = _Stage.booting;
  String _myName = '';
  String _freq = '104.3';
  bool _isHost = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    String? persisted;
    try {
      persisted = await widget.identityStore.getDisplayName();
    } catch (error, stackTrace) {
      // Hive lives on the filesystem; corruption or disk failure can throw
      // here. Don't strand the user on the splash — fall back to onboarding,
      // which will overwrite whatever was on disk on completion.
      debugPrint('Failed to load persisted display name: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (!mounted) return;
    setState(() {
      if (persisted != null) {
        _myName = persisted;
        _stage = _Stage.discovery;
      } else {
        _stage = _Stage.onboarding;
      }
    });
  }

  Future<void> _onOnboardingDone(String name) async {
    try {
      await widget.identityStore.setDisplayName(name);
    } catch (error, stackTrace) {
      // Persistence failed — accept the in-memory name so the user isn't
      // stranded on the name screen. They'll be re-onboarded next launch.
      debugPrint('Failed to persist display name: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (!mounted) return;
    setState(() {
      _myName = name;
      _stage = _Stage.discovery;
    });
  }

  Future<void> _onRenameRequested(String name) async {
    try {
      await widget.identityStore.setDisplayName(name);
    } catch (error, stackTrace) {
      // Same trade-off as onboarding completion: keep the new name in memory
      // so the rename UI feels responsive; the failure surfaces next launch
      // when the previous name is loaded back.
      debugPrint('Failed to persist display name: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (!mounted) return;
    setState(() => _myName = name);
  }

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
      case _Stage.booting:
        return const _BootSplash();
      case _Stage.onboarding:
        return FrequencyOnboardingScreen(onDone: _onOnboardingDone);
      case _Stage.discovery:
        return FrequencyDiscoveryScreen(
          myName: _myName,
          onRename: _onRenameRequested,
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

/// Brief blank splash while we read the persisted identity. We expect Hive's
/// box open to take a couple frames at most; rendering a stripped-down
/// background avoids a flash of the wrong screen.
class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: const SizedBox.expand(),
    );
  }
}
