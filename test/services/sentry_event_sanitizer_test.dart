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

  group('sanitizeSentryEvent — MAC address redaction', () {
    test('redacts MAC addresses from breadcrumb messages', () {
      final event = SentryEvent(
        breadcrumbs: [
          Breadcrumb(message: 'Error getting MTU for AA:BB:CC:DD:EE:FF: timeout'),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.breadcrumbs!.single.message, contains('[MAC_REDACTED]'));
      expect(
        result.breadcrumbs!.single.message,
        isNot(contains('AA:BB:CC:DD:EE:FF')),
      );
    });

    test('redacts hyphen-separated MAC addresses', () {
      final event = SentryEvent(
        breadcrumbs: [
          Breadcrumb(message: 'connect to aa-bb-cc-dd-ee-ff failed'),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.breadcrumbs!.single.message, contains('[MAC_REDACTED]'));
      expect(
        result.breadcrumbs!.single.message,
        isNot(contains('aa-bb-cc-dd-ee-ff')),
      );
    });

    test('redacts MAC addresses inside nested breadcrumb data', () {
      final event = SentryEvent(
        breadcrumbs: [
          Breadcrumb(data: {'endpoint': '11:22:33:44:55:66', 'rssi': -70}),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      final data = result.breadcrumbs!.single.data!;
      expect(data['endpoint'], '[MAC_REDACTED]');
      expect(data['rssi'], -70);
    });

    test('does not over-match short hex sequences', () {
      final event = SentryEvent(
        breadcrumbs: [Breadcrumb(message: 'opcode 0xAB:0xCD failed')],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(
        result.breadcrumbs!.single.message,
        equals('opcode 0xAB:0xCD failed'),
      );
    });
  });

  group('sanitizeSentryEvent — top-level message', () {
    test('redacts peerId in formatted message', () {
      final event = SentryEvent(
        message: SentryMessage('host bootstrap failed peerId=abc-123'),
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.message!.formatted, contains('[REDACTED]'));
      expect(result.message!.formatted, isNot(contains('abc-123')));
    });

    test('redacts displayName in template', () {
      final event = SentryEvent(
        message: SentryMessage(
          'join attempt for displayName: Alice',
          template: 'join attempt for displayName: %s',
        ),
      );
      final result = sanitizeSentryEvent(event)!;
      // Template was the literal "%s" placeholder so it stays intact, but the
      // "displayName:" key still triggers the message redactor.
      expect(result.message!.template, contains('[REDACTED]'));
    });

    test('redacts MAC in message params', () {
      final event = SentryEvent(
        message: SentryMessage(
          'failed for AA:BB:CC:DD:EE:FF',
          params: ['AA:BB:CC:DD:EE:FF'],
        ),
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.message!.params!.single, '[MAC_REDACTED]');
      expect(result.message!.formatted, contains('[MAC_REDACTED]'));
    });
  });

  group('sanitizeSentryEvent — exceptions', () {
    test('redacts peerId from exception value', () {
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: 'StateError',
            value: 'JoinAccepted send failed peerId=abc-123',
          ),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.exceptions!.single.value, contains('[REDACTED]'));
      expect(result.exceptions!.single.value, isNot(contains('abc-123')));
    });

    test('redacts MAC from exception value', () {
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: 'PlatformException',
            value: 'Error getting MTU for AA:BB:CC:DD:EE:FF',
          ),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.exceptions!.single.value, contains('[MAC_REDACTED]'));
      expect(
        result.exceptions!.single.value,
        isNot(contains('AA:BB:CC:DD:EE:FF')),
      );
    });

    test('redacts displayName in stack frame vars', () {
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: 'Exception',
            value: 'oops',
            stackTrace: SentryStackTrace(
              frames: [
                SentryStackFrame(
                  function: 'doThing',
                  fileName: 'foo.dart',
                  lineNo: 42,
                  vars: {'displayName': 'Alice', 'count': 3},
                ),
              ],
            ),
          ),
        ],
      );
      final result = sanitizeSentryEvent(event)!;
      final frame = result.exceptions!.single.stackTrace!.frames.single;
      expect(frame.vars['displayName'], '[REDACTED]');
      expect(frame.vars['count'], 3);
      expect(frame.fileName, 'foo.dart');
      expect(frame.lineNo, 42);
    });
  });

  group('sanitizeSentryEvent — user', () {
    test('drops every PII field from event.user', () {
      final event = SentryEvent(
        user: SentryUser(
          id: 'abc-123',
          username: 'alice',
          email: 'alice@example.com',
          ipAddress: '203.0.113.7',
          name: 'Alice',
        ),
      );
      final result = sanitizeSentryEvent(event)!;
      final user = result.user!;
      expect(user.id, isNull);
      expect(user.username, isNull);
      expect(user.email, isNull);
      expect(user.ipAddress, isNull);
      expect(user.name, isNull);
    });

    test('redacts PII keys inside user.data', () {
      // SentryUser asserts that at least one identifier is set at construction
      // time, so we satisfy the assertion with a placeholder id; the scrubber
      // is expected to clear it as part of the redact pass.
      final event = SentryEvent(
        user: SentryUser(
          id: 'placeholder',
          data: {'displayName': 'Alice', 'peerId': 'abc-123', 'role': 'host'},
        ),
      );
      final result = sanitizeSentryEvent(event)!;
      final user = result.user!;
      expect(user.id, isNull);
      final data = user.data!;
      expect(data['displayName'], '[REDACTED]');
      expect(data['peerId'], '[REDACTED]');
      expect(data['role'], 'host');
    });
  });

  group('sanitizeSentryEvent — fingerprint and transaction', () {
    test('redacts MAC in fingerprint entries', () {
      final event = SentryEvent(
        fingerprint: ['ble-error', 'AA:BB:CC:DD:EE:FF'],
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.fingerprint, ['ble-error', '[MAC_REDACTED]']);
    });

    test('redacts peerId in transaction name', () {
      final event = SentryEvent(transaction: '/room/peerId=abc-123/voice');
      final result = sanitizeSentryEvent(event)!;
      expect(result.transaction, contains('[REDACTED]'));
      expect(result.transaction, isNot(contains('abc-123')));
    });
  });

  group('sanitizeSentryEvent — request', () {
    test('redacts MAC in request URL', () {
      final event = SentryEvent(
        request: SentryRequest(url: 'https://api.example/peer/AA:BB:CC:DD:EE:FF'),
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.request!.url, contains('[MAC_REDACTED]'));
      expect(result.request!.url, isNot(contains('AA:BB:CC:DD:EE:FF')));
    });

    test('redacts peerId in request query string', () {
      final event = SentryEvent(
        request: SentryRequest(queryString: 'peerId=abc-123&v=1'),
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.request!.queryString, contains('[REDACTED]'));
      expect(result.request!.queryString, isNot(contains('abc-123')));
    });

    test('redacts PII-keyed headers', () {
      final event = SentryEvent(
        request: SentryRequest(
          headers: {'X-PeerId': 'abc-123', 'X-Version': '1.0'},
        ),
      );
      final result = sanitizeSentryEvent(event)!;
      expect(result.request!.headers['X-PeerId'], '[REDACTED]');
      expect(result.request!.headers['X-Version'], '1.0');
    });
  });
}
