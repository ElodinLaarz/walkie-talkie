import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/bloc/frequency_session_cubit.dart';
import 'package:walkie_talkie/bloc/frequency_session_state.dart';
import 'package:walkie_talkie/services/identity_store.dart';

class _FakeStore implements IdentityStore {
  String? _name;
  bool throwOnGet = false;
  bool throwOnSet = false;
  int setCalls = 0;

  _FakeStore({String? initial}) : _name = initial;

  @override
  Future<String?> getDisplayName() async {
    if (throwOnGet) throw StateError('boom');
    return _name;
  }

  @override
  Future<void> setDisplayName(String value) async {
    setCalls++;
    if (throwOnSet) throw StateError('boom');
    final trimmed = value.trim();
    _name = trimmed.isEmpty ? null : trimmed;
  }
}

void main() {
  group('FrequencySessionCubit', () {
    test('starts in the booting stage with no name', () {
      final cubit = FrequencySessionCubit(identityStore: _FakeStore());
      expect(cubit.state.stage, SessionStage.booting);
      expect(cubit.state.myName, '');
      expect(cubit.state.roomFreq, isNull);
      expect(cubit.state.roomIsHost, isFalse);
    });

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap with a persisted name routes to discovery',
      build: () => FrequencySessionCubit(
        identityStore: _FakeStore(initial: 'Maya'),
      ),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [
        const FrequencySessionState(
          stage: SessionStage.discovery,
          myName: 'Maya',
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap without a persisted name routes to onboarding',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [
        const FrequencySessionState(
          stage: SessionStage.onboarding,
          myName: '',
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'bootstrap falls through to onboarding when the store throws',
      build: () => FrequencySessionCubit(
        identityStore: _FakeStore()..throwOnGet = true,
      ),
      act: (cubit) => cubit.bootstrap(),
      expect: () => [
        const FrequencySessionState(
          stage: SessionStage.onboarding,
          myName: '',
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'completeOnboarding persists and advances to discovery',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const FrequencySessionState(
        stage: SessionStage.onboarding,
        myName: '',
      ),
      act: (cubit) => cubit.completeOnboarding('Devon'),
      expect: () => [
        const FrequencySessionState(
          stage: SessionStage.discovery,
          myName: 'Devon',
        ),
      ],
      verify: (cubit) async {
        // setDisplayName actually got called.
        expect((cubit.identityStore as _FakeStore).setCalls, 1);
        expect(await cubit.identityStore.getDisplayName(), 'Devon');
      },
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'completeOnboarding still advances when persistence throws',
      build: () => FrequencySessionCubit(
        identityStore: _FakeStore()..throwOnSet = true,
      ),
      seed: () => const FrequencySessionState(
        stage: SessionStage.onboarding,
        myName: '',
      ),
      act: (cubit) => cubit.completeOnboarding('Sam'),
      expect: () => [
        const FrequencySessionState(
          stage: SessionStage.discovery,
          myName: 'Sam',
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'rename updates the name without changing the stage',
      build: () => FrequencySessionCubit(
        identityStore: _FakeStore(initial: 'Maya'),
      ),
      seed: () => const FrequencySessionState(
        stage: SessionStage.discovery,
        myName: 'Maya',
      ),
      act: (cubit) => cubit.rename('Maya R.'),
      expect: () => [
        const FrequencySessionState(
          stage: SessionStage.discovery,
          myName: 'Maya R.',
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'joinRoom enters the room stage with the freq and host flag',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const FrequencySessionState(
        stage: SessionStage.discovery,
        myName: 'Maya',
      ),
      act: (cubit) => cubit.joinRoom(freq: '104.3', isHost: true),
      expect: () => [
        const FrequencySessionState(
          stage: SessionStage.room,
          myName: 'Maya',
          roomFreq: '104.3',
          roomIsHost: true,
        ),
      ],
    );

    blocTest<FrequencySessionCubit, FrequencySessionState>(
      'leaveRoom drops the room fields and goes back to discovery',
      build: () => FrequencySessionCubit(identityStore: _FakeStore()),
      seed: () => const FrequencySessionState(
        stage: SessionStage.room,
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: true,
      ),
      act: (cubit) => cubit.leaveRoom(),
      expect: () => [
        const FrequencySessionState(
          stage: SessionStage.discovery,
          myName: 'Maya',
          roomFreq: null,
          roomIsHost: false,
        ),
      ],
    );
  });

  group('FrequencySessionState', () {
    test('copyWith preserves untouched fields', () {
      const a = FrequencySessionState(
        stage: SessionStage.room,
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: true,
      );
      final b = a.copyWith(myName: 'Maya R.');
      expect(b.stage, SessionStage.room);
      expect(b.myName, 'Maya R.');
      expect(b.roomFreq, '104.3');
      expect(b.roomIsHost, isTrue);
    });

    test('copyWith(clearRoom: true) drops both room fields', () {
      const a = FrequencySessionState(
        stage: SessionStage.room,
        myName: 'Maya',
        roomFreq: '104.3',
        roomIsHost: true,
      );
      final b = a.copyWith(stage: SessionStage.discovery, clearRoom: true);
      expect(b.stage, SessionStage.discovery);
      expect(b.roomFreq, isNull);
      expect(b.roomIsHost, isFalse);
    });

    test('equatable equality treats identical fields as equal', () {
      const a = FrequencySessionState(
        stage: SessionStage.discovery,
        myName: 'Maya',
      );
      const b = FrequencySessionState(
        stage: SessionStage.discovery,
        myName: 'Maya',
      );
      expect(a, equals(b));
    });
  });
}
