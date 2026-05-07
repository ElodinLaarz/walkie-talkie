import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:walkie_talkie/bloc/frequency_session_cubit.dart';
import 'package:walkie_talkie/bloc/frequency_session_state.dart';
import 'package:walkie_talkie/l10n/generated/app_localizations.dart';
import 'package:walkie_talkie/screens/frequency_privacy_policy_screen.dart';
import 'package:walkie_talkie/screens/frequency_settings_screen.dart';
import 'package:walkie_talkie/screens/security_faq_screen.dart';
import 'package:walkie_talkie/services/blocked_peers_store.dart';
import 'package:walkie_talkie/services/identity_store.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';
import 'package:walkie_talkie/services/settings_store.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/frequency_atoms.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

class _FakeSettingsStore implements SettingsStore {
  bool pttMode;
  bool keepScreenOn;
  bool cleared = false;
  final bool throwOnClear;

  final List<(String, bool)> calls = [];

  _FakeSettingsStore({
    this.pttMode = false,
    this.keepScreenOn = false,
    this.throwOnClear = false,
  });

  @override
  Future<bool> getPttModeEnabled() async => pttMode;

  @override
  Future<void> setPttModeEnabled(bool v) async => calls.add(('setPttMode', v));

  @override
  Future<bool> getKeepScreenOn() async => keepScreenOn;

  @override
  Future<void> setKeepScreenOn(bool v) async =>
      calls.add(('setKeepScreenOn', v));

  @override
  Future<bool> getCrashReportingEnabled() async => false;

  @override
  Future<void> setCrashReportingEnabled(bool v) async =>
      calls.add(('setCrashReporting', v));

  int clearCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls++;
    if (throwOnClear) throw StateError('boom');
    pttMode = false;
    keepScreenOn = false;
    cleared = true;
  }
}

