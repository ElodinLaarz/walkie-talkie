import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/uuid.dart';

void main() {
  group('generateUuidV4', () {
    test('returns canonical 8-4-4-4-12 hyphenated format', () {
      final uuid = generateUuidV4();
      final parts = uuid.split('-');
      expect(parts.length, 5);
      expect(parts[0].length, 8);
      expect(parts[1].length, 4);
      expect(parts[2].length, 4);
      expect(parts[3].length, 4);
      expect(parts[4].length, 12);
    });

    test('version nibble is 4', () {
      final uuid = generateUuidV4();
      // Third group, first character must be '4'.
      expect(uuid.split('-')[2][0], '4');
    });

    test('variant bits are 10xx (high nibble 8–b)', () {
      final uuid = generateUuidV4();
      // Fourth group, first hex digit must be 8, 9, a, or b.
      final variantChar = uuid.split('-')[3][0];
      expect(
        '89ab'.contains(variantChar),
        isTrue,
        reason: 'Expected variant nibble in {8,9,a,b}, got $variantChar',
      );
    });

    test('output is lowercase hex', () {
      final uuid = generateUuidV4();
      final noHyphens = uuid.replaceAll('-', '');
      expect(noHyphens, matches(RegExp(r'^[0-9a-f]+$')));
    });

    test('successive calls return distinct values', () {
      final a = generateUuidV4();
      final b = generateUuidV4();
      expect(a, isNot(equals(b)));
    });
  });

  group('isCanonicalUuid', () {
    test('accepts a well-formed lowercase UUID', () {
      expect(
        isCanonicalUuid('550e8400-e29b-41d4-a716-446655440000'),
        isTrue,
      );
    });

    test('accepts output of generateUuidV4', () {
      expect(isCanonicalUuid(generateUuidV4()), isTrue);
    });

    test('rejects uppercase UUID', () {
      expect(
        isCanonicalUuid('550E8400-E29B-41D4-A716-446655440000'),
        isFalse,
      );
    });

    test('rejects UUID missing a hyphen group', () {
      expect(isCanonicalUuid('550e8400e29b41d4a716446655440000'), isFalse);
    });

    test('rejects UUID with wrong segment length', () {
      expect(
        isCanonicalUuid('550e840-e29b-41d4-a716-446655440000'),
        isFalse,
      );
    });

    test('rejects empty string', () {
      expect(isCanonicalUuid(''), isFalse);
    });

    test('rejects UUID with leading whitespace', () {
      expect(
        isCanonicalUuid(' 550e8400-e29b-41d4-a716-446655440000'),
        isFalse,
      );
    });

    test('rejects non-hex characters', () {
      expect(
        isCanonicalUuid('550e8400-e29b-41d4-a716-44665544000g'),
        isFalse,
      );
    });
  });
}
