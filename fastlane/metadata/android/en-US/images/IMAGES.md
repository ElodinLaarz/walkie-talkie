# Play Store Images

Place the following assets in this directory, then upload them via Play Console
or `fastlane supply`.

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

## Phone screenshots (required — at least 2)

File names: `phoneScreenshots/1.png`, `2.png`, `3.png`
Required size: Between 320 px and 3840 px on the longest side; aspect ratio 16:9 or 9:16 recommended.

**Status: committed** — three 1080x1920 mockups generated from `scripts/gen_screenshots.py`.
Upload with `bundle exec fastlane android upload_images`.

Screenshots:
1. **Discovery screen** (`1.png`) — nearby frequency rows with radar animation, "Tune in" buttons, and "Start a new Frequency" card.
2. **Frequency room** (`2.png`) — 98.7 MHz dial, two peer chips orbiting it, PTT and Mute buttons.
3. **Settings screen** (`3.png`) — Voice/Display/Privacy/About sections with toggles and links.

To replace with real device captures:
`adb exec-out screencap -p > phoneScreenshots/1.png` (repeat for each screen).

## 7-inch tablet screenshots (recommended)

File names: `sevenInchScreenshots/1.png`, `2.png`
Play Console recommends at least 2 even if the app is phone-only.

**Status: not yet captured.**

## 10-inch tablet screenshots (recommended)

File names: `tenInchScreenshots/1.png`, `2.png`

**Status: not yet captured.**
