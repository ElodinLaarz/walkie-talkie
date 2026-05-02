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

## gen_screenshots.py

Generates three 1080×1920 phone screenshots for the Play Store listing
using Python + Pillow (no device required).

**Platform note:** the script hard-codes Windows font paths
(`C:/Windows/Fonts/segoeuib.ttf`). On macOS/Linux, install Segoe UI or
edit the `FONT_BD` / `FONT_REG` constants at the top of the script to
point at available system fonts before running.

```bash
python3 scripts/gen_screenshots.py
# Output: fastlane/metadata/android/en-US/images/phoneScreenshots/{1,2,3}.png
```

Screenshots produced:
1. Discovery screen — nearby frequency rows, radar animation, Start card
2. Frequency Room — central dial, peer chips, PTT and Mute buttons
3. Settings screen — VOICE / DISPLAY / PRIVACY / ABOUT sections

## gen_tablet_screenshots.py

Generates four tablet screenshots for the Play Store listing:
two at 1200×1920 (7-inch) and two at 1600×2560 (10-inch).
All dimensions scale proportionally from the 1080 px phone baseline.

**Platform note:** same Windows font dependency as `gen_screenshots.py`
above — update `FONT_BD` / `FONT_REG` if running on macOS/Linux.

```bash
python3 scripts/gen_tablet_screenshots.py
# Output: fastlane/metadata/android/en-US/images/sevenInchScreenshots/{1,2}.png
#         fastlane/metadata/android/en-US/images/tenInchScreenshots/{1,2}.png
```

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

Runs the full local presubmit gate (formatting, analysis, tests, native
C++ tests). Mirrors what CI runs on every push.

```bash
bash scripts/presubmit.sh
```
