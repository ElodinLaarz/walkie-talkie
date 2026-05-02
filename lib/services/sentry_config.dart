// Compile-time Sentry configuration — values are baked in via
// `--dart-define=SENTRY_DSN=...` at build time and never change at runtime.
// Release CI injects SENTRY_DSN from the repository secret; dev/debug builds
// that omit the flag get an empty string and `kSentryConfigured == false`.

const String _kSentryDsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');

/// True when a Sentry DSN was provided at build time.
///
/// When false the crash-reporting toggle in Settings is inert and rendered
/// disabled so users are not shown a control that silently does nothing.
const bool kSentryConfigured = _kSentryDsn != '';
