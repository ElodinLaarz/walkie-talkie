#include <iostream>
#include <vector>
#include <map>
#include <mutex>
#include <cstring>
#include <cassert>
#include <algorithm>

// Mock Android logging for standalone testing
#define LOGI(...) printf(__VA_ARGS__); printf("\n")

/**
 * AudioMixer implements the "Mix-Minus" routing logic.
 * Each device hears all other devices except themselves.
 */
class AudioMixer {
private:
    std::mutex mixerMutex;
    
    // Map of device ID to their audio buffers
    std::map<int, std::vector<int16_t>> deviceBuffers;
    
    // Maximum number of simultaneous devices
    static constexpr int kMaxDevices = 3;
    
public:
    // Add a device to the mixer
    bool addDevice(int deviceId) {
        std::lock_guard<std::mutex> lock(mixerMutex);
        
        if (deviceBuffers.size() >= kMaxDevices) {
            LOGI("Maximum devices reached (%d)", kMaxDevices);
            return false;
        }
        
        deviceBuffers[deviceId] = std::vector<int16_t>();
        LOGI("Device %d added to mixer", deviceId);
        return true;
    }
    
    // Remove a device from the mixer
    void removeDevice(int deviceId) {
        std::lock_guard<std::mutex> lock(mixerMutex);
        deviceBuffers.erase(deviceId);
        LOGI("Device %d removed from mixer", deviceId);
    }
    
    // Update audio data for a device
    void updateDeviceAudio(int deviceId, const int16_t* audioData, int numFrames) {
        std::lock_guard<std::mutex> lock(mixerMutex);
        
        auto it = deviceBuffers.find(deviceId);
        if (it != deviceBuffers.end()) {
            it->second.assign(audioData, audioData + numFrames);
        }
    }
    
    // Get mixed audio for a specific device (all others except this device)
    void getMixedAudioForDevice(int deviceId, int16_t* outputBuffer, int numFrames) {
        std::lock_guard<std::mutex> lock(mixerMutex);
        
        // Initialize output buffer to zero
        std::memset(outputBuffer, 0, numFrames * sizeof(int16_t));
        
        // Mix all devices except the target device
        for (const auto& [id, buffer] : deviceBuffers) {
            if (id != deviceId && !buffer.empty()) {
                int framesToMix = std::min(numFrames, static_cast<int>(buffer.size()));
                for (int i = 0; i < framesToMix; i++) {
                    // Simple mixing with clipping prevention
                    int32_t mixed = outputBuffer[i] + buffer[i];
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
        deviceBuffers.clear();
        LOGI("Mixer cleared");
    }

    // Helper for testing: get number of devices
    size_t getDeviceCount() {
        std::lock_guard<std::mutex> lock(mixerMutex);
        return deviceBuffers.size();
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

int main() {
    try {
        testMixMinus();
        testClipping();
        testMaxDevices();
        std::cout << "All C++ Mixer tests passed!" << std::endl;
    } catch (const std::exception& e) {
        std::cerr << "Test failed with exception: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
