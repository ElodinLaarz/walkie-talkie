import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/frequency_session.dart';

void main() {
  group('FrequencySession', () {
    test('mhzDisplay is in [88.0, 107.9] at 0.1 precision', () {
      // Sample a spread of UUID tails covering low/high/mid of the 12-bit range.
      const tails = ['000', 'fff', '7ff', '800', 'abc', '123'];
      for (final t in tails) {
        final s = FrequencySession(
          sessionUuid: '00000000-0000-0000-0000-000000000$t',
          hostPeerId: 'host',
        );
        final value = double.parse(s.mhzDisplay);
        expect(value, greaterThanOrEqualTo(88.0));
        expect(value, lessThanOrEqualTo(107.9));
        // 0.1 precision => one digit after the decimal.
        expect(s.mhzDisplay, matches(RegExp(r'^\d{2,3}\.\d$')));
      }
    });

    test('mhzDisplay is deterministic for the same UUID', () {
      const uuid = '550e8400-e29b-41d4-a716-446655440abc';
      final a = FrequencySession(sessionUuid: uuid, hostPeerId: 'h1');
      final b = FrequencySession(sessionUuid: uuid, hostPeerId: 'h2');
      expect(a.mhzDisplay, b.mhzDisplay);
    });

    test('mhzDisplay differs across UUIDs that vary in the low 12 bits', () {
      final a = FrequencySession(
        sessionUuid: '00000000-0000-0000-0000-000000000abc',
        hostPeerId: 'h',
      );
      final b = FrequencySession(
        sessionUuid: '00000000-0000-0000-0000-000000000def',
        hostPeerId: 'h',
      );
      expect(a.mhzDisplay, isNot(b.mhzDisplay));
    });

    test('sessionCode is 4 chars from the Crockford alphabet', () {
      final s = FrequencySession(
        sessionUuid: '550e8400-e29b-41d4-a716-446655440000',
        hostPeerId: 'h',
      );
      expect(s.sessionCode.length, 4);
      expect(
        s.sessionCode,
        matches(RegExp(r'^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{4}$')),
      );
    });

    test('sessionCode is deterministic and changes with low 20 bits', () {
      final a = FrequencySession(
        sessionUuid: '00000000-0000-0000-0000-0000000aaaaa',
        hostPeerId: 'h',
      );
      final b = FrequencySession(
        sessionUuid: '00000000-0000-0000-0000-0000000bbbbb',
        hostPeerId: 'h',
      );
      expect(a.sessionCode, isNot(b.sessionCode));

      // Same UUID → same code.
      final a2 = FrequencySession(
        sessionUuid: a.sessionUuid,
        hostPeerId: 'different-host',
      );
      expect(a.sessionCode, a2.sessionCode);
    });

    test('JSON round-trip', () {
      const original = FrequencySession(
        sessionUuid: '550e8400-e29b-41d4-a716-446655440000',
        hostPeerId: 'peer-host-1',
      );
      final round = FrequencySession.fromJson(original.toJson());
      expect(round, original);
    });

    test('throws on a UUID too short to map', () {
      expect(
        () => FrequencySession(sessionUuid: 'ab', hostPeerId: 'h').mhzDisplay,
        throwsFormatException,
      );
    });
  });
}
