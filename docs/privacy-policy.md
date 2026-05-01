# Frequency — Privacy Policy

_Last updated: 2026-04-30_

Frequency is an offline, peer-to-peer walkie-talkie app for Android. It runs
entirely on the phones in the conversation — there is no Frequency server, no
cloud sync, no analytics SDK, and no account system. This document describes
exactly what data the app touches, where it lives, and how to remove it.

## TL;DR

- **No internet is required for voice or control.** The app does not declare
  the `INTERNET` permission in its main manifest and cannot transmit your
  audio off-device.
- **No accounts.** There is nothing to sign up for and nothing to delete from
  a server because no server exists.
- **No third-party analytics, ads, or tracking.**
- The only data Frequency stores is on your own device, and uninstalling the
  app removes all of it.

## Data the app processes

### Audio (microphone)

Frequency captures audio from your phone's microphone while you are in a
voice room and you are talking (or transmitting if push-to-talk is held).
The audio is encoded with Opus and streamed over a Bluetooth LE L2CAP
channel directly to the other phones in the same room. **Audio is not
recorded to disk, not sent to any server, and not retained after it has
been transmitted.**

### Bluetooth identifiers

To find nearby phones running Frequency the app advertises and scans for a
Frequency-specific Bluetooth service UUID. While in a room your phone
exchanges its Bluetooth MAC address and a per-room session UUID with the
host so packets can be routed to the right peer. Bluetooth identifiers are
used solely to maintain the active connection and are not collected,
aggregated, or sent anywhere.

The Bluetooth scan permission is requested with the
`neverForLocation` flag, and the app does not use Bluetooth scan results
to derive your location.

### On-device storage

Frequency stores a small amount of data locally on your device so it can
remember you between launches:

- **Display name** — the handle you chose during onboarding. Shown to other
  peers in the same room.
- **Stable peer ID** — a random identifier generated on first launch so
  other peers can recognize your phone across reconnects in the same room.
- **Recent frequencies** — the most recently hosted channels, surfaced as
  a "Recent" list on the Discovery screen.
- **Blocked peers** — peer IDs you have muted so the mute persists across
  reconnects.

This data lives in the app's private storage on your phone (sqflite and a
legacy Hive box that is being migrated). It is never transmitted off the
device by Frequency.

### Crash and diagnostic data

Frequency does not include any crash reporter, telemetry SDK, or analytics
library. If a crash reporter is added in a future version it will be
**opt-in** and the in-app setting will state exactly what is sent.

## Permissions and why each is requested

| Permission | Why Frequency needs it |
| --- | --- |
| `BLUETOOTH_SCAN` (with `neverForLocation`) | Find other phones advertising the Frequency service nearby. |
| `BLUETOOTH_CONNECT` | Open a GATT control connection to the host of the room you join. |
| `BLUETOOTH_ADVERTISE` | Advertise your device when you are hosting a room so others can find it. |
| `RECORD_AUDIO` | Capture your voice while you are talking in a room. |
| `MODIFY_AUDIO_SETTINGS` | Route audio to the speaker, a wired headset, or a paired Bluetooth headset. |
| `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_MICROPHONE` / `FOREGROUND_SERVICE_CONNECTED_DEVICE` | Keep the mic and Bluetooth radio running while the screen is off so the room does not drop when the phone locks. |
| `POST_NOTIFICATIONS` | Show the foreground-service notification that lets you know a room is active and provides controls. |

## Children's privacy

Frequency captures audio. The app is targeted at users **13 and older**
and we do not knowingly collect any data from children under that age.

## Data retention and deletion

There is no remote account, so there is nothing to delete from a server.
All data Frequency stores lives on your phone. To remove every piece of
data the app has ever stored:

1. Open **Settings → Apps → Frequency → Storage** on your Android device.
2. Tap **Clear storage** to wipe the app's data, or **Uninstall** to
   remove the app entirely.

Uninstalling the app removes the local database, the display name, the
peer ID, the recent-frequencies list, and the blocked-peers list.

## Changes to this policy

If we change how Frequency processes data we will update this file and
revise the "Last updated" date at the top. The canonical source of this
policy is the
[`docs/privacy-policy.md`](https://github.com/ElodinLaarz/walkie-talkie/blob/main/docs/privacy-policy.md)
file in the project's GitHub repository.

## Contact

Questions, concerns, or reports about Frequency's privacy practices can
be filed as an issue on the project's GitHub repository:

- <https://github.com/ElodinLaarz/walkie-talkie/issues>
