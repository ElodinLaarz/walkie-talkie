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

**Status: not yet captured.** Place screenshots here once captured, then run
`bundle exec fastlane android upload_images` to push them.

Suggested shots (capture on a Pixel 8 or similar at 1080x2400):
1. **Discovery screen** — showing 2-3 nearby frequency rows with the radar animation.
2. **Frequency room** — showing the central dial, 2 peer chips with talking rings, and the PTT button.
3. **Settings screen** — showing the PTT mode toggle and About section.

To capture: `adb exec-out screencap -p > phoneScreenshots/1.png` (repeat for each screen).

## 7-inch tablet screenshots (recommended)

File names: `sevenInchScreenshots/1.png`, `2.png`
Play Console recommends at least 2 even if the app is phone-only.

**Status: not yet captured.**

## 10-inch tablet screenshots (recommended)

File names: `tenInchScreenshots/1.png`, `2.png`

**Status: not yet captured.**
