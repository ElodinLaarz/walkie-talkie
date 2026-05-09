---
permalink: /invite-links/
---

# Invite Links

Walkie-Talkie uses a custom URI scheme so users can share a frequency with nearby friends before they open the app.

## Format

```
walkietalkie://join?freq=<mhzDisplay>
```

| Parameter | Description | Example |
|-----------|-------------|---------|
| `freq` | The MHz display string of the frequency (URL-encoded) | `104.3` |

Example link:

```
walkietalkie://join?freq=104.3
```

## How it works

**Sender (host device)**

1. Open a frequency room.
2. Tap the invite icon to open the invite sheet.
3. Tap **Copy invite link** — the link is copied to the clipboard and a confirmation snackbar appears.
4. Share the link via any messaging app.

**Receiver (guest device)**

1. Tap the link. Android resolves `walkietalkie://` to the app and opens it.
2. If the app was closed, it opens to the discovery screen.
3. A banner ("Looking for X MHz…") appears while BLE scanning is active.
4. When the host's frequency appears in the nearby list the user can tap it to join normally.

## Why a custom scheme instead of App Links?

App Links (HTTPS universal links) require a hosted `.well-known/assetlinks.json` file, which conflicts with the app's offline-first, no-account design. The custom `walkietalkie://` scheme works entirely on-device with no internet dependency.

## Android manifest

The intent filter is declared in `android/app/src/main/AndroidManifest.xml`:

```xml
<intent-filter android:autoVerify="false">
    <action android:name="android.intent.action.VIEW"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <category android:name="android.intent.category.BROWSABLE"/>
    <data android:scheme="walkietalkie" android:host="join"/>
</intent-filter>
```

## Native → Flutter bridge

- **Cold start** — Flutter calls `getInitialLink()` via `MethodChannel` once the engine is ready. The native side reads `Activity.getIntent().getData()` and returns the `freq` query parameter (or `null`).
- **Warm start** — `onNewIntent` fires; the native side sends `{"type": "openInviteLink", "freq": "..."}` through the existing `audio_events` EventChannel.
