# Walkie-Talkie Smoke Test Runbook

Manual end-to-end test procedure for verifying BLE/L2CAP/voice functionality across physical devices.

## Pre-flight

### Hardware Requirements
- **Two Android 12+ devices** covering the OEM matrix:
  - **Minimum**: One Pixel + one Samsung
  - **Ideal**: Add Xiaomi or OnePlus to catch aggressive battery-management failures

### Setup
1. Fresh installation on both devices
2. Bluetooth enabled on both
3. All permissions granted at onboarding:
   - `BLUETOOTH_SCAN`
   - `BLUETOOTH_CONNECT`
   - `BLUETOOTH_ADVERTISE`
   - `RECORD_AUDIO`
   - `POST_NOTIFICATIONS` (Android 13+) — required for the foreground service notification; denial prevents FGS from starting (see step 11)

### Test Environment Record
Document for each test run:
- Device A: **Model**: _____________ **Android Version**: _____________
- Device B: **Model**: _____________ **Android Version**: _____________
- App Version: _____________
- Test Date: _____________
- Tester: _____________

---

## Test Steps

### 1. Host Creation
**Device A** (will be "Alice" for this test):
1. Enter display name: "Alice"
2. Tap **Start a new Frequency**
3. **Verify**:
   - Notification shows MHz frequency (e.g., "104.3 MHz")
   - Notification has **Leave** action
   - Room screen displays with Alice as the only peer in roster

**Pass/Fail**: ☐ Pass ☐ Fail  
**Notes**: _______________________________________________

---

### 2. Discovery
**Device B** (will be "Bob"):
1. Enter display name: "Bob"
2. Land on Discovery screen
3. **Verify**:
   - Alice's frequency row appears within **5 seconds**
   - MHz string matches what Device A shows
   - Host name shows "Alice"
   - Signal strength indicator present

**Pass/Fail**: ☐ Pass ☐ Fail  
**Timing** (discovery latency): _______ seconds  
**Notes**: _______________________________________________

---

### 3. Join Request & Acceptance
**Device B**:
1. Tap **Tune in** on Alice's row

**Device A**:
1. **Verify**: "Bob wants to tune in" toast appears within **2 seconds**
2. Tap **Let in**

**Both Devices**:
1. **Verify**: Roster shows both Alice and Bob within **2 seconds**

**Pass/Fail**: ☐ Pass ☐ Fail  
**Timing** (join handshake): _______ seconds  
**Notes**: _______________________________________________

---

### 4. Voice Transmission
**Device A** (Alice speaks):
1. Speak into Device A microphone: "Testing one two three"

**Device B** (Bob listens):
1. **Verify**:
   - Alice's talking ring lights up
   - Audio is audible on Device B
   - Audio quality is acceptable (subjective)

**Repeat in reverse** (Bob speaks, Alice listens):
1. Speak into Device B: "Copy that, loud and clear"

**Device A**:
1. **Verify**:
   - Bob's talking ring lights up
   - Audio is audible on Device A
   - Audio quality is acceptable

**Pass/Fail**: ☐ Pass ☐ Fail  
**Audio Quality** (1-5): A→B: ☐ B→A: ☐  
**Latency** (estimated): _______ ms  
**Notes**: _______________________________________________

---

### 5. Mute Functionality
**Device B** (Bob):
1. Tap **Mute** button
2. Speak into microphone

**Device A**:
1. **Verify**:
   - Alice no longer hears Bob
   - Roster shows Bob with muted indicator

**Device B**:
1. Tap **Mute** again to unmute
2. **Verify**: Mute indicator disappears

**Pass/Fail**: ☐ Pass ☐ Fail  
**Notes**: _______________________________________________

---

### 6. Media Controls
**Device A** (Alice):
1. Tap **Skip** in media player

**Device B** (Bob):
1. **Verify**: Media UI advances to next track within **500 ms**
2. Track title/artist updates correctly

**Repeat with other media controls** (Play/Pause, Previous):
- **Play/Pause**: ☐ Pass ☐ Fail
- **Previous**: ☐ Pass ☐ Fail
- **Skip**: ☐ Pass ☐ Fail

**Pass/Fail**: ☐ Pass ☐ Fail  
**Notes**: _______________________________________________

---

