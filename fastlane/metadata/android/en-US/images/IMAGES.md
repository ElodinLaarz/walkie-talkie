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

**Status: committed** — four 1080x1920 captures generated from real Flutter widgets.
Upload with `bundle exec fastlane android upload_images`.

Screenshots:
1. **Discovery screen** (`1.png`) — actual discovery UI with recent and nearby frequency rows, scanning state, and "Start a new Frequency" card.
2. **Frequency room** (`2.png`) — actual room UI with on-air chrome, media controls, PTT, and a real `PeerRow` roster.
3. **Settings screen** (`3.png`) — Voice/Display/Privacy/About sections with toggles and links.
4. **Bluetooth/no-cloud explainer** (`4.png`) — the real third explainer page rendered by `FrequencyExplainerScreen`.

Regenerate from widgets:
```
dart tool/generate_store_screenshots.dart
```

## 7-inch tablet screenshots (recommended)

File names: `sevenInchScreenshots/1.png`, `2.png`
Play Console recommends at least 2 even if the app is phone-only.

**Status: committed** — two 1200x1920 captures generated from real Flutter widgets.

Screenshots:
1. **Discovery screen** (`1.png`) — nearby frequency rows with radar, Tune-in buttons, Start card.
2. **Frequency room** (`2.png`) — room header, local user card with PTT button, roster of two peer rows (talking-ring indicator, muted state), PTT mode hint.

Regenerate from widgets:
```
dart tool/generate_store_screenshots.dart
```

## 10-inch tablet screenshots (recommended)

File names: `tenInchScreenshots/1.png`, `2.png`

**Status: committed** — two 1600x2560 captures generated from real Flutter widgets.

Screenshots:
1. **Discovery screen** (`1.png`) — same layout as 7-inch at higher density.
2. **Frequency room** (`2.png`) — same layout as 7-inch at higher density.

Regenerate from widgets:
```
dart tool/generate_store_screenshots.dart
```
