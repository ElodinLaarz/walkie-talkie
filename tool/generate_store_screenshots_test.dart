// ignore_for_file: invalid_use_of_protected_member
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:walkie_talkie/bloc/discovery_cubit.dart';
import 'package:walkie_talkie/bloc/discovery_state.dart';
import 'package:walkie_talkie/bloc/frequency_session_cubit.dart';
import 'package:walkie_talkie/bloc/frequency_session_state.dart';
import 'package:walkie_talkie/data/frequency_models.dart';
import 'package:walkie_talkie/l10n/generated/app_localizations.dart';
import 'package:walkie_talkie/protocol/discovery.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/protocol/peer.dart';
import 'package:walkie_talkie/screens/frequency_discovery_screen.dart';
import 'package:walkie_talkie/screens/frequency_explainer_screen.dart';
import 'package:walkie_talkie/screens/frequency_room_screen.dart';
import 'package:walkie_talkie/screens/frequency_settings_screen.dart';
import 'package:walkie_talkie/services/audio_service.dart';
import 'package:walkie_talkie/services/blocked_peers_store.dart';
import 'package:walkie_talkie/services/bluetooth_discovery_service.dart';
import 'package:walkie_talkie/services/identity_store.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';
import 'package:walkie_talkie/services/settings_store.dart';
import 'package:walkie_talkie/theme/app_theme.dart';
import 'package:walkie_talkie/widgets/frequency_toast_host.dart';

const _captureKey = ValueKey('store-screenshot-capture');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('generate Play Store screenshots from real Flutter widgets', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Frequency',
      packageName: 'com.elodin.walkie_talkie',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
      installerStore: null,
    );

    final target = Platform.environment['SCREENSHOT_TARGET'];
    if (target == null || target.isEmpty) {
      throw StateError(
        'Run `dart tool/generate_store_screenshots.dart`; direct test '
        'invocations must set SCREENSHOT_TARGET.',
      );
    }
    await _captureTarget(tester, target);
  });
}

Future<void> _captureTarget(WidgetTester tester, String target) async {
  switch (target) {
    case 'phone-1':
      return _capture(
        tester,
        physicalSize: const Size(1080, 1920),
        devicePixelRatio: 2.5,
        outputPath:
            'fastlane/metadata/android/en-US/images/phoneScreenshots/1.png',
        child: _discoveryScreen(),
      );
    case 'phone-2':
      return _capture(
        tester,
        physicalSize: const Size(1080, 1920),
        devicePixelRatio: 2.5,
        outputPath:
            'fastlane/metadata/android/en-US/images/phoneScreenshots/2.png',
        child: _roomScreen(),
      );
    case 'phone-3':
      return _capture(
        tester,
        physicalSize: const Size(1080, 1920),
        devicePixelRatio: 2.5,
        outputPath:
            'fastlane/metadata/android/en-US/images/phoneScreenshots/3.png',
        child: _settingsScreen(),
      );
    case 'phone-4':
      return _capture(
        tester,
        physicalSize: const Size(1080, 1920),
        devicePixelRatio: 2.5,
        outputPath:
            'fastlane/metadata/android/en-US/images/phoneScreenshots/4.png',
        child: _explainerScreen(),
        afterPump: () async {
          await tester.tap(find.text('Next'));
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(find.text('Next'));
          await tester.pump(const Duration(milliseconds: 350));
        },
      );
    case 'seven-1':
      return _capture(
        tester,
        physicalSize: const Size(1200, 1920),
        devicePixelRatio: 2,
        outputPath:
            'fastlane/metadata/android/en-US/images/sevenInchScreenshots/1.png',
        child: _discoveryScreen(),
      );
    case 'seven-2':
      return _capture(
        tester,
        physicalSize: const Size(1200, 1920),
        devicePixelRatio: 2,
        outputPath:
            'fastlane/metadata/android/en-US/images/sevenInchScreenshots/2.png',
        child: _roomScreen(),
      );
    case 'ten-1':
      return _capture(
        tester,
        physicalSize: const Size(1600, 2560),
        devicePixelRatio: 2,
        outputPath:
            'fastlane/metadata/android/en-US/images/tenInchScreenshots/1.png',
        child: _discoveryScreen(),
      );
    case 'ten-2':
      return _capture(
        tester,
        physicalSize: const Size(1600, 2560),
        devicePixelRatio: 2,
        outputPath:
            'fastlane/metadata/android/en-US/images/tenInchScreenshots/2.png',
        child: _roomScreen(),
      );
    default:
      throw ArgumentError.value(target, 'SCREENSHOT_TARGET');
  }
}