### 7. Range / Weak Signal
**Device B** (Bob):
1. Walk approximately **20 meters away** from Device A
2. Maintain line-of-sight if possible

**Device A** (Alice):
1. **Verify**: "Bob's signal is weak" toast appears within **30 seconds**

**Device B**:
1. Walk back to original position
2. **Verify**: Signal indicator returns to normal

**Pass/Fail**: ☐ Pass ☐ Fail  
**Distance to trigger**: _______ meters  
**Timing**: _______ seconds  
**Notes**: _______________________________________________

---

### 8. Reconnect (Long Disconnection)
**Device B** (Bob):
1. Walk behind a concrete wall or obstruction that breaks BLE signal
2. Wait until app returns to Discovery screen (target: **≤15 seconds**)
3. **Verify**: "Lost connection" toast displays

**Device A** (Alice):
1. **Verify**: Roster updates to show only Alice within **15 seconds**

**Device B**:
1. Walk back within range
2. Tap **Tune in** on Alice's frequency again
3. **Verify**:
   - Reconnection succeeds
   - Roster shows both peers
   - Media state restored (playing status, track position)

**Pass/Fail**: ☐ Pass ☐ Fail  
**Disconnect detection time**: _______ seconds  
**Reconnect time**: _______ seconds  
**Notes**: _______________________________________________

---

### 9. Reconnect (Short / Auto-Reconnect)
**Device B** (Bob):
1. Walk behind obstruction for **3 seconds only**
2. Return to range before full disconnection timeout

**Both Devices**:
1. **Verify**:
   - Voice resumes automatically within **2 seconds** of re-emerging
   - UI shows "Reconnecting…" pill during the gap
   - No manual re-tune required

**Pass/Fail**: ☐ Pass ☐ Fail  
**Auto-reconnect latency**: _______ seconds  
**Notes**: _______________________________________________

---

### 10. Clean Leave
**Device B** (Bob):
1. Tap **Leave** button

**Device A** (Alice):
1. **Verify**: Roster updates within **2 seconds** to show only Alice

**Device B**:
1. **Verify**: Returns to Discovery screen

**Pass/Fail**: ☐ Pass ☐ Fail  
**Notes**: _______________________________________________

---

### 11. POST_NOTIFICATIONS Denial Path (Android 13+ only)
**Prerequisites**: Device running Android 13+ (API 33+). Fresh install or cleared app data so the permission prompt reappears.

**Device A** (Alice):
1. Launch app and proceed through onboarding
2. When the notification permission dialog appears, tap **Don't allow**
3. Tap **Start a new Frequency** to create a room

**Device A**:
1. **Verify**: App does not crash
2. **Verify**: A descriptive error or warning is shown (toast, dialog, or permission-denied screen) — the app must not silently proceed as if the foreground service started normally
3. **Verify**: Tapping the prompt (if shown) to open Settings lets the user grant the permission and retry

> **Note:** On some OEM/Android combinations the foreground service notification may still appear due to OS-level exceptions. Document the outcome — pass or deviation — with device model and API level.

**Pass/Fail**: ☐ Pass ☐ Fail  
**Device model / API level**: _____________  
**Observed behaviour**: _______________________________________________  
**Notes**: _______________________________________________

---

### 12. Crash Reporting Toggle Round-Trip
**Prerequisites**: Build compiled with a Sentry DSN (`kSentryConfigured = true`); otherwise the toggle is read-only and this section is not applicable.

**Device A**:
1. Navigate to **Settings** (gear icon or overflow menu in the room or discovery screen)
2. Locate **Crash reporting** toggle under Privacy
3. Enable the toggle

**Device A**:
1. **Verify**: Snackbar appears: *"Crash reporting enabled. Restart the app to apply."*
2. Fully close and relaunch the app
3. **Verify**: App launches without crash, Sentry session is active (observable via Sentry dashboard or proxy: no crash on launch)

**Device A**:
1. Navigate back to Settings → Privacy
2. Disable the **Crash reporting** toggle

**Device A**:
1. **Verify**: Snackbar appears: *"Crash reporting disabled. Restart the app to apply."*
2. Fully close and relaunch the app
3. **Verify**: No Sentry network traffic is initiated (no outbound connections to `*.sentry.io`)

**Pass/Fail (enable)**: ☐ Pass ☐ Fail  
**Pass/Fail (disable)**: ☐ Pass ☐ Fail  
**Notes**: _______________________________________________

