# Play Store — Permissions Rationale

Justification text for each permission declared in `AndroidManifest.xml`.
Copy these into the Play Console **App content → Permissions** section, or use
them when responding to a policy review query.

---

## BLUETOOTH_SCAN
> *"To discover other Walkie Talkie rooms broadcasting nearby over Bluetooth LE.
> The `neverForLocation` flag is set — this scan cannot be used to derive the
> user's location."*

**Why needed:** The discovery screen lists nearby hosts that are advertising the
Walkie Talkie service UUID. Without scan permission the list stays empty.

**Privacy note:** `android:usesPermissionFlags="neverForLocation"` is set in the
manifest, so Android does not require the user to grant location permission and
the OS enforces that scan results cannot be used to derive location.

---

## BLUETOOTH_CONNECT
> *"To connect to a nearby Walkie Talkie host and exchange voice and control
> messages over GATT and L2CAP CoC (Bluetooth LE connection-oriented channels)."*

**Why needed:** Joining a room requires a GATT connection to the host for the
control plane (join/leave/roster/mute messages) and an L2CAP CoC channel for
the voice plane (Opus-encoded audio).

---

## BLUETOOTH_ADVERTISE
> *"To broadcast the local frequency so nearby devices can discover and join
> your room when you are acting as host."*

**Why needed:** The host role requires advertising a BLE service so guests can
find the room. Without this permission, a user cannot create their own channel.

---

## RECORD_AUDIO
> *"To capture microphone input for real-time voice transmission to nearby peers
> in the same room. Audio is Opus-encoded and sent directly over Bluetooth LE —
> it is never stored, uploaded, or sent to any server."*

**Why needed:** Core walkie-talkie functionality. The app cannot transmit voice
without microphone access.

---

## MODIFY_AUDIO_SETTINGS
> *"To configure Android's audio routing so that voice output is directed to
> the active audio device — phone speaker, wired headset, or paired Bluetooth
> headset — according to the user's preference."*

**Why needed:** Allows the app to call `AudioManager.setMode()` and route audio
to the correct output device when a Bluetooth headset is connected.

---

## FOREGROUND_SERVICE / FOREGROUND_SERVICE_MICROPHONE / FOREGROUND_SERVICE_CONNECTED_DEVICE
> *"To keep the microphone and Bluetooth connection alive when the screen is off
> or the app is in the background. A foreground service is required by Android
> to sustain microphone capture and BLE connections outside the foreground;
> without it the OS would silence the mic and drop the connection when the user
> pockets their phone mid-conversation."*

**Why needed:** Android 9+ enforces that apps capturing the microphone from the
background must declare and maintain a `foregroundServiceType=microphone`
foreground service. The `connectedDevice` type is additionally required to
maintain the BLE connection while backgrounded.

---

## POST_NOTIFICATIONS
> *"To display the persistent 'Walkie Talkie Active' foreground notification.
> Android 13+ requires notification permission before a foreground service
> notification can appear; this notification is the mandatory indicator that
> the microphone foreground service is running."*

**Why needed:** Android 13+ (API 33) requires `POST_NOTIFICATIONS` to show any
notification, including the mandatory foreground service notification. Denying
this permission on API 33+ would prevent the foreground service from starting,
effectively making the app non-functional while backgrounded.

---

## Summary table

| Permission | Runtime prompt? | User can deny? | Impact if denied |
|---|---|---|---|
| BLUETOOTH_SCAN | Yes (Android 12+) | Yes | Cannot discover nearby rooms |
| BLUETOOTH_CONNECT | Yes (Android 12+) | Yes | Cannot join or host rooms |
| BLUETOOTH_ADVERTISE | Yes (Android 12+) | Yes | Cannot host a room |
| RECORD_AUDIO | Yes | Yes | Cannot transmit voice |
| MODIFY_AUDIO_SETTINGS | No (normal) | N/A | No headset routing |
| FOREGROUND_SERVICE (+ _MICROPHONE, + _CONNECTED_DEVICE) | No (normal) | N/A | OS does not allow mic/BLE BG |
| POST_NOTIFICATIONS | Yes (Android 13+) | Yes | FGS notification hidden; BG operation degraded |
