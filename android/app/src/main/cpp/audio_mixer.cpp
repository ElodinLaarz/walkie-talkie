#include <jni.h>
#include <android/log.h>
#include <vector>
#include <map>
#include <mutex>
#include <cstring>

#define LOG_TAG "AudioMixer"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

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
};

// Global mixer instance
static AudioMixer* g_audioMixer = nullptr;

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
