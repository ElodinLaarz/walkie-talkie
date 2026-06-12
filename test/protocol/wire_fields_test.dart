import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/wire_fields.dart';

void main() {
  // ── reqString ─────────────────────────────────────────────────────────────

  group('reqString', () {
    test('returns the string when present', () {
      expect(reqString({'k': 'hello'}, 'k'), 'hello');
      expect(reqString({'k': ''}, 'k'), '');
    });

    test('throws on missing key', () {
      expect(() => reqString({}, 'k'), throwsFormatException);
    });

    test('throws on int', () {
      expect(() => reqString({'k': 1}, 'k'), throwsFormatException);
    });

    test('throws on bool', () {
      expect(() => reqString({'k': true}, 'k'), throwsFormatException);
    });

    test('throws on null', () {
      expect(() => reqString({'k': null}, 'k'), throwsFormatException);
    });
  });

  // ── reqBoundedString ───────────────────────────────────────────────────────

  group('reqBoundedString', () {
    test('returns the string when within the bound', () {
      expect(reqBoundedString({'k': 'hi'}, 'k', maxLen: 8), 'hi');
    });

    test('accepts a string exactly at maxLen', () {
      final s = 'a' * 8;
      expect(reqBoundedString({'k': s}, 'k', maxLen: 8), s);
    });

    test('accepts the empty string', () {
      expect(reqBoundedString({'k': ''}, 'k', maxLen: 8), '');
    });

    test('throws when longer than maxLen', () {
      expect(
        () => reqBoundedString({'k': 'a' * 9}, 'k', maxLen: 8),
        throwsFormatException,
      );
    });

    test('throws on missing key (delegates to reqString)', () {
      expect(() => reqBoundedString({}, 'k', maxLen: 8), throwsFormatException);
    });

    test('throws on mistyped (non-string) value', () {
      expect(
        () => reqBoundedString({'k': 1}, 'k', maxLen: 8),
        throwsFormatException,
      );
    });
  });

  // ── optBoundedString ─────────────────────────────────────────────────────

  group('optBoundedString', () {
    test('returns null when the key is absent', () {
      expect(optBoundedString({}, 'k', maxLen: 8), isNull);
    });

    test('returns null when the value is null', () {
      expect(optBoundedString({'k': null}, 'k', maxLen: 8), isNull);
    });

    test('returns the value at or under the cap', () {
      expect(optBoundedString({'k': 'hi'}, 'k', maxLen: 8), 'hi');
      final s = 'a' * 8;
      expect(optBoundedString({'k': s}, 'k', maxLen: 8), s);
    });

    test('throws when the value exceeds the cap', () {
      expect(
        () => optBoundedString({'k': 'a' * 9}, 'k', maxLen: 8),
        throwsFormatException,
      );
    });

    test('throws on mistyped (non-string) value', () {
      expect(
        () => optBoundedString({'k': 1}, 'k', maxLen: 8),
        throwsFormatException,
      );
    });
  });

  // ── reqInt ────────────────────────────────────────────────────────────────

  group('reqInt', () {
    test('returns the int when present', () {
      expect(reqInt({'k': 0}, 'k'), 0);
      expect(reqInt({'k': -1}, 'k'), -1);
      expect(reqInt({'k': 0x7fffffffffffffff}, 'k'), 0x7fffffffffffffff);
    });

    test('throws on missing key', () {
      expect(() => reqInt({}, 'k'), throwsFormatException);
    });

    test('throws on JSON double (1.0) — double is not int on the wire', () {
      expect(() => reqInt({'k': 1.0}, 'k'), throwsFormatException);
    });

    test('throws on string', () {
      expect(() => reqInt({'k': '1'}, 'k'), throwsFormatException);
    });

    test('throws on bool', () {
      expect(() => reqInt({'k': false}, 'k'), throwsFormatException);
    });

    test('throws on null', () {
      expect(() => reqInt({'k': null}, 'k'), throwsFormatException);
    });
  });

  // ── reqSeq ────────────────────────────────────────────────────────────────

  group('reqSeq', () {
    test('accepts lower bound 1', () {
      expect(reqSeq({'k': 1}, 'k'), 1);
    });

    test('accepts upper bound 0xFFFFFFFF', () {
      expect(reqSeq({'k': 0xFFFFFFFF}, 'k'), 0xFFFFFFFF);
    });

    test('accepts mid-range value', () {
      expect(reqSeq({'k': 0x80000000}, 'k'), 0x80000000);
    });

    test('throws on 0 — below range', () {
      expect(() => reqSeq({'k': 0}, 'k'), throwsFormatException);
    });

    test('throws on -1 — negative', () {
      expect(() => reqSeq({'k': -1}, 'k'), throwsFormatException);
    });

    test('throws on 0x100000000 — above range', () {
      expect(() => reqSeq({'k': 0x100000000}, 'k'), throwsFormatException);
    });

    test('throws on missing key', () {
      expect(() => reqSeq({}, 'k'), throwsFormatException);
    });

    test('throws on double', () {
      expect(() => reqSeq({'k': 1.0}, 'k'), throwsFormatException);
    });
  });

  // ── reqAtMs ───────────────────────────────────────────────────────────────

  group('reqAtMs', () {
    test('accepts 0', () {
      expect(reqAtMs({'k': 0}, 'k'), 0);
    });

    test('accepts positive timestamp', () {
      expect(reqAtMs({'k': 1_700_000_000_000}, 'k'), 1_700_000_000_000);
    });

    test('throws on -1', () {
      expect(() => reqAtMs({'k': -1}, 'k'), throwsFormatException);
    });

    test('throws on missing key', () {
      expect(() => reqAtMs({}, 'k'), throwsFormatException);
    });

    test('throws on double', () {
      expect(() => reqAtMs({'k': 0.0}, 'k'), throwsFormatException);
    });

    test('throws on string', () {
      expect(() => reqAtMs({'k': '0'}, 'k'), throwsFormatException);
    });
  });

  // ── reqBool ───────────────────────────────────────────────────────────────

  group('reqBool', () {
    test('returns true', () {
      expect(reqBool({'k': true}, 'k'), isTrue);
    });

    test('returns false', () {
      expect(reqBool({'k': false}, 'k'), isFalse);
    });

    test('throws on missing key', () {
      expect(() => reqBool({}, 'k'), throwsFormatException);
    });

    test('throws on int', () {
      expect(() => reqBool({'k': 1}, 'k'), throwsFormatException);
    });

    test('throws on string', () {
      expect(() => reqBool({'k': 'true'}, 'k'), throwsFormatException);
    });

    test('throws on null', () {
      expect(() => reqBool({'k': null}, 'k'), throwsFormatException);
    });
  });

  // ── optInt ────────────────────────────────────────────────────────────────

  group('optInt', () {
    test('returns null when key absent', () {
      expect(optInt({}, 'k'), isNull);
    });

    test('returns null when value is null', () {
      expect(optInt({'k': null}, 'k'), isNull);
    });

    test('returns int when present', () {
      expect(optInt({'k': 42}, 'k'), 42);
    });

    test('throws FormatException on double when present', () {
      expect(() => optInt({'k': 1.0}, 'k'), throwsFormatException);
    });

    test('throws FormatException on string when present', () {
      expect(() => optInt({'k': '1'}, 'k'), throwsFormatException);
    });
  });

  // ── optString ─────────────────────────────────────────────────────────────

  group('optString', () {
    test('returns null when key absent', () {
      expect(optString({}, 'k'), isNull);
    });

    test('returns null when value is null', () {
      expect(optString({'k': null}, 'k'), isNull);
    });

    test('returns string when present', () {
      expect(optString({'k': 'hello'}, 'k'), 'hello');
    });

    test('throws FormatException on int when present', () {
      expect(() => optString({'k': 1}, 'k'), throwsFormatException);
    });
  });

  // ── optBool ───────────────────────────────────────────────────────────────

  group('optBool', () {
    test('returns orElse when key absent', () {
      expect(optBool({}, 'k', orElse: true), isTrue);
      expect(optBool({}, 'k', orElse: false), isFalse);
    });

    test('returns orElse when value is null', () {
      expect(optBool({'k': null}, 'k', orElse: true), isTrue);
    });

    test('returns bool when present', () {
      expect(optBool({'k': true}, 'k', orElse: false), isTrue);
      expect(optBool({'k': false}, 'k', orElse: true), isFalse);
    });

    test('throws FormatException on int when present', () {
      expect(() => optBool({'k': 1}, 'k', orElse: false), throwsFormatException);
    });

    test('throws FormatException on string when present', () {
      expect(
        () => optBool({'k': 'true'}, 'k', orElse: false),
        throwsFormatException,
      );
    });
  });
}
