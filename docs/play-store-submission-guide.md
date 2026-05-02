---
layout: page
title: Play Store Submission Guide
permalink: /play-store-submission/
---

# Play Store Submission Guide

Step-by-step checklist for submitting Frequency to the Google Play Store.
Items marked ✅ are complete (all code and assets are committed); items marked
⏳ require action inside the Play Console.

---

## Status overview

| Item | Status | Reference |
|---|---|---|
| App name / short / long description | ✅ Done | `fastlane/metadata/android/en-US/` |
| Feature graphic (1024×500) | ✅ Done | `fastlane/metadata/android/en-US/images/featureGraphic.png` |
| Phone screenshots (3×) | ✅ Done | `fastlane/metadata/android/en-US/images/phoneScreenshots/` |
| 7-inch tablet screenshots (2×) | ✅ Done | `fastlane/metadata/android/en-US/images/sevenInchScreenshots/` |
| 10-inch tablet screenshots (2×) | ✅ Done | `fastlane/metadata/android/en-US/images/tenInchScreenshots/` |
| Data safety form answers | ✅ Done | `docs/play-store-data-safety.md` |
| Permissions justification text | ✅ Done | `docs/play-store-permissions-rationale.md` |
| Privacy policy URL | ✅ Done | `https://elodinlaarz.github.io/walkie-talkie/privacy-policy/` |
| Account & data deletion URL | ✅ Done | `https://elodinlaarz.github.io/walkie-talkie/privacy-policy/#data-retention-and-deletion` |
| Content rating (IARC) questionnaire | ⏳ Play Console | `docs/play-store-content-rating.md` |
| Target audience (13+) | ⏳ Play Console | See below |
| Signed AAB upload to internal track | ⏳ First time | See below |
| Closed testing track (12 testers × 14 days) | ⏳ Play Console | See below |
| Pre-launch report | ⏳ Auto after AAB upload | See below |
| Promo video | Optional | — |

---

## Step 1 — Upload listing text and images

Run once after credentials are set up:

```bash
# Set the PLAY_STORE_JSON_KEY_BASE64 secret in GitHub Settings → Secrets,
# then trigger the workflow manually:
#   GitHub → Actions → "Play Store — Upload Metadata & Images" → Run workflow

# Or run locally with a service-account key:
export PLAY_STORE_JSON_KEY_PATH=/path/to/key.json
bundle exec fastlane android upload_all
```

This uploads the title, descriptions, changelogs, feature graphic, and
all screenshots in one shot.

---

## Step 2 — Build and upload the signed AAB

```bash
# The release workflow runs automatically on v* tags.
# To trigger manually:
git tag v1.0.0
git push origin v1.0.0

# The "Play Store — Deploy to Internal Track" workflow picks up the built
# AAB and uploads it to the internal testing track.
```

Alternatively, trigger "Release Build" then "Play Store — Deploy to Internal
Track" from GitHub → Actions → Run workflow.

---

## Step 3 — Content rating (IARC)

**Play Console → App content → Content rating → Start questionnaire**

Select category: **Communication** (real-time audio between nearby users).

Use the reference answers in [`docs/play-store-content-rating.md`](play-store-content-rating.md)
to complete the questionnaire. Key answers:
- User-to-user communication: **Yes** (voice)
- User-generated content: **Yes** (real-time voice)
- Violent / sexual content: **No**
- Gambling: **No**
- Location sharing: **No**

After completing: click **Apply rating** to save.

---

## Step 4 — Target audience and content

**Play Console → App content → Target audience and content**

1. Select age group: **13 and over** (audio capture from minors is not intended)
2. Confirm the app is not designed for children under 13
3. Under "Ads" confirm the app contains no ads

---

## Step 5 — Data safety form

**Play Console → App content → Data safety**

Use the answers in [`docs/play-store-data-safety.md`](play-store-data-safety.md).
Key declarations:
- Audio/voice: collected, processed in real time, not stored, not shared
- Bluetooth device IDs: collected for connectivity only, not shared, deleted on uninstall
- Data is encrypted in transit (BLE link-layer AES)
- No third-party data sharing (except opt-in Sentry crash reports)

Data deletion URL: `https://elodinlaarz.github.io/walkie-talkie/privacy-policy/#data-retention-and-deletion`

---

## Step 6 — Permissions declaration

**Play Console → App content → Permissions** (shown during review if required)

Use the justifications in [`docs/play-store-permissions-rationale.md`](play-store-permissions-rationale.md).

---

## Step 7 — Closed testing track setup

Google requires **12 testers × 14 continuous days** on the internal or closed
testing track before a new personal developer account can publish to production.

**Play Console → Testing → Internal testing → Testers**

1. Create a testers list and add at least 12 Google accounts
2. Share the opt-in link with your testers
3. Each tester must accept the opt-in **and** install the app
4. The 14-day clock starts once testers are active

Practical notes:
- You can use the internal track for the mandatory period (internal is
  separate from closed/alpha/beta but counts toward the requirement in
  newer Google policies — verify in your Play Console dashboard).
- The clock **does not restart** if you push a new AAB; keep testers
  on the same track throughout.

---

## Step 8 — Pre-launch report

Uploading an AAB to any track automatically triggers Google's automated
pre-launch report (robot crawling on Pixel, Galaxy, Xiaomi emulators).
No manual action required.

**Play Console → Android vitals → Pre-launch report**

Review the report for:
- Crashes on launch
- ANRs during the robot test (expected: the robot cannot interact with
  BLE features, so audio-related screens may timeout — this is acceptable)
- Accessibility issues (screen reader labels, contrast)
- Security findings

---

## Step 9 — Promote to production

After the 14-day closed testing window closes:

1. **Play Console → Testing → Internal testing → Promote release**
2. Set rollout percentage (start at 10–20% for staged rollout)
3. Add release notes in the changelog field (already in `fastlane/metadata/android/en-US/changelogs/1.txt`)
4. Click **Review release** then **Start rollout to production**

---

## Service-account key setup (one-time)

1. **Play Console → Setup → API access → Link to Google Cloud project**
2. Create a service account in Google Cloud Console with "Service Account" role
3. Grant the service account access in Play Console (Release manager or higher)
4. Download the JSON key
5. Base64-encode and store in GitHub: `Settings → Secrets → PLAY_STORE_JSON_KEY_BASE64`

```bash
base64 -w0 /path/to/key.json | pbcopy  # macOS — paste into GitHub secret
base64 -w0 /path/to/key.json | xclip   # Linux
```

---

## Regenerating screenshots

If the app UI changes, regenerate screenshots with:

```bash
# Phone screenshots (1080×1920)
python3 scripts/gen_screenshots.py

# Tablet screenshots (1200×1920 and 1600×2560)
python3 scripts/gen_tablet_screenshots.py

# Or capture real device screenshots via adb:
adb exec-out screencap -p > fastlane/metadata/android/en-US/images/phoneScreenshots/1.png
```

Then re-upload:

```bash
bundle exec fastlane android upload_images
```