FreqSwitch _findToggleFor(WidgetTester tester, String label) {
  return tester.widget<FreqSwitch>(
    find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
      matching: find.byType(FreqSwitch),
    ),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PackageInfo.setMockInitialValues(
      appName: 'Frequency',
      packageName: 'com.elodin.walkie_talkie',
      version: '1.2.3',
      buildNumber: '42',
      buildSignature: '',
      installerStore: null,
    );
  });

  group('FrequencySettingsScreen', () {
    testWidgets('renders the Settings title in the app bar', (tester) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('renders Voice, Display, Privacy and About section headers', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      final list = find.byType(ListView);
      for (final header in ['VOICE', 'DISPLAY', 'PRIVACY', 'ABOUT']) {
        await tester.dragUntilVisible(
          find.text(header),
          list,
          const Offset(0, -200),
        );
        expect(find.text(header), findsOneWidget, reason: '$header missing');
      }
    });

    testWidgets('PTT mode toggle is visible', (tester) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Push-to-talk mode'), findsOneWidget);
    });

    testWidgets('PTT mode toggle reflects initial false value from store', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          FrequencySettingsScreen(
            settingsStore: _FakeSettingsStore(pttMode: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_findToggleFor(tester, 'Push-to-talk mode').value, isFalse);
    });

    testWidgets('PTT mode toggle reflects initial true value from store', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          FrequencySettingsScreen(
            settingsStore: _FakeSettingsStore(pttMode: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_findToggleFor(tester, 'Push-to-talk mode').value, isTrue);
    });

    testWidgets('tapping PTT toggle calls setPttModeEnabled and flips state', (
      tester,
    ) async {
      final store = _FakeSettingsStore(pttMode: false);
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: store)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Push-to-talk mode'));
      await tester.pump();

      expect(store.calls, contains(('setPttMode', true)));
      expect(_findToggleFor(tester, 'Push-to-talk mode').value, isTrue);
    });

    testWidgets('Keep screen on toggle is visible', (tester) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Keep screen on'), findsOneWidget);
    });

    testWidgets(
      'Keep screen on toggle reflects initial false value from store',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            FrequencySettingsScreen(
              settingsStore: _FakeSettingsStore(keepScreenOn: false),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(_findToggleFor(tester, 'Keep screen on').value, isFalse);
      },
    );

    testWidgets(
      'Keep screen on toggle reflects initial true value from store',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            FrequencySettingsScreen(
              settingsStore: _FakeSettingsStore(keepScreenOn: true),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(_findToggleFor(tester, 'Keep screen on').value, isTrue);
      },
    );

    testWidgets(
      'tapping Keep screen on toggle calls setKeepScreenOn and flips state',
      (tester) async {
        final store = _FakeSettingsStore(keepScreenOn: false);
        await tester.pumpWidget(
          _wrap(FrequencySettingsScreen(settingsStore: store)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.bySemanticsLabel('Keep screen on'));
        await tester.pump();

        expect(store.calls, contains(('setKeepScreenOn', true)));
        expect(_findToggleFor(tester, 'Keep screen on').value, isTrue);
      },
    );

    testWidgets(
      'Crash reporting row is visible and disabled when Sentry is not configured',
      (tester) async {
        await tester.pumpWidget(
          _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
        );
        await tester.pumpAndSettle();

        await tester.dragUntilVisible(
          find.text('Crash reporting'),
          find.byType(ListView),
          const Offset(0, -200),
        );
        expect(find.text('Crash reporting'), findsOneWidget);

        // kSentryConfigured is always false in test builds, so the toggle must
        // be inert (onChanged == null on the underlying FreqSwitch).
        final toggle = tester.widget<FreqSwitch>(
          find.descendant(
            of: find.ancestor(
              of: find.text('Crash reporting'),
              matching: find.byType(ListTile),
            ),
            matching: find.byType(FreqSwitch),
          ),
        );
        expect(toggle.onChanged, isNull);
      },
    );

    testWidgets('version row shows version from PackageInfo', (tester) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('1.2.3'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('1.2.3'), findsOneWidget);
    });

    testWidgets('Privacy policy link is visible in About section', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('Privacy policy'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Privacy policy'), findsOneWidget);
    });

    testWidgets(
      'tapping Privacy policy link navigates to FrequencyPrivacyPolicyScreen',
      (tester) async {
        await tester.pumpWidget(
          _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
        );
        await tester.pumpAndSettle();

        await tester.dragUntilVisible(
          find.text('Privacy policy'),
          find.byType(ListView),
          const Offset(0, -200),
        );
        await tester.tap(find.text('Privacy policy'));
        await tester.pumpAndSettle();

        expect(find.byType(FrequencyPrivacyPolicyScreen), findsOneWidget);
      },
    );

    testWidgets('Open source licenses link is visible', (tester) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('Open source licenses'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Open source licenses'), findsOneWidget);
    });

    testWidgets('tapping Open source licenses opens the LicensePage', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('Open source licenses'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Open source licenses'));
      await tester.pumpAndSettle();

      expect(find.byType(LicensePage), findsOneWidget);
    });

    testWidgets(
      'tapping Privacy & Security FAQ link navigates to the SecurityFaqScreen',
      (tester) async {
        await tester.pumpWidget(
          _wrap(FrequencySettingsScreen(settingsStore: _FakeSettingsStore())),
        );
        await tester.pumpAndSettle();

        await tester.dragUntilVisible(
          find.text('Privacy & Security FAQ'),
          find.byType(ListView),
          const Offset(0, -200),
        );
        await tester.tap(find.text('Privacy & Security FAQ'));
        await tester.pumpAndSettle();

        expect(find.byType(SecurityFaqScreen), findsOneWidget);
      },
    );
  });

  Future<void> openResetDialog(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('Reset all data'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Reset all data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset all data'));
    await tester.pumpAndSettle();
  }

  group('FrequencySettingsScreen reset-all-data flow', () {
    testWidgets('cancel in confirmation dialog leaves stores untouched', (
      tester,
    ) async {
      final identity = _FakeIdentityStore();
      final recents = _FakeRecentStore();
      final blocked = _FakeBlockedStore();
      final settings = _FakeSettingsStore(pttMode: true);
      final cubit = _FakeCubit();
      addTearDown(cubit.close);

      await tester.pumpWidget(
        _ProvidedSettings(
          identity: identity,
          recents: recents,
          blocked: blocked,
          settings: settings,
          cubit: cubit,
        ),
      );
      await tester.pumpAndSettle();

      await openResetDialog(tester);

      // Cancel button — no tap on the destructive option.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(identity.cleared, isFalse);
      expect(recents.cleared, isFalse);
      expect(blocked.cleared, isFalse);
      expect(settings.cleared, isFalse);
      expect(cubit.resetCalls, 0);
    });

    testWidgets('confirm in dialog clears every store and resets the cubit', (
      tester,
    ) async {
      final identity = _FakeIdentityStore();
      final recents = _FakeRecentStore();
      final blocked = _FakeBlockedStore();
      final settings = _FakeSettingsStore(pttMode: true);
      final cubit = _FakeCubit();
      addTearDown(cubit.close);

      await tester.pumpWidget(
        _ProvidedSettings(
          identity: identity,
          recents: recents,
          blocked: blocked,
          settings: settings,
          cubit: cubit,
        ),
      );
      await tester.pumpAndSettle();

      await openResetDialog(tester);

      // Find the confirm action — uses the destructive label "Reset".
      // Two "Reset all data" instances exist (link + dialog title), plus
      // a single "Reset" button — tap by exact text "Reset".
      await tester.tap(find.widgetWithText(TextButton, 'Reset'));
      await tester.pumpAndSettle();

      expect(identity.cleared, isTrue);
      expect(recents.cleared, isTrue);
      expect(blocked.cleared, isTrue);
      expect(settings.cleared, isTrue);
      expect(cubit.resetCalls, 1);
    });

    testWidgets('confirm tolerates store errors and still resets the cubit', (
      tester,
    ) async {
      final identity = _FakeIdentityStore(throwOnClear: true);
      final recents = _FakeRecentStore(throwOnClear: true);
      final blocked = _FakeBlockedStore(throwOnClear: true);
      final settings = _FakeSettingsStore(throwOnClear: true);
      final cubit = _FakeCubit();
      addTearDown(cubit.close);

      await tester.pumpWidget(
        _ProvidedSettings(
          identity: identity,
          recents: recents,
          blocked: blocked,
          settings: settings,
          cubit: cubit,
        ),
      );
      await tester.pumpAndSettle();

      await openResetDialog(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Reset'));
      await tester.pumpAndSettle();

      // Tolerated errors → every store's clear() was attempted, and
      // the cubit reset still ran exactly once.
      expect(identity.clearCalls, 1);
      expect(recents.clearCalls, 1);
      expect(blocked.clearCalls, 1);
      expect(settings.clearCalls, 1);
      expect(cubit.resetCalls, 1);
    });
  });
}

class _ProvidedSettings extends StatelessWidget {
  final IdentityStore identity;
  final RecentFrequenciesStore recents;
  final BlockedPeersStore blocked;
  final SettingsStore settings;
  final FrequencySessionCubit cubit;

  const _ProvidedSettings({
    required this.identity,
    required this.recents,
    required this.blocked,
    required this.settings,
    required this.cubit,
  });

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<IdentityStore>.value(value: identity),
        RepositoryProvider<RecentFrequenciesStore>.value(value: recents),
        RepositoryProvider<BlockedPeersStore>.value(value: blocked),
      ],
      child: BlocProvider<FrequencySessionCubit>.value(
        value: cubit,
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: FrequencySettingsScreen(settingsStore: settings),
        ),
      ),
    );
  }
}

