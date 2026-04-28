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

static std::atomic<bool> g_muted{false};

// Voice-activity detection (VAD) globals.
// g_jvm + g_callbackObj let the real-time audio thread call back into Kotlin
// via AttachCurrentThread without going through a MethodChannel.
static JavaVM* g_jvm = nullptr;
static jobject g_callbackObj = nullptr;
static jmethodID g_onTalkingChangedMethod = nullptr;
static std::atomic<bool> g_lastTalking{false};
// Threshold ~= -40 dBFS for 16-bit audio: 32768 * 10^(-40/20) ~= 328
static constexpr double kTalkingThreshold = 328.0;
// Hysteresis frame counts at 48 kHz: ~100 ms on, ~300 ms off.
static constexpr int32_t kOnHoldFrames  = 4800;
static constexpr int32_t kOffHoldFrames = 14400;
static int32_t g_aboveFrames = 0;
static int32_t g_belowFrames = 0;

static void emitLocalTalkingEvent(bool talking) {
    if (g_jvm == nullptr || g_callbackObj == nullptr || g_onTalkingChangedMethod == nullptr) return;
    JNIEnv* env = nullptr;
    bool attached = false;
    jint status = g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if (g_jvm->AttachCurrentThread(&env, nullptr) == JNI_OK) attached = true;
    }
    if (env == nullptr) return;
    env->CallVoidMethod(g_callbackObj, g_onTalkingChangedMethod, static_cast<jboolean>(talking));
    if (attached) g_jvm->DetachCurrentThread();
}

class AudioEngine : public oboe::AudioStreamDataCallback {
private:
    std::shared_ptr<oboe::AudioStream> recordingStream;
    std::shared_ptr<oboe::AudioStream> playbackStream;
    std::mutex audioMutex;
    static constexpr int32_t kSampleRate = 48000;
    static constexpr int32_t kChannelCount = 1;
    static constexpr oboe::AudioFormat kFormat = oboe::AudioFormat::I16;

public:
    AudioEngine() {}
    ~AudioEngine() { stop(); }

    bool start() {
        LOGI("Starting audio engine...");
        oboe::AudioStreamBuilder rb;
        rb.setDirection(oboe::Direction::Input)
          ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
          ->setSharingMode(oboe::SharingMode::Exclusive)
          ->setFormat(kFormat)->setChannelCount(kChannelCount)->setSampleRate(kSampleRate)
          ->setDataCallback(this);
        oboe::Result result = rb.openStream(recordingStream);
        if (result != oboe::Result::OK) {
            LOGE("Failed to open recording stream: %s", oboe::convertToText(result));
            return false;
        }
        oboe::AudioStreamBuilder pb;
        pb.setDirection(oboe::Direction::Output)
          ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
          ->setSharingMode(oboe::SharingMode::Exclusive)
          ->setFormat(kFormat)->setChannelCount(kChannelCount)->setSampleRate(kSampleRate);
        result = pb.openStream(playbackStream);
        if (result != oboe::Result::OK) {
            LOGE("Failed to open playback stream: %s", oboe::convertToText(result));
            return false;
        }
        recordingStream->requestStart();
        playbackStream->requestStart();
        LOGI("Audio engine started successfully");
        return true;
    }

    void stop() {
        if (recordingStream) { recordingStream->requestStop(); recordingStream->close(); }
        if (playbackStream)  { playbackStream->requestStop();  playbackStream->close(); }
        LOGI("Audio engine stopped");
    }

    oboe::DataCallbackResult onAudioReady(
            oboe::AudioStream *audioStream, void *audioData, int32_t numFrames) override {
        if (numFrames <= 0) return oboe::DataCallbackResult::Continue;

        if (audioStream->getDirection() == oboe::Direction::Input) {
            auto *inputData = static_cast<int16_t *>(audioData);
            if (g_muted.load(std::memory_order_relaxed)) {
                std::memset(inputData, 0, numFrames * sizeof(int16_t));
            }

            // VAD: RMS computation with hysteresis.
            // Note: we intentionally run VAD on the (potentially zeroed) buffer even
            // when muted. When muted, RMS == 0 < threshold, so g_belowFrames accumulates
            // and the talking state clears after ~300 ms. Without this, muting while
            // speaking would leave g_lastTalking stuck at true indefinitely.
            {
                int64_t sumSq = 0;
                for (int32_t i = 0; i < numFrames; ++i) {
                    int64_t s = inputData[i];
                    sumSq += s * s;
                }
                double rms = std::sqrt(static_cast<double>(sumSq) / static_cast<double>(numFrames));
                bool above = (rms > kTalkingThreshold);
                // Cap counters to prevent int32 overflow on very long sessions.
                if (above) {
                    g_aboveFrames = std::min(g_aboveFrames + numFrames, 2 * kOnHoldFrames);
                    g_belowFrames = 0;
                } else {
                    g_belowFrames = std::min(g_belowFrames + numFrames, 2 * kOffHoldFrames);
                    g_aboveFrames = 0;
                }
                bool nowTalking = g_lastTalking.load(std::memory_order_relaxed);
                if (!nowTalking && g_aboveFrames >= kOnHoldFrames) {
                    g_aboveFrames = 0;
                    g_lastTalking.store(true, std::memory_order_relaxed);
                    emitLocalTalkingEvent(true);
                } else if (nowTalking && g_belowFrames >= kOffHoldFrames) {
                    g_belowFrames = 0;
                    g_lastTalking.store(false, std::memory_order_relaxed);
                    emitLocalTalkingEvent(false);
                }
            }

            if (g_audioMixer != nullptr) {
                g_audioMixer->updateDeviceAudio(0, inputData, numFrames);
                std::vector<int16_t> mixedOutput(numFrames);
                g_audioMixer->getMixedAudioForDevice(0, mixedOutput.data(), numFrames);
                if (playbackStream && playbackStream->getState() == oboe::StreamState::Started)
                    playbackStream->write(mixedOutput.data(), numFrames, 0);
            }
        }
        return oboe::DataCallbackResult::Continue;
    }
};

static AudioEngine* g_audioEngine = nullptr;

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeStart(JNIEnv *env, jobject thiz) {
    env->GetJavaVM(&g_jvm);
    if (g_callbackObj != nullptr) env->DeleteGlobalRef(g_callbackObj);
    g_callbackObj = env->NewGlobalRef(thiz);
    jclass cls = env->GetObjectClass(thiz);
    g_onTalkingChangedMethod = env->GetMethodID(cls, "onTalkingChanged", "(Z)V");
    env->DeleteLocalRef(cls);
    g_lastTalking.store(false, std::memory_order_relaxed);
    g_aboveFrames = 0;
    g_belowFrames = 0;
    if (g_audioEngine == nullptr) g_audioEngine = new AudioEngine();
    return g_audioEngine->start();
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeStop(JNIEnv *env, jobject thiz) {
    if (g_audioEngine != nullptr) { g_audioEngine->stop(); delete g_audioEngine; g_audioEngine = nullptr; }
    if (g_callbackObj != nullptr) { env->DeleteGlobalRef(g_callbackObj); g_callbackObj = nullptr; }
    g_onTalkingChangedMethod = nullptr;
    g_jvm = nullptr;
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeSetMuted(JNIEnv *env, jobject thiz, jboolean muted) {
    g_muted.store(muted, std::memory_order_relaxed);
    return JNI_TRUE;
}

JNIEXPORT jshortArray JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeGetAudioData(JNIEnv *env, jobject thiz, jint numFrames) {
    return nullptr;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativePlayAudioData(JNIEnv *env, jobject thiz, jshortArray audioData) {
}

} // extern "C"