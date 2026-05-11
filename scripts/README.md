# scripts/

Helper scripts for development, release, and Play Store operations.

## validate_store_metadata.sh

Validates Play Store character limits across all locale metadata files.
Run automatically in CI (before Flutter SDK setup) and in the
play-store-metadata upload workflow.

```bash
bash scripts/validate_store_metadata.sh
# or with a custom metadata root:
bash scripts/validate_store_metadata.sh /path/to/fastlane/metadata/android
```

Limits enforced:
- `title.txt` ≤ 30 chars
- `short_description.txt` ≤ 80 chars
- `full_description.txt` ≤ 4000 chars
- `changelogs/*.txt` ≤ 500 chars each

## Store screenshots

```bash
dart tool/generate_store_screenshots.dart
```

Generates committed Play Store screenshots from real Flutter widgets:

- `fastlane/metadata/android/en-US/images/phoneScreenshots/{1,2,3,4}.png`
- `fastlane/metadata/android/en-US/images/sevenInchScreenshots/{1,2}.png`
- `fastlane/metadata/android/en-US/images/tenInchScreenshots/{1,2}.png`

The old Pillow mockup generators were removed so store art cannot drift from
the app's actual widgets, theme, localization, and layout.
Set `FLUTTER_BIN=/path/to/flutter` if `flutter` is not on `PATH`.

## measure_app_size.sh

Downloads bundletool, generates device-specific APK splits from a signed AAB
(signing the split APKs with the provided keystore for bundletool's alignment
step), and reports per-device download size via `bundletool get-size total`.
Used by the **release workflow** (`release.yml`) after a production build.

Thresholds (configurable via env vars in `release.yml`):
- **Soft-warn target**: 30 MiB — logs a warning if exceeded, build continues
- **Hard-fail ceiling**: 50 MiB — fails the build if exceeded

Note: the Flutter CI workflow (`flutter.yml`) uses a separate inline raw-AAB
size check (not per-device download size) and does not call this script.

```bash
# Normally run by the release workflow; to run locally against a
# release AAB (already signed with the production keystore):
AAB_PATH=build/app/outputs/bundle/release/app-release.aab \
KEYSTORE_PATH=/path/to/release.jks \
KEYSTORE_PASSWORD=<password> \
KEY_ALIAS=<alias> \
KEY_PASSWORD=<key-password> \
bash scripts/measure_app_size.sh
```

## presubmit.sh

Runs the full local presubmit gate. A **superset** of what CI
(`.github/workflows/flutter.yml`) runs — designed to catch every
regression CI would catch, plus a couple of local-only checks so
the contributor doesn't burn a CI round-trip on a fixable local
issue:

1. Play Store metadata character-limit validation *(also in CI)*
2. `dart format --set-exit-if-changed` *(local-only — CI does not
   enforce formatting; this is a contributor convenience)*
3. `flutter analyze` *(also in CI)*
4. `flutter test` *(without `--coverage`; CI runs the coverage variant
   and uploads to Codecov, which is not informative locally)*
5. Native C++ tests via `scripts/run_native_cpp_tests.sh` *(also in CI)*
6. Kotlin unit tests: `./gradlew :app:testDebugUnitTest --no-daemon`
   *(also in CI; auto-skipped when `android/gradlew` is not executable —
   once-per-clone fix is `chmod +x android/gradlew`)*

```bash
bash scripts/presubmit.sh
```

**Intentionally NOT mirrored from CI**: the debug-AAB size regression
alarm. It requires a full JDK setup and a `flutter build appbundle`,
adding minutes for low local-regression value (the AAB rarely changes
outside of dependency churn).

## install-git-hooks.sh

Installs an opt-in `pre-push` git hook that runs `presubmit.sh` before
every `git push`. A failing presubmit aborts the push so a CI
round-trip is not spent on a regression a local run would have caught.

```bash
bash scripts/install-git-hooks.sh
```

Re-runnable: a hook this script already installed (detected via a
marker comment) is replaced in place. A pre-existing hook *not*
installed by this script (husky / lefthook / hand-rolled) is **not**
clobbered — it gets backed up to `pre-push.bak.<UTC-timestamp>` next
to itself, with a stdout message, so you can merge in the presubmit
step manually if you want both.

Bypass for emergencies:

```bash
git push --no-verify
```

The hook directory is resolved via `git rev-parse
--path-format=absolute --git-path hooks` so the path is absolute
across linked worktrees and custom `core.hooksPath` configurations.
Requires git ≥ 2.31 (January 2021).
