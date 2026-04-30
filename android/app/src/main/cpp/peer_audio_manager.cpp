#include "peer_audio_manager.h"

#include <android/log.h>

#include <chrono>
#include <thread>
#include <utility>

#define LOG_TAG "PeerAudioManager"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

PeerAudioManager::PeerAudioManager() { LOGI("PeerAudioManager created"); }

PeerAudioManager::~PeerAudioManager() {
    stopMixerThread();
    clear();
    if (jvm_) {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        if (callbackObject_) {
            JNIEnv* env = nullptr;
            if (jvm_->GetEnv(reinterpret_cast<void**>(&env),
                             JNI_VERSION_1_6) == JNI_OK) {
                env->DeleteGlobalRef(callbackObject_);
            }
            callbackObject_ = nullptr;
        }
    }
}

int PeerAudioManager::registerPeer(const std::string& macAddress) {
    std::lock_guard<std::mutex> lock(peerRegistryMutex_);

    auto it = peers_.find(macAddress);
    if (it != peers_.end()) {
        LOGI("Peer %s already registered with device ID %d", macAddress.c_str(),
             it->second->deviceId);
        return it->second->deviceId;
    }

    auto state = std::make_shared<PeerState>();
    state->deviceId = nextDeviceId_++;
    state->encoder = std::make_unique<OpusEncoder>();
    state->decoder = std::make_unique<OpusDecoder>();
    state->jitterBuffer = std::make_unique<JitterBuffer>();
    state->bitrate.store(audio_config::kDefaultBitrate,
                         std::memory_order_relaxed);

    if (g_audioMixer) {
        g_audioMixer->addDevice(state->deviceId);
    }

    deviceIdToMac_[state->deviceId] = macAddress;
    LOGI("Peer %s registered with device ID %d", macAddress.c_str(),
         state->deviceId);
    int id = state->deviceId;
    peers_[macAddress] = std::move(state);
    return id;
}

void PeerAudioManager::unregisterPeer(const std::string& macAddress) {
    std::lock_guard<std::mutex> lock(peerRegistryMutex_);

    auto it = peers_.find(macAddress);
    if (it == peers_.end()) {
        return;
    }
    int deviceId = it->second->deviceId;

    if (g_audioMixer) {
        g_audioMixer->removeDevice(deviceId);
    }

    deviceIdToMac_.erase(deviceId);
    peers_.erase(it);
    LOGI("Peer %s (device ID %d) unregistered", macAddress.c_str(), deviceId);
}

int PeerAudioManager::getDeviceId(const std::string& macAddress) {
    std::lock_guard<std::mutex> lock(peerRegistryMutex_);
    auto it = peers_.find(macAddress);
    return (it != peers_.end()) ? it->second->deviceId : -1;
}

std::string PeerAudioManager::getMacAddress(int deviceId) {
    std::lock_guard<std::mutex> lock(peerRegistryMutex_);
    auto it = deviceIdToMac_.find(deviceId);
    return (it != deviceIdToMac_.end()) ? it->second : std::string{};
}

bool PeerAudioManager::onVoiceFramePushed(const std::string& macAddress,
                                          uint32_t seq, const uint8_t* opusData,
                                          int opusSize) {
    std::shared_ptr<PeerState> state;
    {
        std::lock_guard<std::mutex> lock(peerRegistryMutex_);
        auto it = peers_.find(macAddress);
        if (it == peers_.end()) {
            return false;
        }
        state = it->second;  // shared_ptr keeps state alive past unlock.
    }
    // JitterBuffer is not thread-safe; we serialize against the mixer
    // thread's tick/pop here.
    std::lock_guard<std::mutex> stateLock(state->mutex);
    return state->jitterBuffer->push(seq, opusData,
                                     static_cast<size_t>(opusSize));
}

int PeerAudioManager::setPeerBitrate(const std::string& macAddress, int bps) {
    std::shared_ptr<PeerState> state;
    {
        std::lock_guard<std::mutex> lock(peerRegistryMutex_);
        auto it = peers_.find(macAddress);
        if (it == peers_.end()) {
            return -1;
        }
        state = it->second;
    }
    // OpusEncoder is not safe to ctl while another thread calls encode();
    // serialize against the mixer-thread encode pass via the per-peer mutex.
    int applied;
    {
        std::lock_guard<std::mutex> stateLock(state->mutex);
        applied = state->encoder->setBitrate(bps);
    }
    state->bitrate.store(applied, std::memory_order_relaxed);
    return applied;
}

