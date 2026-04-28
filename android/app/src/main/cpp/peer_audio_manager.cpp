#include "peer_audio_manager.h"
#include <android/log.h>
#include <chrono>
#include <thread>

#define LOG_TAG "PeerAudioManager"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

PeerAudioManager::PeerAudioManager() {
    LOGI("PeerAudioManager created");
}

PeerAudioManager::~PeerAudioManager() {
    stopMixerThread();
    clear();
    if (callbackObject && jvm) {
        JNIEnv* env = nullptr;
        if (jvm->GetEnv((void**)&env, JNI_VERSION_1_6) == JNI_OK) {
            env->DeleteGlobalRef(callbackObject);
        }
    }
}

int PeerAudioManager::registerPeer(const std::string& macAddress) {
    std::lock_guard<std::mutex> lock(peerRegistryMutex);

    // Check if already registered
    auto it = macToDeviceId.find(macAddress);
    if (it != macToDeviceId.end()) {
        LOGI("Peer %s already registered with device ID %d", macAddress.c_str(), it->second);
        return it->second;
    }

    // Assign new device ID
    int deviceId = nextDeviceId++;
    macToDeviceId[macAddress] = deviceId;
    deviceIdToMac[deviceId] = macAddress;

    // Add device to mixer
    if (g_audioMixer) {
        g_audioMixer->addDevice(deviceId);
    }

    // Create Opus encoder for this peer
    {
        std::lock_guard<std::mutex> encoderLock(encodersMutex);
        encoders[deviceId] = std::make_unique<::OpusEncoder>();
    }

    LOGI("Peer %s registered with device ID %d", macAddress.c_str(), deviceId);
    return deviceId;
}

void PeerAudioManager::unregisterPeer(const std::string& macAddress) {
    std::lock_guard<std::mutex> lock(peerRegistryMutex);

    auto it = macToDeviceId.find(macAddress);
    if (it == macToDeviceId.end()) {
        return;
    }

    int deviceId = it->second;

    // Remove from mixer
    if (g_audioMixer) {
        g_audioMixer->removeDevice(deviceId);
    }

    // Remove encoder
    {
        std::lock_guard<std::mutex> encoderLock(encodersMutex);
        encoders.erase(deviceId);
    }

    // Remove from maps
    deviceIdToMac.erase(deviceId);
    macToDeviceId.erase(macAddress);

    LOGI("Peer %s (device ID %d) unregistered", macAddress.c_str(), deviceId);
}

int PeerAudioManager::getDeviceId(const std::string& macAddress) {
    std::lock_guard<std::mutex> lock(peerRegistryMutex);
    auto it = macToDeviceId.find(macAddress);
    return (it != macToDeviceId.end()) ? it->second : -1;
}

std::string PeerAudioManager::getMacAddress(int deviceId) {
    std::lock_guard<std::mutex> lock(peerRegistryMutex);
    auto it = deviceIdToMac.find(deviceId);
    return (it != deviceIdToMac.end()) ? it->second : "";
}

bool PeerAudioManager::startMixerThread() {
    if (mixerRunning.load()) {
        LOGI("Mixer thread already running");
        return true;
    }

    mixerRunning.store(true);
    mixerThread = std::thread(&PeerAudioManager::mixerTickLoop, this);
    LOGI("Mixer thread started");
    return true;
}

void PeerAudioManager::stopMixerThread() {
    if (!mixerRunning.load()) {
        return;
    }

    mixerRunning.store(false);
    if (mixerThread.joinable()) {
        mixerThread.join();
    }
    LOGI("Mixer thread stopped");
}

