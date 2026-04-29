#include <jni.h>
#include <android/log.h>
#include <oboe/Oboe.h>
#include <memory>
#include <vector>
#include <mutex>
#include <atomic>
#include <cstring>
#include <cmath>
#include "audio_mixer.h"

#define LOG_TAG "WalkieTalkieAudio"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// Global mute flag — declared before AudioEngine so onAudioReady (inline
// in the class body) can reference it without a forward declaration.
static std::atomic<bool> g_muted{false};

// Audio-focus pause flag. When true, mic frames are zeroed before reaching
// the mixer / transport, mirroring the mute path. Streams themselves are
// also requestPause()'d (see pauseStreams()) — the flag is a belt-and-braces
// guard for the brief window where a callback is already in flight when
// pause is issued.
static std::atomic<bool> g_focusPaused{false};

// Output volume multiplier driven by AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK.
// 1.0 = full volume; 0.3 ≈ -10 dB which is what most media apps duck to.
static std::atomic<float> g_duckingVolume{1.0f};

// Global JNI references for voice activity callbacks
static std::mutex g_jniMutex;
static JavaVM* g_jvm = nullptr;
static jobject g_mainActivity = nullptr;

class AudioEngine : public oboe::AudioStreamDataCallback {
private:
    std::shared_ptr<oboe::AudioStream> recordingStream;
    std::shared_ptr<oboe::AudioStream> playbackStream;
    std::mutex audioMutex;

    // Audio configuration
    static constexpr int32_t kSampleRate = 48000;  // LE Audio standard
    static constexpr int32_t kChannelCount = 1;    // Mono for voice
    static constexpr oboe::AudioFormat kFormat = oboe::AudioFormat::I16;  // 16-bit PCM

    // Voice activity detection
    static constexpr double kTalkingThreshold = 0.01;  // -40 dBFS ≈ 0.01 RMS
    static constexpr int32_t kOnHysteresisMs = 100;    // 100ms above threshold to flip on
    static constexpr int32_t kOffHysteresisMs = 300;   // 300ms below threshold to flip off
    bool lastTalking = false;
    int32_t aboveThresholdFrames = 0;
    int32_t belowThresholdFrames = 0;
    const int32_t onHysteresisFrames = (kSampleRate * kOnHysteresisMs) / 1000;
    const int32_t offHysteresisFrames = (kSampleRate * kOffHysteresisMs) / 1000;

    // Compute RMS (Root Mean Square) of audio samples
    double computeRms(const int16_t* samples, int32_t numFrames) {
        if (numFrames == 0) return 0.0;

        double sum = 0.0;
        for (int32_t i = 0; i < numFrames; ++i) {
            double normalized = samples[i] / 32768.0;  // Normalize to [-1, 1]
            sum += normalized * normalized;
        }
        return std::sqrt(sum / numFrames);
    }

    // Emit talking event to Flutter via JNI
    void emitTalkingEvent(bool talking) {
        // Snapshot JNI globals under lock to avoid use-after-free
        JavaVM* jvm = nullptr;
        jobject activity = nullptr;
        {
            std::lock_guard<std::mutex> lock(g_jniMutex);
            if (g_jvm == nullptr || g_mainActivity == nullptr) return;
            jvm = g_jvm;
            activity = g_mainActivity;
        }

        JNIEnv* env = nullptr;
        bool needDetach = false;

        // Get JNI environment
        if (jvm->GetEnv((void**)&env, JNI_VERSION_1_6) != JNI_OK) {
            if (jvm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
                return;  // Skip logging in audio callback to avoid glitches
            }
            needDetach = true;
        }

        // Call MainActivity.sendLocalTalkingEvent(boolean)
        jclass activityClass = env->GetObjectClass(activity);
        if (activityClass != nullptr) {
            jmethodID method = env->GetMethodID(activityClass, "sendLocalTalkingEvent", "(Z)V");
            if (method != nullptr) {
                env->CallVoidMethod(activity, method, talking);
            }
            env->DeleteLocalRef(activityClass);
        }

        if (needDetach) {
            jvm->DetachCurrentThread();
        }
    }

public:
    AudioEngine() {}

    ~AudioEngine() {
        stop();
    }

    // Start audio streams
    bool start() {
        LOGI("Starting audio engine...");

        // Create recording stream
        oboe::AudioStreamBuilder recordingBuilder;
        recordingBuilder.setDirection(oboe::Direction::Input)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
            ->setSharingMode(oboe::SharingMode::Exclusive)
            ->setFormat(kFormat)
            ->setChannelCount(kChannelCount)
            ->setSampleRate(kSampleRate)
            ->setDataCallback(this);

        oboe::Result result = recordingBuilder.openStream(recordingStream);
        if (result != oboe::Result::OK) {
            LOGE("Failed to create recording stream: %s", oboe::convertToText(result));
            return false;
        }

        // Create playback stream
        oboe::AudioStreamBuilder playbackBuilder;
        playbackBuilder.setDirection(oboe::Direction::Output)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
            ->setSharingMode(oboe::SharingMode::Exclusive)
            ->setFormat(kFormat)
            ->setChannelCount(kChannelCount)
            ->setSampleRate(kSampleRate);
            // We use direct write for playback currently, or could use another callback

        result = playbackBuilder.openStream(playbackStream);
        if (result != oboe::Result::OK) {
            LOGE("Failed to create playback stream: %s", oboe::convertToText(result));
            return false;
        }

        // Start streams
        recordingStream->requestStart();
        playbackStream->requestStart();

        LOGI("Audio engine started successfully");
        return true;
    }

