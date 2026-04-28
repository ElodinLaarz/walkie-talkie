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
    std::map<int, std::unique_ptr<DeviceAudioBuffer>> devices;

    static constexpr int kMaxDevices = 8;  // Increased from 3 to support more peers

public:
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
