import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'bloc/discovery_cubit.dart';
import 'bloc/frequency_session_cubit.dart';
import 'bloc/frequency_session_state.dart';
import 'data/frequency_models.dart';
import 'l10n/generated/app_localizations.dart';
import 'screens/frequency_discovery_screen.dart';
import 'screens/frequency_onboarding_screen.dart';
import 'screens/frequency_permission_denied_screen.dart';
import 'screens/frequency_room_screen.dart';
import 'services/audio_service.dart';
import 'services/ble_control_transport.dart';
import 'services/blocked_peers_store.dart';
import 'services/bluetooth_discovery_service.dart';
import 'services/identity_store.dart';
import 'services/native_licenses.dart';
import 'services/onboarding_permission_gateway.dart';
import 'services/permission_watcher.dart';
import 'services/recent_frequencies_store.dart';
import 'services/settings_store.dart';
import 'services/storage_migration.dart';
import 'theme/app_theme.dart';
import 'widgets/frequency_toast_host.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // sqflite is the v1 store; this is a one-shot copy of any legacy Hive
  // data on installs that had it. Subsequent launches see the marker in
  // the `kv` table and skip Hive init entirely.
  await migrateHiveToSqliteIfNeeded();
  // Make Oboe (Apache-2.0) + Opus (BSD-3-Clause) license texts available to
  // the in-app `LicensePage`. Pure-Dart deps are auto-discovered, but our
  // vendored C++ libs aren't, so we register their `LICENSE`/`COPYING`
  // files explicitly. The closure passed to `LicenseRegistry.addLicense`
  // is only invoked when the LicensePage is opened, so this doesn't add
  // startup latency — and the registration call itself is synchronous.
  registerNativeLicenses();

  // Check crash reporting opt-in preference.
  final settingsStore = SqfliteSettingsStore();
  final crashReportingEnabled = await settingsStore.getCrashReportingEnabled();

  if (crashReportingEnabled) {
    // Sentry DSN should be provided via build args or environment variable.
    // For now, we'll set up the infrastructure but won't initialize without a DSN.
    const sentryDsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');

    if (sentryDsn.isNotEmpty) {
      await SentryFlutter.init(
        (options) {
          options.dsn = sentryDsn;
          // Enable session tracking
          options.enableAutoSessionTracking = true;
          // Sample rate: 100% for crashes (privacy-first app, low volume)
          options.sampleRate = 1.0;
          // Attach stack traces to messages
          options.attachStacktrace = true;
          // Redact PII before sending
          options.beforeSend = (event, hint) {
            return _sanitizeEvent(event);
          };
        },
        appRunner: () => runApp(WalkieTalkieApp(settingsStore: settingsStore)),
      );
      return;
    }
  }

  // Opt-out path or missing DSN: run without Sentry
  runApp(WalkieTalkieApp(settingsStore: settingsStore));
}

// Matches any key/field containing a display-name identifier, regardless of
// separator (camelCase, snake_case, or space-separated).
final _piiKeyRegex = RegExp(r'display[_ ]?name', caseSensitive: false);
// Matches "display_?name: <value>" in free-form text, capturing through the
// next comma or semicolon so multi-word values are fully redacted.
final _piiMessageRegex = RegExp(r'display[_ ]?name[:\s]*[^,;]+', caseSensitive: false);

/// Sanitizes Sentry events to remove PII.
/// Redacts display names from contexts and breadcrumbs.
/// Keeps peerId as it's documented as an anonymous identifier.
SentryEvent? _sanitizeEvent(SentryEvent event) {
  // Direct mutation — SentryContexts is mutable in sentry 9.x.
  event.contexts.removeWhere((key, _) => _piiKeyRegex.hasMatch(key));

  // Mutate breadcrumbs in-place — SentryBreadcrumb is mutable in sentry 9.x.
  for (final crumb in event.breadcrumbs ?? const []) {
    final msg = crumb.message;
    if (msg != null && _piiMessageRegex.hasMatch(msg)) {
      crumb.message = msg.replaceAll(_piiMessageRegex, 'displayName: [REDACTED]');
    }

    final data = crumb.data;
    if (data != null && data.keys.any(_piiKeyRegex.hasMatch)) {
      crumb.data = Map.fromEntries(data.entries.map((e) {
        return _piiKeyRegex.hasMatch(e.key) ? MapEntry(e.key, '[REDACTED]') : e;
      }));
    }
  }

  return event;
}