    // Stop audio streams
    void stop() {
        if (recordingStream) {
            recordingStream->requestStop();
            recordingStream->close();
        }
        if (playbackStream) {
            playbackStream->requestStop();
            playbackStream->close();
        }
        LOGI("Audio engine stopped");
    }

    // Pause both streams without tearing them down. Used for transient
    // audio focus losses (incoming calls) so a phone call doesn't fight
    // the Oboe streams for the audio path. Counterpart to resumeStreams().
    bool pauseStreams() {
        bool ok = true;
        if (recordingStream) {
            oboe::Result r = recordingStream->requestPause();
            if (r != oboe::Result::OK) {
                LOGE("Failed to pause recording stream: %s", oboe::convertToText(r));
                ok = false;
            }
        }
        if (playbackStream) {
            oboe::Result r = playbackStream->requestPause();
            if (r != oboe::Result::OK) {
                LOGE("Failed to pause playback stream: %s", oboe::convertToText(r));
                ok = false;
            }
        }
        LOGI("Audio streams paused (ok=%d)", ok ? 1 : 0);
        return ok;
    }

    // Resume both streams after a transient pause.
    bool resumeStreams() {
        bool ok = true;
        if (recordingStream) {
            oboe::Result r = recordingStream->requestStart();
            if (r != oboe::Result::OK) {
                LOGE("Failed to resume recording stream: %s", oboe::convertToText(r));
                ok = false;
            }
        }
        if (playbackStream) {
            oboe::Result r = playbackStream->requestStart();
            if (r != oboe::Result::OK) {
                LOGE("Failed to resume playback stream: %s", oboe::convertToText(r));
                ok = false;
            }
        }
        LOGI("Audio streams resumed (ok=%d)", ok ? 1 : 0);
        return ok;
    }

    // Oboe callback for audio data
    oboe::DataCallbackResult onAudioReady(
            oboe::AudioStream *audioStream,
            void *audioData,
            int32_t numFrames) override {

        if (audioStream->getDirection() == oboe::Direction::Input) {
            // Recording: feed to mixer directly
            auto *inputData = static_cast<int16_t *>(audioData);

            // Focus-pause short-circuit. requestPause() halts new callbacks
            // but a callback already in flight when pause was issued still
            // runs once. Drop its audio entirely instead of running VAD,
            // mixer, and playback for a chunk that's already lost the
            // audio path — saves CPU and prevents a mid-call blip.
            if (g_focusPaused.load(std::memory_order_relaxed)) {
                std::memset(inputData, 0, numFrames * sizeof(int16_t));
                return oboe::DataCallbackResult::Continue;
            }

            bool isMuted = g_muted.load(std::memory_order_relaxed);

            // Voice activity detection (compute RMS before mute gate, so we
            // detect talking state even when muted for UI feedback)
            double rms = computeRms(inputData, numFrames);
            bool nowAboveThreshold = rms > kTalkingThreshold;

            // Hysteresis: require sustained signal to flip talking state
            if (nowAboveThreshold) {
                aboveThresholdFrames += numFrames;
                belowThresholdFrames = 0;
                // Flip to talking if we've been above threshold for long enough
                if (!lastTalking && aboveThresholdFrames >= onHysteresisFrames) {
                    lastTalking = true;
                    emitTalkingEvent(true);
                }
            } else {
                belowThresholdFrames += numFrames;
                aboveThresholdFrames = 0;
                // Flip to not talking if we've been below threshold for long enough
                if (lastTalking && belowThresholdFrames >= offHysteresisFrames) {
                    lastTalking = false;
                    emitTalkingEvent(false);
                }
            }

            // When muted, zero the mic frames so they don't reach the mixer
            // or any future BLE transport. The streams stay warm so unmuting
            // is instant — no codec reinit round-trip.
            if (isMuted) {
                std::memset(inputData, 0, numFrames * sizeof(int16_t));
            }

            if (g_audioMixer != nullptr) {
                // Here we'd ideally know which device this input is from.
                // For a single phone mic, we can assign a special ID like 0.
                g_audioMixer->updateDeviceAudio(0, inputData, numFrames);

                // For demonstration: mix for device 0 (hearing others) and play it back
                std::vector<int16_t> mixedOutput(numFrames);
                g_audioMixer->getMixedAudioForDevice(0, mixedOutput.data(), numFrames);

                // Apply ducking volume for AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK.
                // Skip the multiply when at full volume to keep the hot path
                // branch-free for the common case.
                float duckVol = g_duckingVolume.load(std::memory_order_relaxed);
                if (duckVol < 1.0f) {
                    for (int32_t i = 0; i < numFrames; ++i) {
                        mixedOutput[i] = static_cast<int16_t>(mixedOutput[i] * duckVol);
                    }
                }

                if (playbackStream && playbackStream->getState() == oboe::StreamState::Started) {
                    playbackStream->write(mixedOutput.data(), numFrames, 0);
                }
            }
        }

        return oboe::DataCallbackResult::Continue;
    }
};