void PeerAudioManager::mixerTickLoop() {
    LOGI("Mixer tick loop started");

    constexpr int kTickIntervalMs = 20;  // 20 ms ticks
    constexpr int kFrameSize = 320;      // 20 ms at 16 kHz
    std::vector<int16_t> mixedBuffer(kFrameSize);
    std::vector<uint8_t> opusBuffer(4000);  // Max Opus packet size
    std::map<int, uint32_t> seqNumbers;     // Per-peer sequence numbers

    auto nextTick = std::chrono::steady_clock::now();

    while (mixerRunning.load()) {
        auto now = std::chrono::steady_clock::now();

        if (now >= nextTick) {
            // Get list of active devices
            std::vector<int> deviceIds;
            std::vector<std::string> macAddresses;
            {
                std::lock_guard<std::mutex> lock(peerRegistryMutex);
                for (const auto& [mac, deviceId] : macToDeviceId) {
                    deviceIds.push_back(deviceId);
                    macAddresses.push_back(mac);
                }
            }

            // For each peer, generate mix-minus, encode, and send
            for (size_t i = 0; i < deviceIds.size(); i++) {
                int deviceId = deviceIds[i];
                const std::string& macAddress = macAddresses[i];

                // Get mixed audio for this device (all others except this one)
                if (g_audioMixer) {
                    g_audioMixer->getMixedAudioForDevice(deviceId, mixedBuffer.data(), kFrameSize);
                }

                // Encode with Opus
                ::OpusEncoder* encoder = nullptr;
                {
                    std::lock_guard<std::mutex> encoderLock(encodersMutex);
                    auto it = encoders.find(deviceId);
                    if (it != encoders.end()) {
                        encoder = it->second.get();
                    }
                }

                if (encoder) {
                    int encodedSize = encoder->encode(
                        mixedBuffer.data(), kFrameSize,
                        opusBuffer.data(), opusBuffer.size()
                    );

                    if (encodedSize > 0) {
                        // Get and increment sequence number
                        uint32_t seq = seqNumbers[deviceId]++;

                        // Send to peer via JNI callback
                        sendAudioToPeer(macAddress, opusBuffer.data(), encodedSize, seq);
                    }
                }
            }

            nextTick += std::chrono::milliseconds(kTickIntervalMs);
        }

        // Sleep until next tick (or a short time if we're behind)
        auto sleepDuration = nextTick - std::chrono::steady_clock::now();
        if (sleepDuration > std::chrono::milliseconds(0)) {
            std::this_thread::sleep_for(sleepDuration);
        }
    }

    LOGI("Mixer tick loop ended");
}

void PeerAudioManager::sendAudioToPeer(const std::string& macAddress, const uint8_t* opusData, int opusSize, uint32_t seq) {
    if (!jvm || !callbackObject) {
        return;
    }

    JNIEnv* env = nullptr;
    bool needDetach = false;

    if (jvm->GetEnv((void**)&env, JNI_VERSION_1_6) != JNI_OK) {
        if (jvm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
            LOGE("Failed to attach thread for audio send callback");
            return;
        }
        needDetach = true;
    }

    // Call callback method: void onMixedAudioReady(String macAddress, byte[] opusData, int seq)
    jclass callbackClass = env->GetObjectClass(callbackObject);
    if (callbackClass) {
        jmethodID method = env->GetMethodID(callbackClass, "onMixedAudioReady", "(Ljava/lang/String;[BI)V");
        if (method) {
            jstring jMacAddress = env->NewStringUTF(macAddress.c_str());
            jbyteArray jOpusData = env->NewByteArray(opusSize);
            env->SetByteArrayRegion(jOpusData, 0, opusSize, reinterpret_cast<const jbyte*>(opusData));

            env->CallVoidMethod(callbackObject, method, jMacAddress, jOpusData, static_cast<jint>(seq));

            env->DeleteLocalRef(jMacAddress);
            env->DeleteLocalRef(jOpusData);
        }
        env->DeleteLocalRef(callbackClass);
    }

    if (needDetach) {
        jvm->DetachCurrentThread();
    }
}

void PeerAudioManager::setCallback(JNIEnv* env, jobject callback) {
    if (callbackObject) {
        env->DeleteGlobalRef(callbackObject);
    }
    callbackObject = env->NewGlobalRef(callback);

    if (!jvm) {
        env->GetJavaVM(&jvm);
    }
    LOGI("JNI callback set");
}

