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

The Sentry DSN must be provided via an environment variable:

```bash
export SENTRY_DSN='https://your-dsn@sentry.io/project-id'
```

For local development, add this to your `~/.bashrc` or `~/.zshrc`.

For CI/CD, add `SENTRY_DSN` as a secret environment variable.

### 3. Build the app

```bash
# Build the release AAB (Android App Bundle)
cd android
./gradlew bundleRelease
```

The Sentry Gradle plugin will automatically:
- Upload ProGuard/R8 mapping files for Java/Kotlin deobfuscation
- Upload native debug symbols for C++ crash reports
- Include source context in stack traces

## User Opt-In Flow

**Current state (this PR):**
- Crash reporting is disabled by default
- The opt-in preference is stored in `SettingsStore.crashReportingEnabled`
- To enable for testing, manually set the flag in SQLite or wait for the Settings screen (issue #121)

**Future (depends on #121):**
- Users will see a toggle in Settings: "Help improve the app — share anonymous crash reports"
- The toggle will be **off by default** (opt-out)
- When enabled, crash reports are queued on-device and sent only on Wi-Fi

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