// Global audio engine instance + mutex.
//
// nativeStop deletes the engine and nulls the pointer; nativePauseStreams /
// nativeResumeStreams read the pointer and dispatch to it. Without
// serialization a stop racing with pause/resume can either tear down the
// engine mid-call (use-after-free) or null the pointer between the load and
// the dereference. In practice the JNI calls usually serialize on the
// service / main thread, but Android focus-change listeners can be
// dispatched on other threads; the mutex makes the contract explicit so
// future call sites can't introduce a UAF by accident.
static std::mutex g_engineMutex;
static AudioEngine* g_audioEngine = nullptr;

extern "C" {

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_MainActivity_nativeRegisterForCallbacks(JNIEnv *env, jobject thiz) {
    std::lock_guard<std::mutex> lock(g_jniMutex);

    // Store JavaVM for thread attachment
    if (g_jvm == nullptr) {
        env->GetJavaVM(&g_jvm);
    }

    // Store global reference to MainActivity for callbacks
    if (g_mainActivity != nullptr) {
        env->DeleteGlobalRef(g_mainActivity);
    }
    g_mainActivity = env->NewGlobalRef(thiz);
    LOGI("MainActivity registered for voice activity callbacks");
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_MainActivity_nativeUnregisterCallbacks(JNIEnv *env, jobject thiz) {
    std::lock_guard<std::mutex> lock(g_jniMutex);

    // Only unregister if this is the same activity instance
    if (g_mainActivity != nullptr && env->IsSameObject(thiz, g_mainActivity)) {
        env->DeleteGlobalRef(g_mainActivity);
        g_mainActivity = nullptr;
        g_jvm = nullptr;
        LOGI("MainActivity unregistered from voice activity callbacks");
    }
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeStart(JNIEnv *env, jobject thiz) {
    std::lock_guard<std::mutex> lock(g_engineMutex);
    if (g_audioEngine == nullptr) {
        g_audioEngine = new AudioEngine();
    }
    return g_audioEngine->start();
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeStop(JNIEnv *env, jobject thiz) {
    std::lock_guard<std::mutex> lock(g_engineMutex);
    if (g_audioEngine != nullptr) {
        g_audioEngine->stop();
        delete g_audioEngine;
        g_audioEngine = nullptr;
    }
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeSetMuted(
        JNIEnv *env, jobject thiz, jboolean muted) {
    g_muted.store(muted, std::memory_order_relaxed);
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativePauseStreams(
        JNIEnv *env, jobject thiz) {
    g_focusPaused.store(true, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(g_engineMutex);
    if (g_audioEngine != nullptr) {
        return g_audioEngine->pauseStreams() ? JNI_TRUE : JNI_FALSE;
    }
    // No engine running — flag stored, nothing else to pause. Treat as
    // success so callers that always pause on focus loss don't see a
    // spurious failure when voice hasn't been started yet.
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeResumeStreams(
        JNIEnv *env, jobject thiz) {
    // Pause and ducking are orthogonal — the caller is responsible for
    // restoring full volume via setDuckingVolume(1.0) when appropriate.
    // Keeps the contract symmetric with pauseStreams (which doesn't touch
    // ducking either) and avoids surprising a duck-then-pause sequence
    // by silently restoring volume on the wrong event.
    g_focusPaused.store(false, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(g_engineMutex);
    if (g_audioEngine != nullptr) {
        return g_audioEngine->resumeStreams() ? JNI_TRUE : JNI_FALSE;
    }
    return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeSetDuckingVolume(
        JNIEnv *env, jobject thiz, jfloat volume) {
    float clamped = volume < 0.0f ? 0.0f : (volume > 1.0f ? 1.0f : volume);
    g_duckingVolume.store(clamped, std::memory_order_relaxed);
}

// These methods can now be used for manual injection if needed,
// but the primary path is now internal to C++.

JNIEXPORT jshortArray JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeGetAudioData(
        JNIEnv *env, jobject thiz, jint numFrames) {
    // Legacy support or specific use cases
    return nullptr;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativePlayAudioData(
        JNIEnv *env, jobject thiz, jshortArray audioData) {
    // Legacy support or specific use cases
}

} // extern "C"