PeerAudioManager::LinkTelemetry PeerAudioManager::getTelemetry(
    const std::string& macAddress) {
    LinkTelemetry t;
    std::shared_ptr<PeerState> state;
    {
        std::lock_guard<std::mutex> lock(peerRegistryMutex_);
        auto it = peers_.find(macAddress);
        if (it == peers_.end()) {
            return t;  // valid = false
        }
        state = it->second;
    }
    // JitterBuffer counters are non-atomic; lock to read them coherently.
    {
        std::lock_guard<std::mutex> stateLock(state->mutex);
        t.underrunCount =
            static_cast<uint32_t>(state->jitterBuffer->underrunCount());
        t.lateFrameCount =
            static_cast<uint32_t>(state->jitterBuffer->lateFrameCount());
        t.jitterTargetDepth =
            static_cast<uint32_t>(state->jitterBuffer->targetDepth());
        t.jitterCurrentDepth =
            static_cast<uint32_t>(state->jitterBuffer->currentDepth());
    }
    t.currentBitrate = state->bitrate.load(std::memory_order_relaxed);
    t.valid = true;
    return t;
}

bool PeerAudioManager::startMixerThread() {
    if (mixerRunning_.load()) {
        LOGI("Mixer thread already running");
        return true;
    }
    mixerRunning_.store(true);
    mixerThread_ = std::thread(&PeerAudioManager::mixerTickLoop, this);
    LOGI("Mixer thread started");
    return true;
}

void PeerAudioManager::stopMixerThread() {
    if (!mixerRunning_.load()) {
        return;
    }
    mixerRunning_.store(false);
    if (mixerThread_.joinable()) {
        mixerThread_.join();
    }
    LOGI("Mixer thread stopped");
}

