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
    // production stuck-producer prune: a frame whose seq exceeds the previously
    // accepted seq by more than [kPoisonThreshold] is dropped and the peer is
    // marked poisoned; the next contiguous frame recovers.
    void onVoiceFrame(int deviceId, uint32_t seq, const int16_t* pcm, int numFrames) {
        std::lock_guard<std::mutex> lock(mixerMutex);

        auto it = devices.find(deviceId);
        if (it == devices.end()) {
            return;
        }
        DeviceState& s = it->second;

        const uint32_t prevSeq = s.lastSeq;
        if (prevSeq != 0 && seq > prevSeq + kPoisonThreshold) {
            s.poisoned = true;
            // Update lastSeq so the next contiguous frame can recover. Drop the
            // current frame's audio (do not write to s.buffer) — production
            // also avoids clearing the in-flight ring buffer here (SPSC contract).
            s.lastSeq = seq;
            LOGI("Device %d poisoned: seq jump %u -> %u", deviceId, prevSeq, seq);
            return;
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

int main() {
    try {
        testMixMinus();
        testClipping();
        testMaxDevices();
        testStuckProducerPrune();
        testPoisonThresholdBoundary();
        testPoisonIsPerPeer();
        testFirstFrameAlwaysPasses();
        std::cout << "All C++ Mixer tests passed!" << std::endl;
    } catch (const std::exception& e) {
        std::cerr << "Test failed with exception: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
