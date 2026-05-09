# Play Store Images

Place the following assets in this directory, then upload them via Play Console
or `fastlane supply`.

## Hi-res app icon

File name: `icon.png`
Required size: **512 × 512 px**
Format: PNG or JPEG, no alpha channel (Play Console enforces this)

**Status: committed** — `icon.png` is present (resized from `assets/icon/icon.png`).
Upload with:

```
bundle exec fastlane android upload_images
```

## Feature graphic

File name: `featureGraphic.png`
Required size: **1024 × 500 px**
Format: PNG or JPEG (no alpha)

**Status: committed** — `featureGraphic.png` is present. Upload with:

```
bundle exec fastlane android upload_images
```

Design used:
- Blue gradient background (#3498DB → #1A6DAE)
- App icon offset-left with subtle shadow
- "Walkie Talkie" in Segoe UI Bold, white
- Taglines: "Voice rooms. No internet. Just Bluetooth." and "No accounts | No cloud | No server"
- Decorative concentric arcs (right half, low-opacity white)

## Phone screenshots (required — at least 2; 4+ unlocks Play promotion eligibility)

File names: `phoneScreenshots/1.png`, `2.png`, `3.png`, `4.png`
Required size: Between 320 px and 3840 px on the longest side; aspect ratio 16:9 or 9:16 recommended.
Promotion eligibility: at least 4 screenshots with the shorter side ≥ 1080 px.

**Status: committed** — four 1080x1920 mockups generated from `scripts/gen_screenshots.py`.
Upload with `bundle exec fastlane android upload_images`.

Screenshots:
1. **Discovery screen** (`1.png`) — nearby frequency rows with radar animation, "Tune in" buttons, and "Start a new Frequency" card.
2. **Frequency room** (`2.png`) — room header, local user card with PTT button, roster of two peer rows (talking-ring indicator, muted state), PTT mode hint.
3. **Settings screen** (`3.png`) — Voice/Display/Privacy/About sections with toggles and links.
4. **Privacy hero** (`4.png`) — "No internet, no account" cloud-off illustration plus Voice/Identity/Telemetry callouts; mirrors the third explainer page.

To replace with real device captures:
`adb exec-out screencap -p > phoneScreenshots/1.png` (repeat for each screen).

### Mockups vs. real app — known drift

The current Pillow mockups in `scripts/gen_screenshots.py` are stylised
representations and **do not match the in-app palette or typography**:

| Aspect            | Mockup                  | Actual app (`lib/theme/app_theme.dart`)         |
| ----------------- | ----------------------- | ----------------------------------------------- |
| Accent colour     | `#3498DB` blue          | `#4DB47C` green (`FrequencyColors.light.accent`) |
| Background        | `#FAFAFA`               | `#FAFAFB` (close)                               |
| Text font         | Segoe UI / DejaVu Sans  | Inter (no font asset shipped — system fallback) |
| Discovery hero    | "Tuning the dial" radio | Bluetooth-LE peer list with `PulseDot` scanning |
| Room screen       | Two peer rows + PTT pill | `PushToTalkButton`, `PeerRow` linear list       |
| MHz channel label | Mock                    | Real (`'$_newFreq MHz'` in `_buildCreateCard`)  |

A path to faithful captures is tracked in
[#359](https://github.com/ElodinLaarz/walkie-talkie/issues/359). Three
viable approaches with trade-offs:

1. **Widget-test capture** — pump each screen with mock cubits in a
   `flutter test`, wrap in `RepaintBoundary`, call `toImage()`, save PNG.
   Reuses existing mocks in `test/screens/*`. Pre-reqs: bundle Inter as
   an asset (or load via `golden_toolkit`'s `loadAppFonts()`), still the
   `PulseDot` / scanning animations, omit OS chrome (status + nav bars
   are renderer overlays, not in the widget tree).
2. **Emulator + `adb exec-out screencap`** — boot a Pixel-shaped AVD,
   drive the app to each state, capture. Faithful chrome but slow,
   harder to script deterministically, and animations need to be paused.
3. **Hybrid** — capture widget body via #1, composite mock OS chrome
   (status/nav bars) on top in Pillow. Best fidelity-to-cost ratio.

Until that lands, the existing mockups satisfy Play's *graphic asset*
requirement (and promotion-eligibility threshold of 4@1080) but should
be regarded as marketing illustrations, not faithful captures.

## 7-inch tablet screenshots (recommended)

File names: `sevenInchScreenshots/1.png`, `2.png`
Play Console recommends at least 2 even if the app is phone-only.

**Status: committed** — two 1200x1920 mockups generated from `scripts/gen_tablet_screenshots.py`.

Screenshots:
1. **Discovery screen** (`1.png`) — nearby frequency rows with radar, Tune-in buttons, Start card.
2. **Frequency room** (`2.png`) — room header, local user card with PTT button, roster of two peer rows (talking-ring indicator, muted state), PTT mode hint.

To replace with real device captures:
`adb exec-out screencap -p > sevenInchScreenshots/1.png`

## 10-inch tablet screenshots (recommended)

File names: `tenInchScreenshots/1.png`, `2.png`

**Status: committed** — two 1600x2560 mockups generated from `scripts/gen_tablet_screenshots.py`.

Screenshots:
1. **Discovery screen** (`1.png`) — same layout as 7-inch at higher density.
2. **Frequency room** (`2.png`) — same layout as 7-inch at higher density.

To replace with real device captures:
`adb exec-out screencap -p > tenInchScreenshots/1.png`
