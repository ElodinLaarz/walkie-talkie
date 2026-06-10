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

    test('fromJson throws FormatException for missing sessionUuid', () {
      expect(
        () => FrequencySession.fromJson({'hostPeerId': 'h'}),
        throwsFormatException,
      );
    });

    test('fromJson throws FormatException for non-string sessionUuid', () {
      expect(
        () => FrequencySession.fromJson({'sessionUuid': 42, 'hostPeerId': 'h'}),
        throwsFormatException,
      );
    });

    test('fromJson throws FormatException for missing hostPeerId', () {
      expect(
        () => FrequencySession.fromJson(
          {'sessionUuid': '550e8400-e29b-41d4-a716-446655440000'},
        ),
        throwsFormatException,
      );
    });

    test('fromJson throws FormatException for non-string hostPeerId', () {
      expect(
        () => FrequencySession.fromJson({
          'sessionUuid': '550e8400-e29b-41d4-a716-446655440000',
          'hostPeerId': null,
        }),
        throwsFormatException,
      );
    });

    test('cosmetic getters fall back instead of throwing on a short UUID', () {
      // A too-short UUID has no low-12/low-20 tail; the getters must not throw
      // (they are reachable from UI with wire-derived sessionUuids). Falls back
      // to the low-bits=0 bucket: 88.0 MHz / "0000".
      final s = FrequencySession(sessionUuid: 'ab', hostPeerId: 'h');
      expect(s.mhzDisplay, '88.0');
      expect(s.sessionCode, '0000');
    });

    test('cosmetic getters fall back instead of throwing on a non-hex UUID', () {
      // A non-hex but syntactically valid sessionUuid can arrive via
      // HostTransfer (decoded with a bare reqString, no hex validation). The
      // cosmetic getters must degrade gracefully, not throw FormatException
      // deep in a UI getter — keeping the protocol's drop-message-keep-link
      // contract intact.
      final s = FrequencySession(
        sessionUuid: 'zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz',
        hostPeerId: 'h',
      );
      final mhz = double.parse(s.mhzDisplay);
      expect(mhz, greaterThanOrEqualTo(88.0));
      expect(mhz, lessThanOrEqualTo(107.9));
      expect(s.sessionCode, matches(RegExp(r'^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{4}$')));
    });

    test('hashCode + toString cover terminal members', () {
      const a = FrequencySession(
        sessionUuid: '550e8400-e29b-41d4-a716-446655440000',
        hostPeerId: 'h1',
      );
      const b = FrequencySession(
        sessionUuid: '550e8400-e29b-41d4-a716-446655440000',
        hostPeerId: 'h1',
      );
      expect(a.hashCode, b.hashCode);
      expect(a.toString(), contains('FrequencySession('));
      expect(a.toString(), contains('h1'));
    });
  });
}