Future<void> _capture(
  WidgetTester tester, {
  required Size physicalSize,
  required double devicePixelRatio,
  required String outputPath,
  required Widget child,
  Future<void> Function()? afterPump,
}) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.platformDispatcher.implicitView!
    ..physicalSize = physicalSize
    ..devicePixelRatio = devicePixelRatio;

  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureKey,
      child: TickerMode(enabled: false, child: _appShell(child)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await afterPump?.call();

  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  final image = await boundary.toImage(pixelRatio: devicePixelRatio);
  final width = image.width;
  final height = image.height;
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = _encodePngRgba(
    rgba!.buffer.asUint8List(),
    width: width,
    height: height,
  );
  image.dispose();
  final file = File(outputPath);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
  // ignore: avoid_print
  print('Generated $outputPath (${width}x$height)');

  binding.platformDispatcher.implicitView!
    ..resetPhysicalSize()
    ..resetDevicePixelRatio();
}

Uint8List _encodePngRgba(
  Uint8List rgba, {
  required int width,
  required int height,
}) {
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.fromList(const [137, 80, 78, 71, 13, 10, 26, 10]))
    ..add(
      _pngChunk(
        'IHDR',
        (BytesBuilder()
              ..add(_uint32(width))
              ..add(_uint32(height))
              ..add(Uint8List.fromList(const [8, 6, 0, 0, 0])))
            .toBytes(),
      ),
    );

  final rowBytes = width * 4;
  final scanlines = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    scanlines.addByte(0);
    scanlines.add(
      Uint8List.sublistView(rgba, y * rowBytes, (y + 1) * rowBytes),
    );
  }

  out
    ..add(_pngChunk('IDAT', ZLibEncoder().convert(scanlines.toBytes())))
    ..add(_pngChunk('IEND', Uint8List(0)));
  return out.toBytes();
}

Uint8List _pngChunk(String type, List<int> data) {
  final typeBytes = Uint8List.fromList(type.codeUnits);
  final body = BytesBuilder(copy: false)
    ..add(typeBytes)
    ..add(data);
  final bodyBytes = body.toBytes();
  final out = BytesBuilder(copy: false)
    ..add(_uint32(data.length))
    ..add(bodyBytes)
    ..add(_uint32(_crc32(bodyBytes)));
  return out.toBytes();
}

Uint8List _uint32(int value) {
  final bytes = ByteData(4)..setUint32(0, value, Endian.big);
  return bytes.buffer.asUint8List();
}

