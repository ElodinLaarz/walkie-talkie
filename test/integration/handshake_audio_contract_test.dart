import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/bloc/frequency_session_cubit.dart';
import 'package:walkie_talkie/bloc/frequency_session_state.dart';
import 'package:walkie_talkie/main.dart';
import 'package:walkie_talkie/protocol/discovery.dart';
import 'package:walkie_talkie/protocol/framing.dart';
import 'package:walkie_talkie/protocol/messages.dart';
import 'package:walkie_talkie/screens/frequency_discovery_screen.dart';
import 'package:walkie_talkie/services/audio_service.dart';
import 'package:walkie_talkie/services/blocked_peers_store.dart';
import 'package:walkie_talkie/services/bluetooth_discovery_service.dart';
import 'package:walkie_talkie/services/identity_store.dart';
import 'package:walkie_talkie/services/permission_watcher.dart';
import 'package:walkie_talkie/services/recent_frequencies_store.dart';
import 'package:walkie_talkie/services/settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'app wiring delivers native controlBytes JoinRequest into the host cubit',
    (tester) async {
      final audio = _RecordingAudioService();
      final discovery = _FakeDiscoveryService();

      await tester.pumpWidget(
        TickerMode(
          enabled: false,
          child: WalkieTalkieApp(
            identityStore: _MemoryIdentityStore(),
            recentFrequenciesStore: _MemoryRecentFrequenciesStore(),
            blockedPeersStore: _MemoryBlockedPeersStore(),
            discoveryService: discovery,
            audioService: audio,
            permissionWatcher: _GrantedPermissionWatcher(),
            settingsStore: _MemorySettingsStore(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final context = tester.element(find.byType(FrequencyDiscoveryScreen));
      final cubit = context.read<FrequencySessionCubit>();
      await cubit.joinRoom(isHost: true);

      expect(audio.calls, contains('startAdvertising'));
      expect(audio.calls, contains('startGattServer'));
      expect(audio.calls, contains('startVoiceServer'));

      audio.outbox.clear();
      const join = JoinRequest(
        peerId: 'p-guest',
        seq: 1,
        atMs: 1000,
        displayName: 'Maya',
        btDevice: 'AA:BB:CC:DD:EE:FF',
      );
      for (final fragment in encodeFragments(join.encode())) {
        audio.inbound.add((endpointId: 'AA:BB:CC:DD:EE:FF', bytes: fragment));
      }
      await tester.pump();
      await tester.pump();

      final room = cubit.state as SessionRoom;
      expect(room.roster.map((p) => p.peerId), contains('p-guest'));

      final sent = _decodeOutbox(audio.outbox);
      final accepted = sent.whereType<JoinAccepted>().single;
      expect(accepted.recipientPeerId, 'p-guest');
      expect(accepted.voicePsm, 0x81);
      expect(sent.whereType<RosterUpdate>(), isNotEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await audio.dispose();
      await discovery.dispose();
    },
  );
}

List<FrequencyMessage> _decodeOutbox(List<Uint8List> outbox) {
  final reassembler = FragmentReassembler();
  final messages = <FrequencyMessage>[];
  for (final fragment in outbox) {
    final json = reassembler.feed(fragment);
    if (json != null) messages.add(FrequencyMessage.decode(json));
  }
  return messages;
}

class _RecordingAudioService extends AudioService {
  final inbound =
      StreamController<({String endpointId, Uint8List bytes})>.broadcast();
  final outbox = <Uint8List>[];
  final calls = <String>[];

  @override
  Stream<Map<String, dynamic>> get audioEvents => const Stream.empty();

  @override
  Stream<bool> get localTalking => const Stream.empty();

  @override
  Stream<({String endpointId, Uint8List bytes})> get controlBytes =>
      inbound.stream;

  @override
  Future<bool> startService({String? freq}) async {
    calls.add('startService');
    return true;
  }

  @override
  Future<bool> stopService() async {
    calls.add('stopService');
    return true;
  }

  @override
  Future<bool> startVoice() async {
    calls.add('startVoice');
    return true;
  }

  @override
  Future<bool> stopVoice() async {
    calls.add('stopVoice');
    return true;
  }

  @override
  Future<bool> setMuted(bool muted) async {
    calls.add('setMuted:$muted');
    return true;
  }

  @override
  Future<bool> setAudioOutput(String output) async {
    calls.add('setAudioOutput:$output');
    return true;
  }

  @override
  Future<bool> startAdvertising({
    required String sessionUuid,
    required String displayName,
  }) async {
    calls.add('startAdvertising');
    return true;
  }

  @override
  Future<bool> stopAdvertising() async {
    calls.add('stopAdvertising');
    return true;
  }

  @override
  Future<bool> startGattServer() async {
    calls.add('startGattServer');
    return true;
  }

  @override
  Future<bool> stopGattServer() async {
    calls.add('stopGattServer');
    return true;
  }

  @override
  Future<int?> startVoiceServer() async {
    calls.add('startVoiceServer');
    return 0x81;
  }

  @override
  Future<bool> stopVoiceTransport() async {
    calls.add('stopVoiceTransport');
    return true;
  }

  @override
  Future<void> writeControlBytes(Uint8List bytes) async {
    calls.add('writeControlBytes');
    outbox.add(Uint8List.fromList(bytes));
  }

  @override
  Future<String?> getInitialLink() async => null;

  Future<void> dispose() => inbound.close();
}

class _FakeDiscoveryService extends DiscoveryService {
  final _results = StreamController<List<DiscoveredSession>>.broadcast();

  @override
  Stream<List<DiscoveredSession>> get results => _results.stream;

  @override
  Future<void> startScan() async => _results.add(const []);

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> dispose() async => _results.close();
}

class _MemoryIdentityStore implements IdentityStore {
  String? displayName = 'Devon';
  String peerId = 'p-host';

  @override
  Future<String?> getDisplayName() async => displayName;

  @override
  Future<void> setDisplayName(String value) async {
    displayName = value.trim().isEmpty ? null : value.trim();
  }

  @override
  Future<String> getPeerId() async => peerId;

  @override
  Future<void> clear() async {
    displayName = null;
    peerId = 'p-host-reset';
  }
}

class _MemoryRecentFrequenciesStore implements RecentFrequenciesStore {
  final _entries = <RecentFrequency>[];

  @override
  Future<List<String>> getRecent() async =>
      _entries.map((e) => e.freq).toList(growable: false);

  @override
  Future<List<RecentFrequency>> getRecentDetailed() async =>
      List.unmodifiable(_entries);

  @override
  Future<void> record(String freq, {String? sessionUuid}) async {
    _entries.removeWhere((e) => e.freq == freq);
    _entries.insert(0, RecentFrequency(freq: freq, sessionUuid: sessionUuid));
  }

  @override
  Future<void> setNickname(String freq, String? nickname) async {}

  @override
  Future<void> setPinned(String freq, bool pinned) async {}

  @override
  Future<void> delete(String freq) async {
    _entries.removeWhere((e) => e.freq == freq);
  }

  @override
  Future<void> clear() async => _entries.clear();
}

class _MemoryBlockedPeersStore implements BlockedPeersStore {
  final _blocked = <String>{};

  @override
  Future<Set<String>> getAll() async => Set.unmodifiable(_blocked);

  @override
  Future<void> block(String peerId) async => _blocked.add(peerId);

  @override
  Future<void> unblock(String peerId) async => _blocked.remove(peerId);

  @override
  Future<void> clear() async => _blocked.clear();
}

class _MemorySettingsStore implements SettingsStore {
  bool pttMode = false;
  bool keepScreenOn = false;
  bool crashReporting = false;

  @override
  Future<bool> getCrashReportingEnabled() async => crashReporting;

  @override
  Future<void> setCrashReportingEnabled(bool enabled) async {
    crashReporting = enabled;
  }

  @override
  Future<bool> getPttModeEnabled() async => pttMode;

  @override
  Future<void> setPttModeEnabled(bool enabled) async {
    pttMode = enabled;
  }

  @override
  Future<bool> getKeepScreenOn() async => keepScreenOn;

  @override
  Future<void> setKeepScreenOn(bool enabled) async {
    keepScreenOn = enabled;
  }

  @override
  Future<void> clear() async {
    pttMode = false;
    keepScreenOn = false;
    crashReporting = false;
  }
}

class _GrantedPermissionWatcher implements PermissionWatcher {
  @override
  Stream<List<AppPermission>> watch() => Stream.value(const []);

  @override
  Future<List<AppPermission>> checkNow() async => const [];

  @override
  Future<void> dispose() async {}
}
