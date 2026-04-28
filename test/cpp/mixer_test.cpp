#include <iostream>
#include <vector>
#include <map>
#include <mutex>
#include <cstdio>
#include <cstring>
#include <cassert>
#include <algorithm>

// Mock Android logging for standalone testing
#define LOGI(...) printf(__VA_ARGS__); printf("\n")

/**
 * AudioMixer implements the "Mix-Minus" routing logic.
 * Each device hears all other devices except themselves.
 *
 * Standalone CI mirror of android/app/src/main/cpp/audio_mixer.{cpp,h}.
 * Keep the [onVoiceFrame] / poison logic in lock-step with production —
 * this file is what CI exercises (production needs the Android NDK).
 */
class AudioMixer {
public:
    // Mirrors production AudioMixer::kPoisonThreshold (audio_mixer.h).
    static constexpr uint32_t kPoisonThreshold = 16;

private:
    struct DeviceState {
        std::vector<int16_t> buffer;
        bool poisoned = false;
        uint32_t lastSeq = 0;  // 0 = no frames seen yet
    };

    std::mutex mixerMutex;

    // Map of device ID to their per-peer state
    std::map<int, DeviceState> devices;

    // Maximum number of simultaneous devices
    static constexpr int kMaxDevices = 3;

public:
    // Add a device to the mixer
    bool addDevice(int deviceId) {
        std::lock_guard<std::mutex> lock(mixerMutex);

        if (devices.size() >= kMaxDevices) {
            LOGI("Maximum devices reached (%d)", kMaxDevices);
            return false;
        }

        devices[deviceId] = DeviceState{};
        LOGI("Device %d added to mixer", deviceId);
        return true;
    }

    // Remove a device from the mixer
    void removeDevice(int deviceId) {
        std::lock_guard<std::mutex> lock(mixerMutex);
        devices.erase(deviceId);
        LOGI("Device %d removed from mixer", deviceId);
    }

    // Update audio data for a device (local-mic style, no seq).
    // The peer-receive path goes through [onVoiceFrame] instead.
    void updateDeviceAudio(int deviceId, const int16_t* audioData, int numFrames) {
        std::lock_guard<std::mutex> lock(mixerMutex);

        auto it = devices.find(deviceId);
        if (it != devices.end()) {
            it->second.buffer.assign(audioData, audioData + numFrames);
        }
    }

    // Feed a peer-arrived voice frame with its over-the-wire seq. Mirrors the
    // production stuck-producer prune: a frame whose forward delta from the
    // last accepted seq exceeds [kPoisonThreshold] is dropped and the peer is
    // marked poisoned; the next valid frame within the threshold recovers.
    // Out-of-order / duplicate frames (delta <= 0) are silently dropped without
    // affecting the watermark or the poison flag. Wrap-safe via signed int32
    // delta (matches production audio_mixer.cpp).
    void onVoiceFrame(int deviceId, uint32_t seq, const int16_t* pcm, int numFrames) {
        std::lock_guard<std::mutex> lock(mixerMutex);

        auto it = devices.find(deviceId);
        if (it == devices.end()) {
            return;
        }
        DeviceState& s = it->second;

        const uint32_t prevSeq = s.lastSeq;
        if (prevSeq != 0) {
            const int32_t diff = static_cast<int32_t>(seq - prevSeq);

            if (diff <= 0) {
                // Out-of-order or duplicate — silently drop.
                return;
            }

            if (diff > static_cast<int32_t>(kPoisonThreshold)) {
                s.poisoned = true;
                // Advance lastSeq so the next within-threshold frame recovers.
                // Drop the current frame's audio (do not write to s.buffer) —
                // production also avoids clearing the in-flight ring buffer
                // here (SPSC contract).
                s.lastSeq = seq;
                LOGI("Device %d poisoned: seq jump %u -> %u (gap %d)", deviceId, prevSeq, seq, diff);
                return;
            }
        }

        if (s.poisoned) {
            s.poisoned = false;
            LOGI("Device %d recovered at seq %u", deviceId, seq);
        }
        s.buffer.assign(pcm, pcm + numFrames);
        s.lastSeq = seq;
    }

    bool isPoisoned(int deviceId) {
        std::lock_guard<std::mutex> lock(mixerMutex);
        auto it = devices.find(deviceId);
        return it != devices.end() && it->second.poisoned;
    }

