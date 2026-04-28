#ifndef AUDIO_MIXER_H
#define AUDIO_MIXER_H

#include <vector>
#include <map>
#include <mutex>
#include <atomic>
#include <memory>
#include <cstring>
#include <algorithm>
#include "ring_buffer.h"

// Per-device audio buffer with lock-free ring buffer for real-time safety
struct DeviceAudioBuffer {
    AudioRingBuffer ringBuffer;
    std::atomic<bool> active{true};  // Flag for stuck-producer detection (future use)
};

class AudioMixer {
private:
    // Device registry protected by mutex (rare changes: peer join/leave)
    std::mutex deviceRegistryMutex;
    std::map<int, std::shared_ptr<DeviceAudioBuffer>> devices;  // shared_ptr for safe concurrent access

    // Pre-allocated buffers for mixing (avoid heap allocations in audio path)
    std::vector<std::pair<int, std::shared_ptr<DeviceAudioBuffer>>> deviceSnapshotBuffer;
    std::vector<int16_t> tempMixBuffer;

    static constexpr int kMaxDevices = 8;  // Increased from 3 to support more peers
    static constexpr int kMaxFrames = 1024;  // Max frames for tempMixBuffer

public:
    AudioMixer();

    // Add a device (peer) to the mixer. Returns true on success.
    bool addDevice(int deviceId);

    // Remove a device from the mixer
    void removeDevice(int deviceId);

    // Update audio data for a device (called from L2CAP receive or mic capture).
    // Lock-free: writes to the device's ring buffer without blocking.
    void updateDeviceAudio(int deviceId, const int16_t* audioData, int numFrames);

    // Get mixed audio for a specific device (mix-minus: all others except this device).
    // Lock-free: reads from ring buffers without blocking.
    void getMixedAudioForDevice(int deviceId, int16_t* outputBuffer, int numFrames);

    // Clear all devices
    void clear();

    // Get list of active device IDs (for mixer tick thread)
    std::vector<int> getActiveDevices();
};

extern AudioMixer* g_audioMixer;

#endif // AUDIO_MIXER_H
