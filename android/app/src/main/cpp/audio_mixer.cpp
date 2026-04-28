#include <jni.h>
#include <android/log.h>
#include "audio_mixer.h"

#define LOG_TAG "AudioMixer"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

// Implementation of AudioMixer methods
bool AudioMixer::addDevice(int deviceId) {
    std::lock_guard<std::mutex> lock(deviceRegistryMutex);
    if (devices.size() >= kMaxDevices) {
        LOGI("Maximum devices reached (%d)", kMaxDevices);
        return false;
    }
    if (devices.find(deviceId) != devices.end()) {
        LOGI("Device %d already exists", deviceId);
        return false;
    }
    devices[deviceId] = std::make_unique<DeviceAudioBuffer>();
    LOGI("Device %d added to mixer", deviceId);
    return true;
}

void AudioMixer::removeDevice(int deviceId) {
    std::lock_guard<std::mutex> lock(deviceRegistryMutex);
    devices.erase(deviceId);
    LOGI("Device %d removed from mixer", deviceId);
}

void AudioMixer::updateDeviceAudio(int deviceId, const int16_t* audioData, int numFrames) {
    // Lock-free: find the device without locking the registry
    // (assumes device pointers remain stable, which they do with std::unique_ptr in std::map)
    DeviceAudioBuffer* device = nullptr;
    {
        std::lock_guard<std::mutex> lock(deviceRegistryMutex);
        auto it = devices.find(deviceId);
        if (it != devices.end()) {
            device = it->second.get();
        }
    }

    if (device) {
        // Lock-free write to ring buffer
        size_t written = device->ringBuffer.write(audioData, numFrames);
        if (written < numFrames) {
            // Buffer full or near-full (normal during startup or if mixer tick is slow)
            // Don't log on every occurrence to avoid spam
        }
    }
}

void AudioMixer::getMixedAudioForDevice(int deviceId, int16_t* outputBuffer, int numFrames) {
    std::memset(outputBuffer, 0, numFrames * sizeof(int16_t));

    // Get device list snapshot
    std::vector<std::pair<int, DeviceAudioBuffer*>> deviceSnapshot;
    {
        std::lock_guard<std::mutex> lock(deviceRegistryMutex);
        for (const auto& [id, buffer] : devices) {
            if (id != deviceId && buffer) {
                deviceSnapshot.push_back({id, buffer.get()});
            }
        }
    }

    // Mix all other devices (lock-free reads from ring buffers)
    std::vector<int16_t> tempBuffer(numFrames);
    for (const auto& [id, device] : deviceSnapshot) {
        if (!device) continue;

        size_t read = device->ringBuffer.peek(tempBuffer.data(), numFrames);
        if (read > 0) {
            // Mix this device's audio into the output
            for (size_t i = 0; i < read; i++) {
                int32_t mixed = static_cast<int32_t>(outputBuffer[i]) + static_cast<int32_t>(tempBuffer[i]);
                // Clamp to int16_t range
                outputBuffer[i] = static_cast<int16_t>(
                    std::max<int32_t>(-32768, std::min<int32_t>(32767, mixed))
                );
            }
        }
    }
}

void AudioMixer::clear() {
    std::lock_guard<std::mutex> lock(deviceRegistryMutex);
    devices.clear();
    LOGI("Mixer cleared");
}

std::vector<int> AudioMixer::getActiveDevices() {
    std::vector<int> activeDevices;
    std::lock_guard<std::mutex> lock(deviceRegistryMutex);
    for (const auto& [id, _] : devices) {
        activeDevices.push_back(id);
    }
    return activeDevices;
}

// Global mixer instance
AudioMixer* g_audioMixer = nullptr;

extern "C" {

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioMixerManager_nativeInit(JNIEnv *env, jobject thiz) {
    if (g_audioMixer == nullptr) {
        g_audioMixer = new AudioMixer();
        LOGI("Audio mixer initialized");
    }
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioMixerManager_nativeAddDevice(
        JNIEnv *env, jobject thiz, jint deviceId) {
    if (g_audioMixer == nullptr) {
        return JNI_FALSE;
    }
    return g_audioMixer->addDevice(deviceId) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioMixerManager_nativeRemoveDevice(
        JNIEnv *env, jobject thiz, jint deviceId) {
    if (g_audioMixer != nullptr) {
        g_audioMixer->removeDevice(deviceId);
    }
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioMixerManager_nativeUpdateDeviceAudio(
        JNIEnv *env, jobject thiz, jint deviceId, jshortArray audioData) {
    if (g_audioMixer == nullptr) {
        return;
    }
    jsize length = env->GetArrayLength(audioData);
    jshort* buffer = env->GetShortArrayElements(audioData, nullptr);
    g_audioMixer->updateDeviceAudio(deviceId, buffer, length);
    env->ReleaseShortArrayElements(audioData, buffer, JNI_ABORT);
}

JNIEXPORT jshortArray JNICALL
Java_com_elodin_walkie_1talkie_AudioMixerManager_nativeGetMixedAudio(
        JNIEnv *env, jobject thiz, jint deviceId, jint numFrames) {
    if (g_audioMixer == nullptr) {
        return nullptr;
    }
    jshortArray result = env->NewShortArray(numFrames);
    jshort* buffer = env->GetShortArrayElements(result, nullptr);
    g_audioMixer->getMixedAudioForDevice(deviceId, buffer, numFrames);
    env->ReleaseShortArrayElements(result, buffer, 0);
    return result;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioMixerManager_nativeClear(JNIEnv *env, jobject thiz) {
    if (g_audioMixer != nullptr) {
        g_audioMixer->clear();
        delete g_audioMixer;
        g_audioMixer = nullptr;
    }
}

} // extern "C"