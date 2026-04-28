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

// Global JNI references for voice activity callbacks
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
        if (g_jvm == nullptr || g_mainActivity == nullptr) return;

        JNIEnv* env = nullptr;
        bool needDetach = false;

        // Get JNI environment
        if (g_jvm->GetEnv((void**)&env, JNI_VERSION_1_6) != JNI_OK) {
            if (g_jvm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
                LOGE("Failed to attach thread for talking event");
                return;
            }
            needDetach = true;
        }

        // Call MainActivity.sendLocalTalkingEvent(boolean)
        jclass activityClass = env->GetObjectClass(g_mainActivity);
        if (activityClass != nullptr) {
            jmethodID method = env->GetMethodID(activityClass, "sendLocalTalkingEvent", "(Z)V");
            if (method != nullptr) {
                env->CallVoidMethod(g_mainActivity, method, talking);
            } else {
                LOGE("Failed to find sendLocalTalkingEvent method");
            }
            env->DeleteLocalRef(activityClass);
        }

        if (needDetach) {
            g_jvm->DetachCurrentThread();
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

    // Oboe callback for audio data
    oboe::DataCallbackResult onAudioReady(
            oboe::AudioStream *audioStream,
            void *audioData,
            int32_t numFrames) override {

        if (audioStream->getDirection() == oboe::Direction::Input) {
            // Recording: feed to mixer directly
            auto *inputData = static_cast<int16_t *>(audioData);

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
                    LOGI("Voice activity detected (RMS: %.4f)", rms);
                }
            } else {
                belowThresholdFrames += numFrames;
                aboveThresholdFrames = 0;
                // Flip to not talking if we've been below threshold for long enough
                if (lastTalking && belowThresholdFrames >= offHysteresisFrames) {
                    lastTalking = false;
                    emitTalkingEvent(false);
                    LOGI("Voice activity ended (RMS: %.4f)", rms);
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

                if (playbackStream && playbackStream->getState() == oboe::StreamState::Started) {
                    playbackStream->write(mixedOutput.data(), numFrames, 0);
                }
            }
        }

        return oboe::DataCallbackResult::Continue;
    }
};

// Global audio engine instance
static AudioEngine* g_audioEngine = nullptr;

extern "C" {

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_MainActivity_nativeRegisterForCallbacks(JNIEnv *env, jobject thiz) {
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
    // Clean up global references
    if (g_mainActivity != nullptr) {
        env->DeleteGlobalRef(g_mainActivity);
        g_mainActivity = nullptr;
    }
    g_jvm = nullptr;
    LOGI("MainActivity unregistered from voice activity callbacks");
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeStart(JNIEnv *env, jobject thiz) {
    if (g_audioEngine == nullptr) {
        g_audioEngine = new AudioEngine();
    }
    return g_audioEngine->start();
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeStop(JNIEnv *env, jobject thiz) {
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