class WalkieTalkieApp extends StatefulWidget {
  /// Override for tests; defaults to the sqflite-backed implementation.
  final IdentityStore? identityStore;

  /// Override for tests; defaults to the sqflite-backed implementation.
  final RecentFrequenciesStore? recentFrequenciesStore;

  /// Override for tests; defaults to the sqflite-backed implementation.
  final BlockedPeersStore? blockedPeersStore;

  /// Override for tests; defaults to the real Bluetooth-LE implementation.
  final DiscoveryService? discoveryService;

  /// Override for tests; defaults to the real [AudioService] backed by
  /// the native MethodChannel/EventChannel.
  final AudioService? audioService;

  /// Override for tests; defaults to [DefaultPermissionWatcher] which polls
  /// permissions on app resume + every 5 s. Tests inject a fake to drive
  /// the revocation flow without permission_handler's platform channel.
  final PermissionWatcher? permissionWatcher;

  /// Production: the [SqfliteSettingsStore] created in [main] so the same
  /// instance is shared between the Sentry init path and the widget tree.
  /// Override in tests to inject a fake without touching the platform channel.
  final SettingsStore? settingsStore;

  const WalkieTalkieApp({
    super.key,
    this.identityStore,
    this.recentFrequenciesStore,
    this.blockedPeersStore,
    this.discoveryService,
    this.audioService,
    this.permissionWatcher,
    this.settingsStore,
  });

  @override
  State<WalkieTalkieApp> createState() => _WalkieTalkieAppState();
}

class _WalkieTalkieAppState extends State<WalkieTalkieApp> {
  /// Owned by this State so [PermissionWatcher.dispose] runs deterministically
  /// when the app widget is unmounted (hot restart, tests, embedded usage).
  /// `flutter_bloc` 8.1.6's [RepositoryProvider] suppresses the underlying
  /// `dispose:` parameter, so we own the lifecycle here and inject the
  /// instance into the provider below — only test-supplied watchers (whose
  /// owner is the test) are skipped.
  PermissionWatcher? _ownedWatcher;

  @override
  void initState() {
    super.initState();
    if (widget.permissionWatcher == null) {
      _ownedWatcher = DefaultPermissionWatcher();
    }
  }

  @override
  void didUpdateWidget(covariant WalkieTalkieApp old) {
    super.didUpdateWidget(old);
    // Reconcile [permissionWatcher] across parent rebuilds: if the caller
    // flips between supplying a watcher and asking us to own one (rare in
    // production, but reachable from a test that switches fakes), make
    // sure we either dispose what we owned or stand up a fresh default.
    final wasOwning = old.permissionWatcher == null;
    final stillOwning = widget.permissionWatcher == null;
    if (wasOwning && !stillOwning) {
      // We owned it; the caller is now supplying one. Release ours.
      unawaited(_ownedWatcher?.dispose());
      _ownedWatcher = null;
    } else if (!wasOwning && stillOwning) {
      // The caller dropped the supplied watcher; mint a default so build()
      // never sees a null on both sides.
      _ownedWatcher = DefaultPermissionWatcher();
    }
  }

  @override
  void dispose() {
    // Only dispose if we created it; a caller-supplied watcher is the
    // caller's responsibility to release.
    unawaited(_ownedWatcher?.dispose());
    _ownedWatcher = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final watcher = widget.permissionWatcher ?? _ownedWatcher!;
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<IdentityStore>(
          create: (_) => widget.identityStore ?? SqfliteIdentityStore(),
        ),
        RepositoryProvider<RecentFrequenciesStore>(
          create: (_) =>
              widget.recentFrequenciesStore ?? SqfliteRecentFrequenciesStore(),
        ),
        RepositoryProvider<BlockedPeersStore>(
          create: (_) =>
              widget.blockedPeersStore ?? SqfliteBlockedPeersStore(),
        ),
        RepositoryProvider<SettingsStore>(
          create: (_) => widget.settingsStore ?? SqfliteSettingsStore(),
        ),
        RepositoryProvider<DiscoveryService>(
          create: (_) => widget.discoveryService ?? DiscoveryService(),
        ),
        RepositoryProvider<AudioService>(
          create: (_) => widget.audioService ?? AudioService(),
        ),
        RepositoryProvider<BleControlTransport>(
          create: (context) =>
              BleControlTransport(context.read<AudioService>()),
        ),
        RepositoryProvider<PermissionWatcher>.value(value: watcher),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider(
            create: (context) => FrequencySessionCubit(
              identityStore: context.read<IdentityStore>(),
              recentFrequenciesStore:
                  context.read<RecentFrequenciesStore>(),
              transport: context.read<BleControlTransport>(),
              audio: context.read<AudioService>(),
              permissionWatcher: context.read<PermissionWatcher>(),
            )..bootstrap(),
          ),
          BlocProvider(
            create: (context) => DiscoveryCubit(
              context.read<DiscoveryService>(),
            ),
          ),
        ],
        child: MaterialApp(
          onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.system,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
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
///
/// Stateful so it can cache user settings (PTT mode) without re-reading from
/// sqflite on every BlocBuilder rebuild. Settings are loaded once in
/// [initState] via a post-frame callback (context is available after the first
/// frame) and refreshed when the app returns from the Settings screen.
class FrequencyApp extends StatefulWidget {
  const FrequencyApp({super.key});

  @override
  State<FrequencyApp> createState() => _FrequencyAppState();
}

class _FrequencyAppState extends State<FrequencyApp> with WidgetsBindingObserver {
  bool _pttMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Post-frame callback so context.read is available.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reloadSettings());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-read PTT mode when the app resumes — the user may have changed it
    // in the Settings screen and returned without the navigator popping into
    // a rebuild of this widget.
    if (state == AppLifecycleState.resumed) _reloadSettings();
  }

