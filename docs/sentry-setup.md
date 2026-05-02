# Sentry Crash Reporting Setup

This document explains how to configure and use Sentry for crash reporting in the Walkie-Talkie app.

## Overview

Crash reporting is **disabled by default (opt-in)** to respect user privacy. The app:
- Does not send any crash reports unless the user explicitly opts in
- Only captures anonymous crash data (no PII like display names)
- Includes native crash support for C++ code (Oboe/Opus)
- Auto-uploads ProGuard/R8 mappings for deobfuscated stack traces

## Configuration

### 1. Obtain a Sentry DSN

1. Create a Sentry project at [sentry.io](https://sentry.io)
2. Copy the DSN (Data Source Name) from your project settings

### 2. Set the DSN for builds

The Sentry DSN is passed to the Flutter build via `--dart-define=SENTRY_DSN=...`
and baked into the binary at compile time.

**CI (release builds):** Add `SENTRY_DSN` as a [GitHub Actions
secret](https://docs.github.com/en/actions/security-guides/encrypted-secrets).
The release workflow (`release.yml`) reads it automatically and appends
`--dart-define=SENTRY_DSN=…` when the secret is present. When the secret is
absent the `--dart-define` flag is omitted entirely, so
`String.fromEnvironment('SENTRY_DSN')` resolves to its `defaultValue: ''` at
compile time and `kSentryConfigured` is false. The crash-reporting toggle in
Settings is rendered disabled in those builds (see
`lib/services/sentry_config.dart`).

**Local development:**

```bash
flutter run --dart-define=SENTRY_DSN='https://your-dsn@sentry.io/project-id'
```

Or export it so any `flutter run`/`flutter build` in the shell picks it up:

```bash
export SENTRY_DSN='https://your-dsn@sentry.io/project-id'
flutter run --dart-define=SENTRY_DSN="$SENTRY_DSN"
```

### 3. Build the app

```bash
# Build the release AAB (Android App Bundle)
flutter build appbundle --release \
  --dart-define=SENTRY_DSN='https://your-dsn@sentry.io/project-id'
```

The Sentry Gradle plugin will automatically:
- Upload ProGuard/R8 mapping files for Java/Kotlin deobfuscation
- Upload native debug symbols for C++ crash reports
- Include source context in stack traces

## User Opt-In Flow

- Crash reporting is **disabled by default** (opt-in).
- The preference is stored in `SettingsStore.crashReportingEnabled`.
- Users toggle it under **Settings → Privacy → Crash reporting**.
- The toggle is rendered **disabled** (greyed out, non-interactive) when the
  build was compiled without a DSN (`kSentryConfigured == false`). A status
  row directly below the toggle shows "Not configured" in that case, so users
  are never left with a control that silently does nothing.

## Privacy

The following data **is** included in crash reports:
- Stack traces (deobfuscated)
- Device model, OS version, app version
- `peerId` (anonymous UUID, documented as non-PII)

The following data **is NOT** included:
- Display names (redacted by `_sanitizeEvent`)
- IP addresses (can be disabled in Sentry project settings)
- Bluetooth MAC addresses
- Any content from the frequency room (audio, messages, etc.)

## Testing

To test crash reporting locally:

1. Set the `SENTRY_DSN` environment variable
2. Enable crash reporting via SQLite:

   ```dart
   final store = SqfliteSettingsStore();
   await store.setCrashReportingEnabled(true);
   ```

3. Trigger a crash:

   ```dart
   throw Exception('Test crash');
   ```

4. Check the Sentry dashboard for the crash report

## Native Crashes (C++)

Native crashes from Oboe or Opus code are automatically captured when:
- The Sentry NDK integration is enabled (configured in `build.gradle.kts`)
- Debug symbols are uploaded (handled automatically by the Sentry Gradle plugin)

To manually upload symbols for a specific build:

```bash
cd android/app
./gradlew uploadSentryNativeSymbolsForRelease
```

## Troubleshooting

### Crash reports not appearing in Sentry

1. **Check the DSN**: Ensure `SENTRY_DSN` is set and correct
2. **Check opt-in**: Verify `SettingsStore.crashReportingEnabled` returns `true`
3. **Check network**: Sentry reports are queued on-device; they may not upload until the device is on Wi-Fi
4. **Check ProGuard mappings**: If stack traces are obfuscated, ensure the Gradle plugin uploaded mappings

### Symbol upload fails in CI

Ensure the CI environment has the `SENTRY_DSN` secret configured and the Sentry Gradle plugin has network access.

## References

- [Sentry Flutter SDK docs](https://docs.sentry.io/platforms/flutter/)
- [Sentry Android Gradle plugin](https://docs.sentry.io/platforms/android/configuration/gradle/)
- Issue #120: Original feature request
- Issue #121: Settings screen for user-facing opt-in toggle