    // Get mixed audio for a specific device (all others except this device)
    void getMixedAudioForDevice(int deviceId, int16_t* outputBuffer, int numFrames) {
        std::lock_guard<std::mutex> lock(mixerMutex);

        // Initialize output buffer to zero
        std::memset(outputBuffer, 0, numFrames * sizeof(int16_t));

        // Mix all devices except the target device
        for (const auto& [id, state] : devices) {
            if (id != deviceId && !state.buffer.empty()) {
                int framesToMix = std::min(numFrames, static_cast<int>(state.buffer.size()));
                for (int i = 0; i < framesToMix; i++) {
                    // Simple mixing with clipping prevention
                    int32_t mixed = outputBuffer[i] + state.buffer[i];
                    outputBuffer[i] = static_cast<int16_t>(
                        std::max<int32_t>(-32768, std::min<int32_t>(32767, mixed))
                    );
                }
            }
        }
    }

    // Clear all device buffers
    void clear() {
        std::lock_guard<std::mutex> lock(mixerMutex);
        devices.clear();
        LOGI("Mixer cleared");
    }

    // Helper for testing: get number of devices
    size_t getDeviceCount() {
        std::lock_guard<std::mutex> lock(mixerMutex);
        return devices.size();
    }
};

void testMixMinus() {
    AudioMixer mixer;
    mixer.addDevice(1);
    mixer.addDevice(2);
    mixer.addDevice(3);

    // 100 frames of audio
    const int numFrames = 100;
    int16_t audio1[numFrames];
    int16_t audio2[numFrames];
    int16_t audio3[numFrames];

    for (int i = 0; i < numFrames; i++) {
        audio1[i] = 100;
        audio2[i] = 200;
        audio3[i] = 300;
    }

    mixer.updateDeviceAudio(1, audio1, numFrames);
    mixer.updateDeviceAudio(2, audio2, numFrames);
    mixer.updateDeviceAudio(3, audio3, numFrames);

    int16_t out1[numFrames];
    int16_t out2[numFrames];
    int16_t out3[numFrames];

    mixer.getMixedAudioForDevice(1, out1, numFrames);
    mixer.getMixedAudioForDevice(2, out2, numFrames);
    mixer.getMixedAudioForDevice(3, out3, numFrames);

    // Device 1 should hear (2 + 3) = 200 + 300 = 500
    // Device 2 should hear (1 + 3) = 100 + 300 = 400
    // Device 3 should hear (1 + 2) = 100 + 200 = 300
    for (int i = 0; i < numFrames; i++) {
        assert(out1[i] == 500);
        assert(out2[i] == 400);
        assert(out3[i] == 300);
    }

    std::cout << "Test Mix-Minus: PASSED" << std::endl;
}

void testClipping() {
    AudioMixer mixer;
    mixer.addDevice(1);
    mixer.addDevice(2);

    const int numFrames = 10;
    int16_t audio1[numFrames];
    int16_t audio2[numFrames];

    for (int i = 0; i < numFrames; i++) {
        audio1[i] = 30000;
        audio2[i] = 30000;
    }

    mixer.updateDeviceAudio(1, audio1, numFrames);
    mixer.updateDeviceAudio(2, audio2, numFrames);

    int16_t out1[numFrames];
    mixer.getMixedAudioForDevice(1, out1, numFrames);

    // Device 1 hears Device 2 (30000)
    for (int i = 0; i < numFrames; i++) {
        assert(out1[i] == 30000);
    }

    // Add Device 3 with large audio to force clipping
    mixer.addDevice(3);
    int16_t audio3[numFrames];
    for (int i = 0; i < numFrames; i++) audio3[i] = 30000;
    mixer.updateDeviceAudio(3, audio3, numFrames);

    mixer.getMixedAudioForDevice(1, out1, numFrames);
    // Device 1 hears (2 + 3) = 30000 + 30000 = 60000 (clamped to 32767)
    for (int i = 0; i < numFrames; i++) {
        assert(out1[i] == 32767);
    }

    std::cout << "Test Clipping: PASSED" << std::endl;
}

void testMaxDevices() {
    AudioMixer mixer;
    assert(mixer.addDevice(1) == true);
    assert(mixer.addDevice(2) == true);
    assert(mixer.addDevice(3) == true);
    assert(mixer.addDevice(4) == false); // kMaxDevices is 3
    assert(mixer.getDeviceCount() == 3);

    std::cout << "Test Max Devices: PASSED" << std::endl;
}