---

### 13. Block & Report
**Prerequisites**: Two devices in the same Frequency room (Alice hosting, Bob joined).

**Device A** (Alice):
1. Tap **Bob's avatar** or name in the room roster to open the peer drawer
2. Tap the **Report** button in the peer drawer

**Device A**:
1. **Verify**: "Bob blocked" dialog appears with message indicating Bob has been muted and blocked
2. **Verify**: Bob's entry in the roster now shows a muted indicator
3. Tap **Email report**

**Device A**:
1. **Verify**: System email sheet opens with:
   - **To**: `support@formalizedchaos.com`
   - **Subject**: `Frequency abuse report`
   - **Body**: Pre-filled sanitized abuse report (peer ID, timestamp, room context — no raw display names or PII beyond what the user typed)

> **If no email app is installed**: Tap **Copy report** instead and verify the clipboard contains the report text.

**Pass/Fail**: ☐ Pass ☐ Fail  
**Notes**: _______________________________________________

---

## Known Risks & Failure Modes

### OEM Bluetooth Roulette
**Symptom**: Connection stable on Pixel but silently drops on Samsung, or fails to advertise on Xiaomi.

**Root Cause**: Aggressive battery management by OEM kills background BLE advertising or GATT connections.

**Mitigation**: Foreground service + auto-reconnect logic should mitigate. Document which OEM/model fails.

**Action**: Record device model + Android version on failure. Tag failure report with OEM name.

---

### L2CAP CoC Instability
**Symptom**: Voice fails to establish, but control plane works (roster appears, media commands fire).

**Root Cause**: `listenUsingInsecureL2capChannel` is flaky on some Android versions.

**Mitigation**: Auto-reconnect retry should kick in.

**Action**: Note failure mode in test results. Verify auto-reconnect attempts occur.

---

### Audio Glitches / Stutters
**Symptom**: Voice transmission has periodic stutters, pops, or dropouts.

**Possible Causes**:
- Mixer thread blocking (mutex contention)
- Oboe callback blocking
- Aggressive CPU throttling
- L2CAP buffer overrun

**Action**: Note audio quality rating. Test on different OEM to isolate hardware/firmware issues.

---

### Fragment Reassembly Failures
**Symptom**: Roster updates fail to propagate, or media commands ignored intermittently.

**Root Cause**: Negotiated MTU < 247 bytes causes fragmentation; OS drops packets.

**Mitigation**: Fragment reassembler should handle drops gracefully.

**Action**: Check logcat for `FragmentError` / `UnexpectedFragmentIndex`. Note frequency of drops.

---

## Test Completion Checklist

- ☐ All 13 test steps executed (steps 11–13 require specific device/build conditions — see prerequisites)
- ☐ Device models + Android versions recorded
- ☐ Pass/Fail status marked for each step
- ☐ Timing measurements recorded (where applicable)
- ☐ Audio quality ratings provided
- ☐ Failure modes documented (if any)
- ☐ Known risks observed and noted
- ☐ Test results shared with team

---

## Acceptance Criteria

This test runbook is considered complete when:
- ✅ Document exists in `docs/smoke-test.md`
- ✅ Has been executed end-to-end **at least once** on each OEM in the matrix
- ✅ Timing measurements + device versions recorded for each run
- ✅ Failure modes catalogued by OEM/model when they occur

---

## Test Results Log

### Run 1
- **Date**: _____________ **Tester**: _____________
- **Device A**: _____________ (Android _______)
- **Device B**: _____________ (Android _______)
- **Overall**: ☐ Pass ☐ Partial Pass ☐ Fail
- **Failed Steps**: _____________
- **Notes**: _____________

### Run 2
- **Date**: _____________ **Tester**: _____________
- **Device A**: _____________ (Android _______)
- **Device B**: _____________ (Android _______)
- **Overall**: ☐ Pass ☐ Partial Pass ☐ Fail
- **Failed Steps**: _____________
- **Notes**: _____________

### Run 3
- **Date**: _____________ **Tester**: _____________
- **Device A**: _____________ (Android _______)
- **Device B**: _____________ (Android _______)
- **Overall**: ☐ Pass ☐ Partial Pass ☐ Fail
- **Failed Steps**: _____________
- **Notes**: _____________
