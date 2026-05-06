import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/services/sentry_config.dart';

void main() {
  test('kSentryConfigured is a compile-time bool', () {
    expect(kSentryConfigured, isA<bool>());
    // In tests there's no SENTRY_DSN dart-define, so it must be false.
    expect(kSentryConfigured, isFalse);
  });
}