// Issue #49: a peer whose seq jumps by > kPoisonThreshold is muted until a
// contiguous seq arrives. This is the test the issue's acceptance criteria
// names explicitly: "feed seqs 1, 2, 20 → mixer poisons; feed seq 21 → mixer
// recovers."
void testStuckProducerPrune() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 8;
    int16_t audio[kFrames];
    for (int i = 0; i < kFrames; i++) audio[i] = 1000;

    // Normal flow: contiguous low seqs.
    mixer.onVoiceFrame(1, 1, audio, kFrames);
    assert(!mixer.isPoisoned(1));
    mixer.onVoiceFrame(1, 2, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Big seq jump: 20 - 2 = 18 > kPoisonThreshold (16). Poison.
    mixer.onVoiceFrame(1, 20, audio, kFrames);
    assert(mixer.isPoisoned(1));

    // Contiguous next frame recovers (21 - 20 = 1, well within threshold).
    mixer.onVoiceFrame(1, 21, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    std::cout << "Test Stuck Producer Prune: PASSED" << std::endl;
}

// Boundary: a frame exactly at lastSeq + kPoisonThreshold MUST NOT poison
// (the check is strictly `>`, so a 16-frame gap is the largest that still
// passes). One past that does. Locks the threshold semantics so a future
// drift in the constant gets caught.
void testPoisonThresholdBoundary() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 4;
    int16_t audio[kFrames] = {500, 500, 500, 500};

    // Establish lastSeq = 1.
    mixer.onVoiceFrame(1, 1, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // seq = 1 + kPoisonThreshold (= 17): inside the window, must not poison.
    mixer.onVoiceFrame(1, 1 + AudioMixer::kPoisonThreshold, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // seq = 17 + kPoisonThreshold + 1 (= 34): just past the window, must poison.
    mixer.onVoiceFrame(1, 17 + AudioMixer::kPoisonThreshold + 1, audio, kFrames);
    assert(mixer.isPoisoned(1));

    std::cout << "Test Poison Threshold Boundary: PASSED" << std::endl;
}

// Per-peer independence: poisoning one device must not affect another. Real
// rooms can have any subset of peers misbehaving at any given moment.
void testPoisonIsPerPeer() {
    AudioMixer mixer;
    mixer.addDevice(1);
    mixer.addDevice(2);

    const int kFrames = 4;
    int16_t audio[kFrames] = {2000, 2000, 2000, 2000};

    mixer.onVoiceFrame(1, 1, audio, kFrames);
    mixer.onVoiceFrame(2, 1, audio, kFrames);

    // Poison only device 1.
    mixer.onVoiceFrame(1, 100, audio, kFrames);
    assert(mixer.isPoisoned(1));
    assert(!mixer.isPoisoned(2));

    // Continue feeding device 2 normally — it stays healthy.
    mixer.onVoiceFrame(2, 2, audio, kFrames);
    mixer.onVoiceFrame(2, 3, audio, kFrames);
    assert(!mixer.isPoisoned(2));
    assert(mixer.isPoisoned(1));

    std::cout << "Test Poison Is Per-Peer: PASSED" << std::endl;
}

// First-frame edge case: lastSeq starts at 0, so the very first frame must
// always pass regardless of value. The protocol says peers start at seq=1
// but a fresh-session reset can land at any value; we trust the GATT join
// handshake to bound that.
void testFirstFrameAlwaysPasses() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 4;
    int16_t audio[kFrames] = {100, 100, 100, 100};

    // First frame at a high seq — should still pass.
    mixer.onVoiceFrame(1, 9999, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Now contiguous seq 10000 is fine (the high seq is the new baseline).
    mixer.onVoiceFrame(1, 10000, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    std::cout << "Test First Frame Always Passes: PASSED" << std::endl;
}

// Out-of-order or duplicate frames (delta <= 0 against the watermark) must
// be silently dropped: don't poison, don't update lastSeq, don't write audio.
// Without this rule a late-arriving older frame would lower the watermark
// and the *next* in-order frame would look like a giant jump and falsely
// poison the peer.
void testOutOfOrderDoesNotPoisonOrAdvance() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 4;
    int16_t audio[kFrames] = {500, 500, 500, 500};

    mixer.onVoiceFrame(1, 1, audio, kFrames);
    mixer.onVoiceFrame(1, 5, audio, kFrames);  // watermark = 5

    // Late arrival of an older seq must not poison.
    mixer.onVoiceFrame(1, 3, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Exact duplicate of the watermark must not poison either.
    mixer.onVoiceFrame(1, 5, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // The watermark must still be 5: a small forward jump (5 → 10) stays
    // within threshold. If the OOO frame had lowered it to 3, then 3 → 10
    // would still be within threshold — so prove the invariant a different
    // way: 5 → 22 is exactly 17 ahead and MUST poison; if the OOO frame
    // had lowered the watermark to 3, then 3 → 22 = 19 also poisons, so
    // that's not discriminating. Use the duplicate path instead: jump from
    // 5 by exactly kPoisonThreshold (= 16) → 21, which must NOT poison.
    mixer.onVoiceFrame(1, 5 + AudioMixer::kPoisonThreshold, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    std::cout << "Test Out-of-Order Does Not Poison Or Advance: PASSED" << std::endl;
}

// Recovery rule per [docs/protocol.md] § Voice frame format: "stops mixing
// that peer's stream until the next valid frame arrives." A valid frame is
// any frame within kPoisonThreshold of the (advanced-on-poison) watermark —
// it does NOT have to be strictly seq+1. A non-contiguous-but-within-threshold
// frame after poisoning recovers the peer, and a frame that is *itself* a
// big-jump keeps it poisoned. This test pins both behaviors.
void testRecoveryAcceptsAnyWithinThresholdFrame() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 4;
    int16_t audio[kFrames] = {100, 100, 100, 100};

    mixer.onVoiceFrame(1, 1, audio, kFrames);
    mixer.onVoiceFrame(1, 2, audio, kFrames);

    // Big jump: poison. Watermark advances to 20.
    mixer.onVoiceFrame(1, 20, audio, kFrames);
    assert(mixer.isPoisoned(1));

    // Another big jump while poisoned (20 → 40, gap 20 > 16) must keep the
    // peer poisoned and advance the watermark to 40.
    mixer.onVoiceFrame(1, 40, audio, kFrames);
    assert(mixer.isPoisoned(1));

    // Non-contiguous-but-within-threshold frame (40 → 50, gap 10 ≤ 16) must
    // recover. (The protocol's "next valid frame" rule, not "next contiguous".)
    mixer.onVoiceFrame(1, 50, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    std::cout << "Test Recovery Accepts Any Within-Threshold Frame: PASSED" << std::endl;
}

// uint32 wraparound. Comparison MUST be wrap-safe: a small forward jump
// across the rollover is normal flow, not a 4-billion-frame gap. Mirrors
// the same fix in production audio_mixer.cpp.
void testSeqWraparoundIsWrapSafe() {
    AudioMixer mixer;
    mixer.addDevice(1);

    const int kFrames = 4;
    int16_t audio[kFrames] = {100, 100, 100, 100};

    // Seed near rollover.
    mixer.onVoiceFrame(1, 0xFFFFFFF0u, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Tiny forward jump straight across uint32 max: gap of 1, must NOT poison.
    mixer.onVoiceFrame(1, 0xFFFFFFF1u, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Wrap forward: 0xFFFFFFF1 → 0x0 is exactly +15 modular, within threshold.
    mixer.onVoiceFrame(1, 0x0u, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Continue past the wrap: 0x0 → 0x5 is +5, normal.
    mixer.onVoiceFrame(1, 0x5u, audio, kFrames);
    assert(!mixer.isPoisoned(1));

    // Now a real big forward jump near the boundary should still poison.
    mixer.onVoiceFrame(1, 0x100u, audio, kFrames);  // +0xFB = 251
    assert(mixer.isPoisoned(1));

    std::cout << "Test Seq Wraparound Is Wrap-Safe: PASSED" << std::endl;
}

int main() {
    try {
        testMixMinus();
        testClipping();
        testMaxDevices();
        testStuckProducerPrune();
        testPoisonThresholdBoundary();
        testPoisonIsPerPeer();
        testFirstFrameAlwaysPasses();
        testOutOfOrderDoesNotPoisonOrAdvance();
        testRecoveryAcceptsAnyWithinThresholdFrame();
        testSeqWraparoundIsWrapSafe();
        std::cout << "All C++ Mixer tests passed!" << std::endl;
    } catch (const std::exception& e) {
        std::cerr << "Test failed with exception: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
