import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:walkie_talkie/services/sentry_event_sanitizer.dart';

void main() {
  group('sanitizeSentryEvent — displayName redaction', () {
    test('removes displayName key from contexts', () {
      final event = SentryEvent(
        contexts: Contexts()..['displayName'] = {'value': 'Alice'},
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.contexts['displayName'], isNull);
    });

    test('redacts colon-separated displayName in breadcrumb message', () {
      final event = SentryEvent(
        breadcrumbs: [
          Breadcrumb(message: 'peer joined displayName: Alice, freq: 42'),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.breadcrumbs!.single.message, contains('[REDACTED]'));
      expect(result.breadcrumbs!.single.message, isNot(contains('Alice')));
    });

    test('redacts equals-separated displayName in breadcrumb message', () {
      final event = SentryEvent(
        breadcrumbs: [Breadcrumb(message: 'join displayName=Alice, code=0')],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.breadcrumbs!.single.message, contains('[REDACTED]'));
      expect(result.breadcrumbs!.single.message, isNot(contains('Alice')));
    });

    test('redacts JSON-style displayName in breadcrumb message', () {
      final event = SentryEvent(
        breadcrumbs: [Breadcrumb(message: '"displayName":"Alice"')],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.breadcrumbs!.single.message, contains('[REDACTED]'));
      expect(result.breadcrumbs!.single.message, isNot(contains('Alice')));
    });

    test('redacts displayName key in breadcrumb data', () {
      final event = SentryEvent(
        breadcrumbs: [
          Breadcrumb(data: {'displayName': 'Alice', 'freq': 42}),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.breadcrumbs!.single.data!['displayName'], '[REDACTED]');
      expect(result.breadcrumbs!.single.data!['freq'], 42);
    });
  });

  group('sanitizeSentryEvent — peerId redaction', () {
    test('removes peerId key from contexts', () {
      final event = SentryEvent(
        contexts: Contexts()..['peerId'] = {'value': 'abc-123'},
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.contexts['peerId'], isNull);
    });

    test('removes peerId from event tags', () {
      final event = SentryEvent(tags: {'peerId': 'abc-123', 'version': '1.0'});
      final result = sanitizeSentryEvent(event)!;
      expect(result.tags!.containsKey('peerId'), isFalse);
      expect(result.tags!['version'], '1.0');
    });

    test('redacts peerId key in breadcrumb data', () {
      final event = SentryEvent(
        breadcrumbs: [
          Breadcrumb(data: {'peerId': 'abc-123', 'event': 'join'}),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.breadcrumbs!.single.data!['peerId'], '[REDACTED]');
      expect(result.breadcrumbs!.single.data!['event'], 'join');
    });

    test('redacts colon-separated peerId in breadcrumb message', () {
      final event = SentryEvent(
        breadcrumbs: [
          Breadcrumb(message: 'transport error peerId: abc-123, code: 5'),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.breadcrumbs!.single.message, contains('[REDACTED]'));
      expect(result.breadcrumbs!.single.message, isNot(contains('abc-123')));
    });

    test('redacts equals-separated peerId in breadcrumb message', () {
      final event = SentryEvent(
        breadcrumbs: [
          Breadcrumb(message: 'disconnect peerId=abc-123, reason=timeout'),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.breadcrumbs!.single.message, contains('[REDACTED]'));
      expect(result.breadcrumbs!.single.message, isNot(contains('abc-123')));
    });

    test('redacts JSON-style peerId in breadcrumb message', () {
      final event = SentryEvent(
        breadcrumbs: [Breadcrumb(message: '"peerId":"abc-123"')],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.breadcrumbs!.single.message, contains('[REDACTED]'));
      expect(result.breadcrumbs!.single.message, isNot(contains('abc-123')));
    });

    test('redacts nested peerId inside a context value map', () {
      final event = SentryEvent(
        contexts: Contexts()..['room'] = {'peerId': 'abc-123', 'freq': 42},
      );
      final result = sanitizeSentryEvent(event)!;
      final roomCtx = result.contexts['room'] as Map<String, dynamic>;
      expect(roomCtx['peerId'], '[REDACTED]');
      expect(roomCtx['freq'], 42);
    });

    test('redacts nested peerId inside breadcrumb data value map', () {
      final event = SentryEvent(
        breadcrumbs: [
          Breadcrumb(
            data: {
              'details': {'peerId': 'abc-123', 'rssi': -70},
            },
          ),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      final details =
          result.breadcrumbs!.single.data!['details'] as Map<String, dynamic>;
      expect(details['peerId'], '[REDACTED]');
      expect(details['rssi'], -70);
    });

    test('leaves unrelated tags and data intact', () {
      final event = SentryEvent(
        tags: {'version': '1.2.3', 'platform': 'android'},
        breadcrumbs: [
          Breadcrumb(data: {'frequency': 42, 'rssi': -70}),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.tags, {'version': '1.2.3', 'platform': 'android'});
      expect(result.breadcrumbs!.single.data, {'frequency': 42, 'rssi': -70});
    });

    test('handles null tags and breadcrumbs without error', () {
      final event = SentryEvent();
      expect(() => sanitizeSentryEvent(event), returnsNormally);
    });

    test(
      'simultaneous displayName and peerId in breadcrumb data are both redacted',
      () {
        final event = SentryEvent(
          breadcrumbs: [
            Breadcrumb(
              data: {'displayName': 'Alice', 'peerId': 'abc-123', 'freq': 7},
            ),
          ],
        );
        final result = sanitizeSentryEvent(event)!;
        final data = result.breadcrumbs!.single.data!;
        expect(data['displayName'], '[REDACTED]');
        expect(data['peerId'], '[REDACTED]');
        expect(data['freq'], 7);
      },
    );
  });
}
