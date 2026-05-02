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

```bash
python3 scripts/gen_tablet_screenshots.py
# Output: fastlane/metadata/android/en-US/images/sevenInchScreenshots/{1,2}.png
#         fastlane/metadata/android/en-US/images/tenInchScreenshots/{1,2}.png
```

## measure_app_size.sh

Downloads bundletool, signs the release AAB with the debug keystore,
and measures per-device download size via `bundletool get-size total`.
Used by the Flutter CI workflow to enforce the < 30 MB download budget.

```bash
# Normally run by CI; to run locally:
AAB_PATH=build/app/outputs/bundle/release/app-release.aab \
KEYSTORE_PATH=~/.android/debug.keystore \
KEYSTORE_PASSWORD=android \
KEY_ALIAS=androiddebugkey \
KEY_PASSWORD=android \
bash scripts/measure_app_size.sh
```

## presubmit.sh

Runs the full local presubmit gate (formatting, analysis, tests, native
C++ tests). Mirrors what CI runs on every push.

```bash
bash scripts/presubmit.sh
```