  Future<void> _reloadSettings() async {
    if (!mounted) return;
    final ptt = await context.read<SettingsStore>().getPttModeEnabled();
    if (mounted && ptt != _pttMode) setState(() => _pttMode = ptt);
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<FrequencySessionCubit, FrequencySessionState>(
      // Reload PTT mode whenever the state transitions into SessionRoom so that
      // a setting changed in the Settings screen (navigator push/pop — which
      // does NOT trigger AppLifecycleState.resumed) is picked up before the
      // room screen renders.
      listenWhen: (prev, next) => next is SessionRoom && prev is! SessionRoom,
      listener: (context, state) => _reloadSettings(),
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
      SessionDiscovery(:final myName, :final recentHostedFrequencies) =>
        FrequencyDiscoveryScreen(
          myName: myName,
          recentHostedFrequencies: recentHostedFrequencies,
          onRename: (name) {
            cubit.rename(name);
          },
          onSetRecentNickname: (freq, nickname) {
            unawaited(cubit.setRecentNickname(freq, nickname));
          },
          onSetRecentPinned: (freq, pinned) {
            unawaited(cubit.setRecentPinned(freq, pinned));
          },
          // joinRoom is a Future<void> now that it persists; the cubit
          // tolerates a fire-and-forget call (the user has already
          // committed to entering the room).
          onPick: (result) {
            unawaited(
              cubit.joinRoom(
                isHost: result.isHost,
                // Host path ignores `freq` — the cubit derives it from a
                // freshly-minted sessionUuid (#39). Pass it through anyway
                // for the guest path, where it carries the discovered
                // session's cosmetic mhzDisplay.
                freq: result.isHost ? null : result.freq,
                macAddress: result.macAddress,
                sessionUuidLow8: result.sessionUuidLow8,
              ),
            );
          },
        ),
      SessionRoom(:final myName, :final roomFreq, :final roomIsHost) =>
        FrequencyRoomScreen(
          freq: roomFreq,
          isHost: roomIsHost,
          myName: myName,
          mediaKind: MediaKind.music,
          pttMode: _pttMode,
          // Pass the singleton from the provider so the screen reuses the
          // one instance (#129) — its own fallback would otherwise build a
          // second AudioService whose audioEvents/controlBytes stream
          // caches diverge from the rest of the app.
          audioService: context.read<AudioService>(),
          // `leaveRoom` is async (re-reads recent frequencies before
          // emitting), but `onLeave` is a sync VoidCallback — wrap
          // explicitly so the discarded future is intentional rather
          // than a tear-off lint.
          onLeave: () {
            unawaited(cubit.leaveRoom());
          },
        ),
      SessionPermissionDenied(:final missing) =>
        FrequencyPermissionDeniedScreen(
          missing: missing,
          onOpenSettings: const DefaultOnboardingPermissionGateway()
              .openAppSettings,
          onRetry: cubit.recheckPermissions,
        ),
    };
  }
}

/// Brief blank splash while the cubit reads the persisted identity. We
/// expect sqflite's first-open to take a couple of frames at most;
/// rendering a stripped-down background avoids a flash of the wrong screen.
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