int _crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      final mask = -(crc & 1);
      crc = (crc >> 1) ^ (0xEDB88320 & mask);
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Widget _appShell(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

Widget _discoveryScreen() {
  final cubit = _ScreenshotDiscoveryCubit([
    DiscoveredSession(
      protocolVersion: 1,
      isHost: true,
      sessionUuidLow8: '1234567890abcdef',
      flags: 0,
      hostName: 'Alex Chen',
      rssi: -48,
      macAddress: 'AA:BB:CC:DD:EE:01',
    ),
    DiscoveredSession(
      protocolVersion: 1,
      isHost: true,
      sessionUuidLow8: 'fedcba0987654321',
      flags: 0,
      hostName: 'Taylor Room',
      rssi: -61,
      macAddress: 'AA:BB:CC:DD:EE:02',
    ),
  ]);
  return BlocProvider.value(
    value: cubit,
    child: FrequencyDiscoveryScreen(
      myName: 'Devon',
      onPick: (_) {},
      onRename: (_) {},
      recentHostedFrequencies: const [
        RecentFrequency(
          freq: '104.3',
          nickname: 'Workshop',
          pinned: true,
          sessionUuid: '12345678-1234-1234-1234-abcdef012345',
        ),
      ],
    ),
  );
}

Widget _roomScreen() {
  final cubit = FrequencySessionCubit(
    identityStore: _MemoryIdentityStore(),
    recentFrequenciesStore: _MemoryRecentFrequenciesStore(),
  );
  cubit.emit(
    const SessionRoom(
      myName: 'Devon',
      roomFreq: '104.3',
      roomIsHost: true,
      hostPeerId: 'p-host',
      roster: [
        ProtocolPeer(peerId: 'p-host', displayName: 'Devon'),
        ProtocolPeer(peerId: 'p-maya', displayName: 'Maya', talking: true),
        ProtocolPeer(peerId: 'p-ari', displayName: 'Ari', muted: true),
      ],
      mediaState: MediaState(
        source: 'Device audio',
        trackIdx: 0,
        playing: true,
        positionMs: 45000,
      ),
    ),
  );
  return FrequencyToastHost(
    child: MultiRepositoryProvider(
      providers: [
        RepositoryProvider<AudioService>.value(value: _SilentAudioService()),
        RepositoryProvider<BlockedPeersStore>.value(
          value: _MemoryBlockedPeersStore(),
        ),
      ],
      child: BlocProvider.value(
        value: cubit,
        child: FrequencyRoomScreen(
          freq: '104.3',
          mediaKind: MediaKind.music,
          pttMode: true,
          isHost: true,
          myName: 'Devon',
          onLeave: () {},
          manageAudioLifecycle: false,
          enableProgressTicker: false,
        ),
      ),
    ),
  );
}

Widget _settingsScreen() {
  return FrequencySettingsScreen(settingsStore: _MemorySettingsStore());
}

Widget _explainerScreen() {
  return FrequencyExplainerScreen(onDone: () {});
}

class _ScreenshotDiscoveryCubit extends DiscoveryCubit {
  _ScreenshotDiscoveryCubit(this.sessions) : super(_NoopDiscoveryService());

  final List<DiscoveredSession> sessions;

  @override
  Future<void> startDiscovery() async {
    if (isClosed) return;
    emit(DiscoveryScanning(sessions: sessions));
  }

  @override
  Future<void> stopDiscovery() async {
    if (isClosed) return;
    emit(DiscoveryStopped(sessions: sessions));
  }
}

class _NoopDiscoveryService extends DiscoveryService {
  @override
  Stream<List<DiscoveredSession>> get results => const Stream.empty();

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> startScan() async {}
}

class _SilentAudioService extends AudioService {
  @override
  Stream<Map<String, dynamic>> get audioEvents => const Stream.empty();

  @override
  Future<bool> startService({String? freq}) async => true;

  @override
  Future<bool> stopService() async => true;

  @override
  Future<bool> startVoice() async => true;

  @override
  Future<bool> stopVoice() async => true;

  @override
  Future<bool> setMuted(bool muted) async => true;

  @override
  Future<bool> setAudioOutput(String output) async => true;
}

class _MemoryIdentityStore implements IdentityStore {
  @override
  Future<String?> getDisplayName() async => 'Devon';

  @override
  Future<void> setDisplayName(String value) async {}

  @override
  Future<String> getPeerId() async => 'p-host';

  @override
  Future<void> clear() async {}
}

class _MemoryRecentFrequenciesStore implements RecentFrequenciesStore {
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
  Future<void> clear() async {}
}

class _MemoryBlockedPeersStore implements BlockedPeersStore {
  @override
  Future<Set<String>> getAll() async => const {};

  @override
  Future<void> block(String peerId) async {}

  @override
  Future<void> unblock(String peerId) async {}

  @override
  Future<void> clear() async {}
}

class _MemorySettingsStore implements SettingsStore {
  @override
  Future<bool> getCrashReportingEnabled() async => false;

  @override
  Future<void> setCrashReportingEnabled(bool enabled) async {}

  @override
  Future<bool> getPttModeEnabled() async => true;

  @override
  Future<void> setPttModeEnabled(bool enabled) async {}

  @override
  Future<bool> getKeepScreenOn() async => true;

  @override
  Future<void> setKeepScreenOn(bool enabled) async {}

  @override
  Future<void> clear() async {}
}
