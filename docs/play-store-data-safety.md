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
- **Is it encrypted in transit?** Yes — BLE link-layer encryption (LE pairing).
- **Can the user request deletion?** Not applicable — audio is never stored. It is processed in real time and discarded.
- **Is collection required or optional?** Required to use the core walkie-talkie feature.

### Device or other IDs (peerId)

- **Why collected:** To identify the local peer in the room roster displayed to others.
- **Is it encrypted in transit?** Yes — BLE link-layer encryption.
- **Can the user request deletion?** Yes — uninstalling the app deletes all local data including the `peerId`. There is no server-side record to delete. See the Data Deletion section below.
- **Is collection required or optional?** Required.

---

## Does your app share data with third parties?

**No.**

The app has no `INTERNET` permission. It cannot make network connections. No data is shared with any third party or any server operated by the developer.

Exception: if the user explicitly opts in to crash reporting (off by default), anonymised crash stack traces are sent to Sentry. These traces contain no audio, no display names, no peer IDs, and no location data.

---

## Security practices

- **Data is encrypted in transit:** Yes (BLE link-layer encryption for all peer-to-peer traffic; TLS for optional crash reporting).
- **You follow the Families Policy:** N/A — the app is rated 13+ (audio capture).
- **Independent security review:** No formal third-party review at v1 launch.

---

## Data deletion

The app stores no user data on any server. To delete all local data:

1. Open **Settings → Apps → Walkie Talkie → Storage**.
2. Tap **Clear Data**.

Or simply uninstall the app.

For the **"Account and data deletion" URL** Play Console requires: link to the
in-app Settings screen → "Clear local data" action, or point to this document
with the instructions above. Suggested URL: your GitHub Pages privacy-policy
page (already filed under [docs/privacy-policy.md](privacy-policy.md)).