void PeerAudioManager::mixerTickLoop() {
    LOGI("Mixer tick loop started");

    constexpr int kFrameSize = audio_config::kCodecFrameSize;

    // Per-thread JVM attachment. The thread runs at 50 Hz × N peers, so we
    // do the attach once and reuse the JNIEnv — per-call attach/detach is
    // wasteful and adds jitter to the mixer loop.
    //
    // **Lazy:** if startMixerThread() runs before setCallback() publishes
    // jvm_, we'd otherwise stay unattached forever. We retry the attach on
    // each tick where `env` is still null AND `jvm_` is now available.
    // Once attached, the JNIEnv is stable for the thread's lifetime; we
    // detach exactly once on loop exit if we attached at all.
    JNIEnv* env = nullptr;
    bool attached = false;

    // Pre-allocate scratch — the mixer thread runs every 20 ms, so the cost
    // of a tick matters more than memory.
    std::vector<int16_t> decodedBuffer(audio_config::kCodecMaxFrameSize);
    std::vector<int16_t> mixedBuffer(kFrameSize);
    std::vector<uint8_t> opusBuffer(audio_config::kMaxOpusPacketSize);

    // Snapshot of active peers, filled from peerRegistryMutex_-guarded state
    // once per tick to avoid holding the lock through the heavier work.
    std::vector<std::shared_ptr<PeerState>> peerSnapshot;
    std::vector<std::string> macSnapshot;
    peerSnapshot.reserve(audio_config::kJitterMaxDepth);
    macSnapshot.reserve(audio_config::kJitterMaxDepth);

    // Mix-minus output uses a per-peer monotonically-increasing seq, separate
    // from the per-peer recv seq tracked inside the jitter buffer. Stays here
    // (locally to the loop) because it's only meaningful while the thread is
    // alive — a re-start of the mixer thread legitimately re-zeros it.
    std::map<int, uint32_t> outboundSeq;

    auto nextTick = std::chrono::steady_clock::now();

    while (mixerRunning_.load()) {
        const auto now = std::chrono::steady_clock::now();
        if (now < nextTick) {
            std::this_thread::sleep_for(nextTick - now);
            continue;
        }

        // Lazy JNI attach. If setCallback() hadn't yet been called when the
        // thread started, jvm_ was null and we couldn't attach. Try again
        // on each tick until we succeed; before that, encoded frames are
        // produced but `sendAudioToPeer` skips the JNI call (no callback to
        // hand them to anyway). On a healthy boot sequence this branch
        // succeeds on the very first tick.
        if (env == nullptr && jvm_ != nullptr) {
            if (jvm_->GetEnv(reinterpret_cast<void**>(&env),
                             JNI_VERSION_1_6) != JNI_OK) {
                if (jvm_->AttachCurrentThread(&env, nullptr) == JNI_OK) {
                    attached = true;
                } else {
                    LOGE("mixerTickLoop: AttachCurrentThread failed; will "
                         "retry next tick");
                    env = nullptr;
                }
            }
        }

        peerSnapshot.clear();
        macSnapshot.clear();
        {
            std::lock_guard<std::mutex> lock(peerRegistryMutex_);
            for (const auto& [mac, state] : peers_) {
                peerSnapshot.push_back(state);
                macSnapshot.push_back(mac);
            }
        }

        // ---- Decode pass: drain each peer's jitter buffer by one frame and
        // feed the decoded PCM into the mixer's per-peer ring. Underruns
        // produce one frame of PLC instead of stalling.
        //
        // We hand the BLE-arrived audio to AudioMixer::updateDeviceAudio
        // rather than AudioMixer::onVoiceFrame: the jitter buffer already
        // enforces in-order, deduped delivery, so the mixer's seq-based
        // stuck-producer poison logic would never fire. Skipping it avoids
        // duplicating the gap detection that the buffer + this loop's PLC
        // path already handle.
        for (size_t i = 0; i < peerSnapshot.size(); ++i) {
            auto& state = peerSnapshot[i];
            int decoded = -1;
            // Hold the per-peer lock across jitter-buffer + decoder use.
            // The decoder is touched only on this thread, so the lock is
            // really there to serialize the jitter buffer (push side runs
            // on the BLE thread).
            std::lock_guard<std::mutex> stateLock(state->mutex);
            state->jitterBuffer->tick();

            auto frame = state->jitterBuffer->pop();
            if (frame.has_value()) {
                decoded = state->decoder->decode(
                    frame->opusData.data(),
                    static_cast<int>(frame->opusData.size()),
                    decodedBuffer.data(),
                    audio_config::kCodecMaxFrameSize);
                state->consecutiveUnderruns = 0;
            } else {
                // Underrun. PLC for one frame; if we've already PLC'd twice in
                // a row, prefer popAny() so the buffer doesn't grow stale.
                if (state->consecutiveUnderruns >= 2) {
                    auto any = state->jitterBuffer->popAny();
                    if (any.has_value()) {
                        decoded = state->decoder->decode(
                            any->opusData.data(),
                            static_cast<int>(any->opusData.size()),
                            decodedBuffer.data(),
                            audio_config::kCodecMaxFrameSize);
                        state->consecutiveUnderruns = 0;
                    }
                }
                if (decoded < 0) {
                    decoded = state->decoder->decodeMissing(
                        decodedBuffer.data(), kFrameSize);
                    ++state->consecutiveUnderruns;
                }
            }

            if (decoded > 0 && g_audioMixer) {
                g_audioMixer->updateDeviceAudio(state->deviceId,
                                                decodedBuffer.data(), decoded);
            }
        }

        // ---- Mix-minus + encode pass: produce one outbound frame per peer.
        for (size_t i = 0; i < peerSnapshot.size(); ++i) {
            auto& state = peerSnapshot[i];
            const std::string& mac = macSnapshot[i];

            if (g_audioMixer) {
                g_audioMixer->getMixedAudioForDevice(
                    state->deviceId, mixedBuffer.data(), kFrameSize);
            } else {
                std::fill(mixedBuffer.begin(), mixedBuffer.end(), 0);
            }

            // Encoder ctl (`setBitrate`) and encode() race on the OpusEncoder
            // handle; the per-peer mutex serializes them.
            int encodedSize;
            {
                std::lock_guard<std::mutex> stateLock(state->mutex);
                encodedSize = state->encoder->encode(
                    mixedBuffer.data(), kFrameSize, opusBuffer.data(),
                    static_cast<int>(opusBuffer.size()));
            }
            if (encodedSize > 0 && env != nullptr) {
                uint32_t seq = outboundSeq[state->deviceId]++;
                sendAudioToPeer(env, mac, opusBuffer.data(), encodedSize, seq);
            }
        }

        nextTick += std::chrono::milliseconds(audio_config::kMixerTickIntervalMs);
        // If we fell behind by more than a tick (e.g. a long stop-the-world
        // GC on the JVM side), don't try to catch up — re-anchor to "now".
        // Catching up just produces a burst of frames that a healthy peer
        // would interpret as a seq jump and the unhealthy peer is already
        // poisoned by the protocol's stuck-producer rule.
        const auto drift = std::chrono::steady_clock::now() - nextTick;
        if (drift > std::chrono::milliseconds(
                        audio_config::kMixerTickIntervalMs * 2)) {
            LOGW("Mixer tick fell behind by %lld ms; re-anchoring",
                 static_cast<long long>(
                     std::chrono::duration_cast<std::chrono::milliseconds>(drift)
                         .count()));
            nextTick = std::chrono::steady_clock::now();
        }
    }

    if (attached && jvm_) {
        jvm_->DetachCurrentThread();
    }

    LOGI("Mixer tick loop ended");
}

