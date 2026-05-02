# Play Store — Store Listing Text

Draft copy for the Play Console **Store presence → Main store listing** section.
All character limits are Play Store maxima; counts shown after each field.

---

## App name

```
Walkie Talkie
```

13 characters (max 30).

---

## Short description

```
Offline voice rooms over Bluetooth LE — no internet or accounts needed.
```

71 characters (max 80).

---

## Long description

```
Talk to anyone nearby — no internet, no accounts, no servers.

Walkie Talkie turns your Android phone into a classic push-to-talk radio using Bluetooth Low Energy. Press the big button, speak, release. Everyone in the same "Frequency" hears you instantly, even when there's no Wi-Fi signal in sight.

── How it works ──

One person hosts a Frequency room. Others nearby discover it automatically and join with a single tap. Voice is compressed with Opus and sent directly over encrypted Bluetooth LE — it never touches any server or the internet.

── Built for real life ──

• Works at concerts, hiking trails, ski slopes, building sites, or anywhere else cell signal disappears.
• Background mode: pocket your phone and keep talking. A persistent notification keeps the mic and connection alive.
• Multiple rooms: Frequencies are labelled so friends know which channel to join.
• Roster: see who's in the room and mute anyone who's causing noise.
• Host transfer: if the host leaves, another peer automatically takes over so the room stays up.

── Privacy first ──

• Zero internet permission — verified by Android: the app's manifest declares no INTERNET permission.
• No accounts, no sign-up, no cloud.
• Voice audio is processed in real time and discarded — nothing is recorded or stored.
• A random peer ID is generated locally on first launch; it lives only on your device.
• Optional crash reporting (off by default): if you opt in, anonymised stack traces are sent to Sentry — no audio, no names, no location.

── Permissions explained ──

• Bluetooth (scan / connect / advertise): to discover rooms and host them.
• Microphone: to capture your voice for transmission.
• Foreground service + notifications: Android requires these to keep the mic alive when the screen is off.

── Requirements ──

Android 9.0 (API 28) or higher. Bluetooth LE support required (present on virtually all phones made since 2014). Works best within 30–100 m of the host; range depends on environment and device hardware.
```

1 474 characters (max 4 000).

---

## Notes for Play Console

- Paste the **App name** into *Store presence → Main store listing → App name*.
- Paste **Short description** into *Store presence → Main store listing → Short description*.
- Paste **Long description** into *Store presence → Main store listing → Full description*.
- Review and localise the copy if the app ships in multiple languages.
- The permissions paragraph mirrors `docs/play-store-permissions-rationale.md`; keep them in sync.