void PeerAudioManager::clear() {
    std::lock_guard<std::mutex> lock(peerRegistryMutex);

    // Remove all devices from mixer
    if (g_audioMixer) {
        for (const auto& [_, deviceId] : macToDeviceId) {
            g_audioMixer->removeDevice(deviceId);
        }
    }

    // Clear encoders
    {
        std::lock_guard<std::mutex> encoderLock(encodersMutex);
        encoders.clear();
    }

    macToDeviceId.clear();
    deviceIdToMac.clear();
    nextDeviceId = 1;

    LOGI("PeerAudioManager cleared");
}

// Global instance
PeerAudioManager* g_peerAudioManager = nullptr;

// JNI methods
extern "C" {

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeInit(JNIEnv *env, jobject thiz) {
    if (g_peerAudioManager == nullptr) {
        g_peerAudioManager = new PeerAudioManager();
        LOGI("PeerAudioManager native initialized");
    }
}

JNIEXPORT jint JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeRegisterPeer(
        JNIEnv *env, jobject thiz, jstring macAddress) {
    if (!g_peerAudioManager) return -1;

    const char* mac = env->GetStringUTFChars(macAddress, nullptr);
    int deviceId = g_peerAudioManager->registerPeer(std::string(mac));
    env->ReleaseStringUTFChars(macAddress, mac);

    return deviceId;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeUnregisterPeer(
        JNIEnv *env, jobject thiz, jstring macAddress) {
    if (!g_peerAudioManager) return;

    const char* mac = env->GetStringUTFChars(macAddress, nullptr);
    g_peerAudioManager->unregisterPeer(std::string(mac));
    env->ReleaseStringUTFChars(macAddress, mac);
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeStartMixerThread(
        JNIEnv *env, jobject thiz) {
    if (!g_peerAudioManager) return JNI_FALSE;
    return g_peerAudioManager->startMixerThread() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeStopMixerThread(
        JNIEnv *env, jobject thiz) {
    if (g_peerAudioManager) {
        g_peerAudioManager->stopMixerThread();
    }
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeSetCallback(
        JNIEnv *env, jobject thiz, jobject callback) {
    if (g_peerAudioManager) {
        g_peerAudioManager->setCallback(env, callback);
    }
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeClear(JNIEnv *env, jobject thiz) {
    if (g_peerAudioManager) {
        g_peerAudioManager->clear();
        delete g_peerAudioManager;
        g_peerAudioManager = nullptr;
    }
}

// Method for receiving Opus frames from peers and feeding to mixer
JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeOnVoiceFrameReceived(
        JNIEnv *env, jobject thiz, jstring macAddress, jbyteArray opusData) {
    if (!g_peerAudioManager || !g_audioMixer) return;

    const char* mac = env->GetStringUTFChars(macAddress, nullptr);
    int deviceId = g_peerAudioManager->getDeviceId(std::string(mac));
    env->ReleaseStringUTFChars(macAddress, mac);

    if (deviceId < 0) {
        LOGE("Received voice frame from unregistered peer");
        return;
    }

    // Decode Opus
    static ::OpusDecoder decoder;  // One decoder can handle all peers (stateless for different streams)

    jsize encodedSize = env->GetArrayLength(opusData);
    jbyte* encodedBuffer = env->GetByteArrayElements(opusData, nullptr);

    int16_t pcmBuffer[960];  // Max frame size for Opus
    int numSamples = decoder.decode(
        reinterpret_cast<const uint8_t*>(encodedBuffer), encodedSize,
        pcmBuffer, 960
    );

    env->ReleaseByteArrayElements(opusData, encodedBuffer, JNI_ABORT);

    if (numSamples > 0) {
        // Feed to mixer
        g_audioMixer->updateDeviceAudio(deviceId, pcmBuffer, numSamples);
    }
}

} // extern "C"
