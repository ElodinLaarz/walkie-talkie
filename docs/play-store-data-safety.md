# Play Store — Data Safety Form

Reference answers for the Play Console Data Safety section.
Fill these in at: **Play Console → App content → Data safety**.

---

## Does your app collect or share any of the required user data types?

**Yes** — but only one narrow opt-in category:

| Data type | Collected? | Shared? | Notes |
|---|---|---|---|
| Crash logs | Yes (opt-in only) | Yes — Sentry | Off by default; user toggles on via Settings → Crash reporting. TLS to Sentry. No audio, no display names, no peer IDs, no location. |
| Diagnostics (perf metrics) | Yes (opt-in only) | Yes — Sentry | Same envelope as crash logs. |

All other data type rows answered **No**, including Audio (voice) and Device or other IDs (peerId). See "Why audio and peerId are not declared" below.

---

## Does your app collect data?

**Yes** — but only the two opt-in Sentry categories above.

### Crash logs and Diagnostics (Sentry, opt-in only)

- **Why collected:** App functionality — improving crash-free experience and identifying performance regressions.
- **Is it encrypted in transit?** Yes — TLS to Sentry's ingestion endpoint.
- **Can the user request deletion?** Yes — toggling crash reporting off stops new uploads, and uninstalling the app or clearing app data removes the local queue. Sentry's data retention is governed by Sentry's own policy, linked from the privacy page.
- **Is collection required or optional?** Optional. The toggle defaults to off; users must explicitly enable it.
- **Shared with third parties?** Yes — Sentry. No other third party receives any data.

## Why audio and peerId are not declared

Voice audio and the local `peerId` UUID are transmitted over Bluetooth LE to other peers in the same Frequency room — peers the user explicitly chose to communicate with by joining a shared frequency. The developer never receives, processes, or stores either of these data types; they exist only on the user's device and on the devices of co-present peers within ~10 m of BLE radio range.

Per Google Play's Data Safety guidance:

> Data sent to other users in your app shouldn't be declared as data collection, unless you also collect and use that data.

That guidance applies cleanly here: the app's voice and peerId are user-to-user only, with no developer-side collection. Declaring them on the Data Safety form would over-state the app's data footprint and force a "No" answer on the encryption-in-transit question (since BLE L2CAP CoC is `createInsecureL2capChannel`), even though no data is actually leaving the user-to-user channel.

The unencrypted BLE link is still disclosed in the in-app Privacy & Security FAQ — this section explains why it doesn't surface as a Data Safety declaration, not why we ignore it.

---

## Does your app share data with third parties?

**No** — with one narrow, opt-in exception.

All peer-to-peer voice and control traffic stays within local Bluetooth range and is never sent to any server. No data is shared with any third party by default.

Exception: if the user explicitly opts in to crash reporting (Settings → Crash reporting, off by default), anonymised crash stack traces are sent to Sentry. These traces contain no audio, no display names, no peer IDs, and no location data — the sanitizer in `lib/services/sentry_event_sanitizer.dart` strips peer IDs from contexts, tags, and breadcrumbs (including nested values) before transmission, so only Sentry's own SDK-generated session identifiers are used for crash correlation. Users who keep crash reporting disabled send no outbound crash telemetry.

---

## Security practices

- **Data is encrypted in transit:** Yes — all data declared as collected (crash logs, diagnostics) is transmitted over TLS to Sentry. Peer-to-peer voice/control traffic over BLE L2CAP CoC is not declared as collection (see "Why audio and peerId are not declared" above) and is unencrypted at the link layer; this is disclosed separately in the in-app Privacy & Security FAQ.
- **You follow the Families Policy:** N/A — the app is rated 13+ (audio capture).
- **Independent security review:** No formal third-party review at v1 launch.

---

## Data deletion

The app stores no user data on any server. To delete all local data:

1. Open **Settings → Apps → Frequency → Storage**.
2. Tap **Clear Data**.

Or simply uninstall the app.

For the **"Account and data deletion" URL** Play Console requires, use:

<https://elodinlaarz.github.io/walkie-talkie/privacy-policy/#data-retention-and-deletion>

This anchors directly to the Data Retention and Deletion section of the public
privacy policy, which explains that uninstalling the app removes all local data
and that there is no server-side account to delete.
