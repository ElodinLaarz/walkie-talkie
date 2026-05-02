# Play Store — Data Safety Form

Reference answers for the Play Console Data Safety section.
Fill these in at: **Play Console → App content → Data safety**.

---

## Does your app collect or share any of the required user data types?

**Yes** — the app processes two narrow categories:

| Data type | Collected? | Shared? | Notes |
|---|---|---|---|
| Voice or sound recordings (Audio) | Transient / processed | No | Mic audio is captured, Opus-encoded, and transmitted over BLE to nearby phones only. Never stored, never sent to a server. |
| Device or other IDs (Bluetooth MAC / peerId) | Transient / on-device | No | A stable `peerId` UUID is generated on first launch and stored locally. It is shared with peers inside an active room for roster display but never sent off-device to any server. Bluetooth hardware addresses are used only by the OS for BLE connection management. |

All other data type rows should be answered **No**.

---

## Does your app collect data?

**Yes** — but only the two transient categories above.

### Audio

- **Why collected:** To transmit the user's voice to nearby peers in the same Frequency room.
- **Is it encrypted in transit?** No — v1 uses unencrypted Bluetooth LE L2CAP CoC channels
  (`createInsecureL2capChannel` / `listenUsingInsecureL2capChannel`). Link-layer encryption
  is not enforced; a nearby attacker with a BLE sniffer could theoretically intercept voice
  packets. This is disclosed in the in-app Privacy & Security FAQ. Future versions plan to
  add enforced pairing or application-layer encryption.
- **Can the user request deletion?** Not applicable — audio is never stored. It is processed in real time and discarded.
- **Is collection required or optional?** Required to use the core walkie-talkie feature.

### Device or other IDs (peerId)

- **Why collected:** To identify the local peer in the room roster displayed to others.
- **Is it encrypted in transit?** No — same unencrypted BLE L2CAP channel as audio (see above).
  The peerId is low-sensitivity (a random UUID not tied to identity) and is only shared within
  the local Bluetooth range of an active room.
- **Can the user request deletion?** Yes — uninstalling the app deletes all local data including the `peerId`. There is no server-side record to delete. See the Data Deletion section below.
- **Is collection required or optional?** Required.

---

## Does your app share data with third parties?

**No** — with one narrow, opt-in exception.

All peer-to-peer voice and control traffic stays within local Bluetooth range and is never sent to any server. No data is shared with any third party by default.

Exception: if the user explicitly opts in to crash reporting (Settings → Crash reporting, off by default), anonymised crash stack traces are sent to Sentry. These traces contain no audio, no display names, no peer IDs, and no location data. Users who keep crash reporting disabled have zero outbound network traffic.

---

## Security practices

- **Data is encrypted in transit:** No for peer-to-peer voice/control traffic (unencrypted BLE
  L2CAP CoC in v1). Yes for the optional opt-in crash reporting channel (TLS to Sentry).
- **You follow the Families Policy:** N/A — the app is rated 13+ (audio capture).
- **Independent security review:** No formal third-party review at v1 launch.

---

## Data deletion

The app stores no user data on any server. To delete all local data:

1. Open **Settings → Apps → Walkie Talkie → Storage**.
2. Tap **Clear Data**.

Or simply uninstall the app.

For the **"Account and data deletion" URL** Play Console requires, use:

<https://elodinlaarz.github.io/walkie-talkie/privacy-policy/#data-retention-and-deletion>

This anchors directly to the Data Retention and Deletion section of the public
privacy policy, which explains that uninstalling the app removes all local data
and that there is no server-side account to delete.
