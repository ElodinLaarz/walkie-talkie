import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'bloc/discovery_cubit.dart';
import 'bloc/frequency_session_cubit.dart';
import 'bloc/frequency_session_state.dart';
import 'data/frequency_mock_data.dart';
import 'screens/frequency_discovery_screen.dart';
import 'screens/frequency_onboarding_screen.dart';
import 'screens/frequency_room_screen.dart';
import 'services/bluetooth_discovery_service.dart';
import 'services/identity_store.dart';
import 'theme/app_theme.dart';
import 'widgets/frequency_toast_host.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  runApp(const WalkieTalkieApp());
}

class WalkieTalkieApp extends StatelessWidget {
  /// Override for tests; defaults to the Hive-backed implementation.
  final IdentityStore? identityStore;

  /// Override for tests; defaults to the real Bluetooth-LE implementation.
  final DiscoveryService? discoveryService;

  const WalkieTalkieApp({super.key, this.identityStore, this.discoveryService});

  @override
  Widget build(BuildContext context) {
    // If the service is not provided, we create it here. Since RepositoryProvider
    // doesn't have a dispose callback like Provider, it's safer to provide it via
    // a StatefulWidget if we need to manage its lifecycle, but for the global
    // app scope it's okay to just let it live.
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<IdentityStore>(
          create: (_) => identityStore ?? HiveIdentityStore(),
        ),
        RepositoryProvider<DiscoveryService>(
          create: (_) => discoveryService ?? DiscoveryService(),
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider(
            create: (context) => FrequencySessionCubit(
              identityStore: context.read<IdentityStore>(),
            )..bootstrap(),
          ),
          BlocProvider(
            create: (context) => DiscoveryCubit(
              context.read<DiscoveryService>(),
            ),
          ),
        ],
        child: MaterialApp(
          title: 'Frequency',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.system,
          // Wrap the navigator so toasts stay above pushed routes (modal bottom
          // sheets, etc.) — a host inside `home` would render below the modal
          // overlay and get hidden when a sheet is open.
          builder: (context, child) => FrequencyToastHost(child: child!),
          home: const FrequencyApp(),
        ),
      ),
    );
  }
}

/// Selects a screen based on the runtime type of `FrequencySessionState`.
/// State and the transitions between stages live in
/// [FrequencySessionCubit]; this widget is a pure projection.
class FrequencyApp extends StatelessWidget {
  const FrequencyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<FrequencySessionCubit, FrequencySessionState>(
      builder: (context, state) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          child: KeyedSubtree(
            key: ValueKey(state.runtimeType),
            child: _buildStage(context, state),
          ),
        );
      },
    );
  }

  Widget _buildStage(BuildContext context, FrequencySessionState state) {
    final cubit = context.read<FrequencySessionCubit>();
    return switch (state) {
      SessionBooting() => const _BootSplash(),
      SessionOnboarding() => FrequencyOnboardingScreen(
          // Wrap in a void closure so the screen's `ValueChanged<String>`
          // signature isn't asked to absorb the cubit's `Future<void>`.
          onDone: (name) {
            cubit.completeOnboarding(name);
          },
        ),
      SessionDiscovery(:final myName) => FrequencyDiscoveryScreen(
          myName: myName,
          onRename: (name) {
            cubit.rename(name);
          },
          onPick: (result) => cubit.joinRoom(
            freq: result.freq,
            isHost: result.isHost,
          ),
        ),
      SessionRoom(:final myName, :final roomFreq, :final roomIsHost) =>
        FrequencyRoomScreen(
          freq: roomFreq,
          isHost: roomIsHost,
          myName: myName,
          groupSize: 5,
          mediaKind: MediaKind.music,
          pttMode: false,
          onLeave: cubit.leaveRoom,
        ),
    };
  }
}

/// Brief blank splash while the cubit reads the persisted identity. We
/// expect Hive's box-open to take a couple of frames at most; rendering a
/// stripped-down background avoids a flash of the wrong screen.
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
