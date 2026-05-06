import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/services/sentry_config.dart';

void main() {
  test('kSentryConfigured tracks the SENTRY_DSN dart-define', () {
    // Derive the expected value from the same env var rather than hard-
    // coding `false` — the production config flips on whenever the test
    // runner is launched with `--dart-define=SENTRY_DSN=...`, and a
    // hard-coded expectation would fail in those configurations.
    const dsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');
    expect(kSentryConfigured, dsn.isNotEmpty);
    expect(kSentryConfigured, isA<bool>());
  });
}