void PeerAudioManager::sendAudioToPeer(JNIEnv* env,
                                        const std::string& macAddress,
                                        const uint8_t* opusData, int opusSize,
                                        uint32_t seq) {
    if (!env) {
        return;
    }

    // Snapshot the global ref under callbackMutex_ into a local ref. This
    // rules out the race where setCallback (JNI thread) calls
    // DeleteGlobalRef while we're mid-CallVoidMethod on the mixer thread.
    // The local ref is independent of the global; it survives even if the
    // global is concurrently swapped or deleted.
    jobject callback = nullptr;
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        if (callbackObject_) {
            callback = env->NewLocalRef(callbackObject_);
        }
    }
    if (!callback) {
        return;
    }

    jclass callbackClass = env->GetObjectClass(callback);
    if (callbackClass) {
        jmethodID method = env->GetMethodID(callbackClass, "onMixedAudioReady",
                                            "(Ljava/lang/String;[BI)V");
        if (method) {
            jstring jMac = env->NewStringUTF(macAddress.c_str());
            jbyteArray jData = env->NewByteArray(opusSize);
            env->SetByteArrayRegion(jData, 0, opusSize,
                                    reinterpret_cast<const jbyte*>(opusData));

            env->CallVoidMethod(callback, method, jMac, jData,
                                static_cast<jint>(seq));

            // Defensive: clear any pending exception from the Java callback
            // so the next JNI call doesn't trip an assert. The protocol
            // contract is that the callback returns void without throwing,
            // but we shouldn't crash the foreground service if Kotlin code
            // throws unexpectedly.
            if (env->ExceptionCheck()) {
                env->ExceptionDescribe();
                env->ExceptionClear();
            }

            env->DeleteLocalRef(jMac);
            env->DeleteLocalRef(jData);
        }
        env->DeleteLocalRef(callbackClass);
    }
    env->DeleteLocalRef(callback);
}

void PeerAudioManager::setCallback(JNIEnv* env, jobject callback) {
    if (!jvm_) {
        env->GetJavaVM(&jvm_);
    }
    std::lock_guard<std::mutex> lock(callbackMutex_);
    if (callbackObject_) {
        env->DeleteGlobalRef(callbackObject_);
    }
    callbackObject_ = env->NewGlobalRef(callback);
    LOGI("JNI callback set");
}

void PeerAudioManager::clear() {
    // Order matters: stop the mixer thread BEFORE tearing down peers, or the
    // tick loop will dereference state we've already freed.
    stopMixerThread();

    std::lock_guard<std::mutex> lock(peerRegistryMutex_);
    if (g_audioMixer) {
        for (const auto& [mac, state] : peers_) {
            g_audioMixer->removeDevice(state->deviceId);
        }
    }
    peers_.clear();
    deviceIdToMac_.clear();
    nextDeviceId_ = 1;
    LOGI("PeerAudioManager cleared");
}

PeerAudioManager* g_peerAudioManager = nullptr;

// Serializes JNI entrypoints against `nativeClear`, which can delete the
// singleton from one thread while another is mid-call. Mirrors the
// g_engineMutex pattern in audio_engine.cpp. The mixer thread itself runs
// without taking this mutex — it only ever uses snapshots of the manager's
// internal state, so once the manager is alive long enough to start the
// thread, the thread can safely outlive any JNI race.
static std::mutex g_peerManagerMutex;

