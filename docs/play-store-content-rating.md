# Play Store — Content Rating (IARC Questionnaire)

Reference answers for the Play Console **App content → Content rating** section.
The International Age Rating Coalition (IARC) questionnaire is completed online inside the Play Console; record your answers here so they can be reproduced consistently.

Start the questionnaire at: **Play Console → App content → Content rating → Start questionnaire**.
Select category **Communication** (the app enables real-time audio communication between nearby users).

---

## Questionnaire answers

### Does the app allow users to interact or communicate?

**Yes** — users in the same Frequency room can hear each other's real-time voice.
Select: **User to user communication (voice, video, or text chat)**.

### Does the app include user-generated content?

**No** — voice audio is transmitted in real time and never stored or viewable by other users after the call.

### Does the app contain violent content?

**No.**

### Does the app contain sexual content?

**No.**

### Does the app use location data?

**No** — the `BLUETOOTH_SCAN` permission is declared with `android:usesPermissionFlags="neverForLocation"` and no location APIs are used.

### Does the app contain material related to gambling?

**No.**

### Does the app contain material related to alcohol, tobacco, or drugs?

**No.**

### Does the app contain horror or frightening content?

**No.**

### Does the app contain hate speech or discriminatory content?

**No.**

### Does the app target children?

**No** — the app captures microphone audio and is rated 13+ (see Target audience section below).

---

## Expected IARC rating

Based on the answers above, the questionnaire should produce a rating of **Everyone 13+** (ESRB) / **PEGI 12** or equivalent in other regions, driven solely by the user-to-user voice communication category.

---

## Target audience and content

Fill in at: **Play Console → App content → Target audience and content**.

- **Target age group**: 13 and above.
- **Does your app appeal to children?**: No.
- **Reason**: The app records and transmits microphone audio; content moderation is not feasible for real-time BLE voice, so the app is inappropriate for users under 13.

---

## Notes

- Re-submit the IARC questionnaire if new communication features (text chat, file sharing) are added.
- The content rating applies globally; verify country-specific ratings after the questionnaire completes.
- Retain a screenshot of the completed questionnaire and the issued rating certificate for your records.
