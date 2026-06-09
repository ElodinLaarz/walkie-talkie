import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/protocol/peer.dart';

void main() {
  const base = ProtocolPeer(
    peerId: 'peer-1',
    displayName: 'Alice',
    btDevice: 'AA:BB:CC:DD:EE:FF',
    muted: false,
    talking: false,
  );

  group('ProtocolPeer.copyWith', () {
    test('no-arg copy returns equal peer', () {
      expect(base.copyWith(), equals(base));
    });

    test('updates displayName', () {
      final updated = base.copyWith(displayName: 'Bob');
      expect(updated.displayName, 'Bob');
      expect(updated.peerId, base.peerId);
    });

    test('updates muted and talking independently', () {
      final muted = base.copyWith(muted: true);
      expect(muted.muted, isTrue);
      expect(muted.talking, isFalse);

      final talking = base.copyWith(talking: true);
      expect(talking.talking, isTrue);
      expect(talking.muted, isFalse);
    });

    test('omitting btDevice preserves existing value', () {
      final copy = base.copyWith(muted: true);
      expect(copy.btDevice, 'AA:BB:CC:DD:EE:FF');
    });

    test('passing btDevice: null clears the field', () {
      final cleared = base.copyWith(btDevice: null);
      expect(cleared.btDevice, isNull);
    });

    test('passing new btDevice value replaces it', () {
      final updated = base.copyWith(btDevice: '11:22:33:44:55:66');
      expect(updated.btDevice, '11:22:33:44:55:66');
    });

    test('copyWith on peer with null btDevice: omitting preserves null', () {
      const noBt = ProtocolPeer(peerId: 'p', displayName: 'X');
      expect(noBt.copyWith(muted: true).btDevice, isNull);
    });

    test('copyWith on peer with null btDevice: can set a value', () {
      const noBt = ProtocolPeer(peerId: 'p', displayName: 'X');
      expect(
        noBt.copyWith(btDevice: 'FF:EE:DD:CC:BB:AA').btDevice,
        'FF:EE:DD:CC:BB:AA',
      );
    });

    test('passing non-String btDevice throws ArgumentError', () {
      expect(() => base.copyWith(btDevice: 42), throwsArgumentError);
      expect(() => base.copyWith(btDevice: true), throwsArgumentError);
      expect(() => base.copyWith(btDevice: <String>[]), throwsArgumentError);
    });
  });

  group('ProtocolPeer equality', () {
    test('equal peers with same fields', () {
      const a = ProtocolPeer(peerId: 'x', displayName: 'Y');
      const b = ProtocolPeer(peerId: 'x', displayName: 'Y');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('peers with different peerId are not equal', () {
      const a = ProtocolPeer(peerId: 'x', displayName: 'Y');
      const b = ProtocolPeer(peerId: 'z', displayName: 'Y');
      expect(a, isNot(equals(b)));
    });
  });

  group('ProtocolPeer JSON round-trip', () {
    test('toJson / fromJson preserves all fields', () {
      final json = base.toJson();
      final restored = ProtocolPeer.fromJson(json);
      expect(restored, equals(base));
    });

    test('btDevice absent in JSON parses as null', () {
      const noBt = ProtocolPeer(peerId: 'p', displayName: 'X');
      final json = noBt.toJson();
      expect(json.containsKey('btDevice'), isFalse);
      final restored = ProtocolPeer.fromJson(json);
      expect(restored.btDevice, isNull);
    });

    // Regression: fromJson used bare `as` casts that throw TypeError (not
    // FormatException) on mistyped wire fields. A ProtocolPeer is decoded
    // nested inside a roster on the control plane, where only FormatException
    // is caught — a TypeError would crash the receiver.
    test('mistyped fields throw FormatException, not TypeError', () {
      expect(
        () => ProtocolPeer.fromJson({'peerId': 1, 'displayName': 'A'}),
        throwsFormatException,
      );
      expect(
        () => ProtocolPeer.fromJson({'peerId': 'p', 'displayName': 2}),
        throwsFormatException,
      );
      expect(
        () => ProtocolPeer.fromJson({
          'peerId': 'p',
          'displayName': 'A',
          'btDevice': 5,
        }),
        throwsFormatException,
      );
      expect(
        () => ProtocolPeer.fromJson({
          'peerId': 'p',
          'displayName': 'A',
          'muted': 'no',
        }),
        throwsFormatException,
      );
      expect(
        () => ProtocolPeer.fromJson({
          'peerId': 'p',
          'displayName': 'A',
          'talking': 1,
        }),
        throwsFormatException,
      );
    });
  });
}