class _FakeIdentityStore implements IdentityStore {
  bool cleared = false;
  int clearCalls = 0;
  final bool throwOnClear;
  _FakeIdentityStore({this.throwOnClear = false});

  @override
  Future<String?> getDisplayName() async => null;
  @override
  Future<void> setDisplayName(String value) async {}
  @override
  Future<String> getPeerId() async => 'fake-peer';
  @override
  Future<void> clear() async {
    clearCalls++;
    if (throwOnClear) throw StateError('boom');
    cleared = true;
  }
}

class _FakeRecentStore implements RecentFrequenciesStore {
  bool cleared = false;
  int clearCalls = 0;
  final bool throwOnClear;
  _FakeRecentStore({this.throwOnClear = false});

  @override
  Future<List<String>> getRecent() async => const [];
  @override
  Future<List<RecentFrequency>> getRecentDetailed() async => const [];
  @override
  Future<void> record(String freq, {String? sessionUuid}) async {}
  @override
  Future<void> setNickname(String freq, String? nickname) async {}
  @override
  Future<void> setPinned(String freq, bool pinned) async {}
  @override
  Future<void> delete(String freq) async {}
  @override
  Future<void> clear() async {
    clearCalls++;
    if (throwOnClear) throw StateError('boom');
    cleared = true;
  }
}

class _FakeBlockedStore implements BlockedPeersStore {
  bool cleared = false;
  int clearCalls = 0;
  final bool throwOnClear;
  _FakeBlockedStore({this.throwOnClear = false});

  @override
  Future<Set<String>> getAll() async => const {};
  @override
  Future<void> block(String peerId) async {}
  @override
  Future<void> unblock(String peerId) async {}
  @override
  Future<void> clear() async {
    clearCalls++;
    if (throwOnClear) throw StateError('boom');
    cleared = true;
  }
}

class _FakeCubit extends Cubit<FrequencySessionState>
    implements FrequencySessionCubit {
  int resetCalls = 0;
  _FakeCubit() : super(const SessionBooting());

  @override
  void resetToOnboarding() {
    resetCalls++;
    emit(const SessionOnboarding());
  }

  // Unused surface for these tests — let unimplemented members throw if hit.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
