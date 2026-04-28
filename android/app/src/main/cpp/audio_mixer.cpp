#include <jni.h>
#include <android/log.h>
#include "audio_mixer.h"

#define LOG_TAG "AudioMixer"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

// Constructor (if needed - add to header too)
AudioMixer::AudioMixer() {
    // Pre-allocate buffers
    deviceSnapshotBuffer.reserve(kMaxDevices);
    tempMixBuffer.resize(kMaxFrames);
}

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
    devices[deviceId] = std::make_shared<DeviceAudioBuffer>();
    LOGI("Device %d added to mixer", deviceId);
    return true;
}

void AudioMixer::removeDevice(int deviceId) {
    std::lock_guard<std::mutex> lock(deviceRegistryMutex);
    devices.erase(deviceId);
    LOGI("Device %d removed from mixer", deviceId);
}

void AudioMixer::updateDeviceAudio(int deviceId, const int16_t* audioData, int numFrames) {
    // Get shared_ptr to device (keeps it alive even if removed concurrently)
    std::shared_ptr<DeviceAudioBuffer> device;
    {
        std::lock_guard<std::mutex> lock(deviceRegistryMutex);
        auto it = devices.find(deviceId);
        if (it != devices.end()) {
            device = it->second;  // Copy shared_ptr (atomic ref count increment)
        }
    }
    // Mutex released - now lock-free

    if (device) {
        // Lock-free write to ring buffer
        size_t written = device->ringBuffer.write(audioData, static_cast<size_t>(numFrames));
        if (written < static_cast<size_t>(numFrames)) {
            // Buffer full or near-full (normal during startup or if mixer tick is slow)
            // Don't log on every occurrence to avoid spam
        }
    }
}

void AudioMixer::onVoiceFrame(int deviceId, uint32_t seq, const int16_t* pcm, int numFrames) {
    std::shared_ptr<DeviceAudioBuffer> device;
    {
        std::lock_guard<std::mutex> lock(deviceRegistryMutex);
        auto it = devices.find(deviceId);
        if (it != devices.end()) {
            device = it->second;
        }
    }
    if (!device) {
        return;
    }

    const uint32_t prevSeq = device->lastSeq;

    // First frame from this peer always passes regardless of value: a
    // fresh-session reset can land at any high seq, and the GATT join
    // handshake bounds when the first frame is allowed to arrive. We use a
    // dedicated `hasSeenSeq` flag rather than `prevSeq != 0` because seq is
    // uint32 and a legitimate wrap to 0 must not look like "unseen" to the
    // next frame.
    if (device->hasSeenSeq) {
        // Wrap-safe forward delta: cast the unsigned subtraction to int32_t.
        // - diff > 0 and small  → in-order, normal flow
        // - diff > kPoisonThreshold → big forward jump, poison
        // - diff <= 0 → out-of-order or duplicate (older seq, or same seq)
        //
        // Using signed int32 here is what makes the comparison wrap-safe:
        // near uint32 rollover the unsigned `prevSeq + 16` would overflow,
        // but `static_cast<int32_t>(seq - prevSeq)` is the modular distance
        // interpreted as signed, which is correct for any pair within ±2^31.
        const int32_t diff = static_cast<int32_t>(seq - prevSeq);

        if (diff <= 0) {
            // Out-of-order or duplicate. Don't poison, don't write, don't
            // touch lastSeq — the existing watermark stays authoritative.
            return;
        }

        if (diff > static_cast<int32_t>(kPoisonThreshold)) {
            if (!device->poisoned.exchange(true, std::memory_order_relaxed)) {
                LOGW("Device %d poisoned: seq jump %u -> %u (gap %d > %u)",
                     deviceId, prevSeq, seq, diff, kPoisonThreshold);
            }
            // Advance lastSeq so the next valid frame within the threshold
            // recovers. Drop the current frame's audio: we don't trust it,
            // and the ring buffer's SPSC contract forbids producer-side
            // `clear()` while the mixer-tick consumer is reading. Any
            // in-flight buffered samples drain naturally over the next tick.
            device->lastSeq = seq;
            // hasSeenSeq is already true here (we're inside the `if`).
            return;
        }
    }

    if (device->poisoned.exchange(false, std::memory_order_relaxed)) {
        LOGI("Device %d recovered at seq %u (prevSeq %u)", deviceId, seq, prevSeq);
    }

    device->ringBuffer.write(pcm, static_cast<size_t>(numFrames));
    device->lastSeq = seq;
    device->hasSeenSeq = true;
}

bool AudioMixer::isPoisoned(int deviceId) {
    std::shared_ptr<DeviceAudioBuffer> device;
    {
        std::lock_guard<std::mutex> lock(deviceRegistryMutex);
        auto it = devices.find(deviceId);
        if (it != devices.end()) {
            device = it->second;
        }
    }
    return device && device->poisoned.load(std::memory_order_relaxed);
}

void AudioMixer::getMixedAudioForDevice(int deviceId, int16_t* outputBuffer, int numFrames) {
    std::memset(outputBuffer, 0, numFrames * sizeof(int16_t));

    // Get device list snapshot using pre-allocated buffer
    deviceSnapshotBuffer.clear();
    {
        std::lock_guard<std::mutex> lock(deviceRegistryMutex);
        for (const auto& [id, buffer] : devices) {
            if (id != deviceId && buffer) {
                deviceSnapshotBuffer.push_back({id, buffer});  // Copy shared_ptr
            }
        }
    }

    // Mix all other devices using pre-allocated temp buffer
    for (const auto& [id, device] : deviceSnapshotBuffer) {
        if (!device) continue;

        // Use read() to consume the data from the ring buffer
        size_t samplesRead = device->ringBuffer.read(tempMixBuffer.data(), std::min(numFrames, kMaxFrames));
        if (samplesRead > 0) {
            // Mix this device's audio into the output
            for (size_t i = 0; i < samplesRead; i++) {
                int32_t mixed = static_cast<int32_t>(outputBuffer[i]) + static_cast<int32_t>(tempMixBuffer[i]);
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