extern "C" {

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeInit(JNIEnv* env,
                                                            jobject thiz) {
    std::lock_guard<std::mutex> lock(g_peerManagerMutex);
    if (g_peerAudioManager == nullptr) {
        g_peerAudioManager = new PeerAudioManager();
        LOGI("PeerAudioManager native initialized");
    }
}

JNIEXPORT jint JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeRegisterPeer(
    JNIEnv* env, jobject thiz, jstring macAddress) {
    std::lock_guard<std::mutex> lock(g_peerManagerMutex);
    if (!g_peerAudioManager) return -1;
    const char* mac = env->GetStringUTFChars(macAddress, nullptr);
    int id = g_peerAudioManager->registerPeer(std::string(mac));
    env->ReleaseStringUTFChars(macAddress, mac);
    return id;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeUnregisterPeer(
    JNIEnv* env, jobject thiz, jstring macAddress) {
    std::lock_guard<std::mutex> lock(g_peerManagerMutex);
    if (!g_peerAudioManager) return;
    const char* mac = env->GetStringUTFChars(macAddress, nullptr);
    g_peerAudioManager->unregisterPeer(std::string(mac));
    env->ReleaseStringUTFChars(macAddress, mac);
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeStartMixerThread(
    JNIEnv* env, jobject thiz) {
    std::lock_guard<std::mutex> lock(g_peerManagerMutex);
    if (!g_peerAudioManager) return JNI_FALSE;
    return g_peerAudioManager->startMixerThread() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeStopMixerThread(
    JNIEnv* env, jobject thiz) {
    std::lock_guard<std::mutex> lock(g_peerManagerMutex);
    if (g_peerAudioManager) {
        g_peerAudioManager->stopMixerThread();
    }
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeSetCallback(
    JNIEnv* env, jobject thiz, jobject callback) {
    std::lock_guard<std::mutex> lock(g_peerManagerMutex);
    if (g_peerAudioManager) {
        g_peerAudioManager->setCallback(env, callback);
    }
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeClear(JNIEnv* env,
                                                             jobject thiz) {
    std::lock_guard<std::mutex> lock(g_peerManagerMutex);
    if (g_peerAudioManager) {
        g_peerAudioManager->clear();
        delete g_peerAudioManager;
        g_peerAudioManager = nullptr;
    }
}

// Push a peer-arrived Opus frame into the peer's jitter buffer. `seq` is the
// per-link uint32 from the VoiceFrame header; arrives as `jlong` so the
// unsigned value survives the JNI hop without sign extension. Range-checking
// happens on the Kotlin side (PeerAudioManager.kt:69); this function trusts
// its input.
JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeOnVoiceFrameReceived(
    JNIEnv* env, jobject thiz, jstring macAddress, jbyteArray opusData,
    jlong seq) {
    std::lock_guard<std::mutex> lock(g_peerManagerMutex);
    if (!g_peerAudioManager) return;
    const char* mac = env->GetStringUTFChars(macAddress, nullptr);
    jsize size = env->GetArrayLength(opusData);
    jbyte* buf = env->GetByteArrayElements(opusData, nullptr);

    g_peerAudioManager->onVoiceFramePushed(
        std::string(mac), static_cast<uint32_t>(seq),
        reinterpret_cast<const uint8_t*>(buf), static_cast<int>(size));

    env->ReleaseByteArrayElements(opusData, buf, JNI_ABORT);
    env->ReleaseStringUTFChars(macAddress, mac);
}

JNIEXPORT jint JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeSetPeerBitrate(
    JNIEnv* env, jobject thiz, jstring macAddress, jint bps) {
    std::lock_guard<std::mutex> lock(g_peerManagerMutex);
    if (!g_peerAudioManager) return -1;
    const char* mac = env->GetStringUTFChars(macAddress, nullptr);
    int applied = g_peerAudioManager->setPeerBitrate(std::string(mac), bps);
    env->ReleaseStringUTFChars(macAddress, mac);
    return applied;
}

// Returns a 5-element int array with telemetry, or null if peer not found.
// Layout: [underrunCount, lateFrameCount, jitterTargetDepth,
//          jitterCurrentDepth, currentBitrate]. Kotlin unpacks this into a
// data class — keeping the marshaling cheap (no JNI object allocations) is
// the point.
JNIEXPORT jintArray JNICALL
Java_com_elodin_walkie_1talkie_PeerAudioManager_nativeGetTelemetry(
    JNIEnv* env, jobject thiz, jstring macAddress) {
    std::lock_guard<std::mutex> lock(g_peerManagerMutex);
    if (!g_peerAudioManager) return nullptr;
    const char* mac = env->GetStringUTFChars(macAddress, nullptr);
    auto t = g_peerAudioManager->getTelemetry(std::string(mac));
    env->ReleaseStringUTFChars(macAddress, mac);

    if (!t.valid) return nullptr;

    jintArray arr = env->NewIntArray(5);
    if (!arr) return nullptr;
    jint values[5] = {
        static_cast<jint>(t.underrunCount),
        static_cast<jint>(t.lateFrameCount),
        static_cast<jint>(t.jitterTargetDepth),
        static_cast<jint>(t.jitterCurrentDepth),
        static_cast<jint>(t.currentBitrate),
    };
    env->SetIntArrayRegion(arr, 0, 5, values);
    return arr;
}

}  // extern "C"
