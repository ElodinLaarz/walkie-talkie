#include <jni.h>
#include <android/log.h>
#include <oboe/Oboe.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "audio_config.h"
#include "audio_mixer.h"
#include "resampler.h"
#include "talking_event_queue.h"

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

// Forward declaration for the error callback class
class AudioEngineErrorCallback;

// Emit audio error event to Flutter via JNI.
// Called from Oboe's error callback when a stream error occurs (e.g., permission
// revoked, device disconnected). Maps Oboe error codes to human-readable reasons
// and sends them to the Dart side so the UI can transition to an error state.
static void emitAudioErrorEvent(oboe::Result error) {
    JavaVM* jvm = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_jniMutex);
        jvm = g_jvm;
        if (jvm == nullptr || g_mainActivity == nullptr) return;
    }

    JNIEnv* env = nullptr;
    bool needDetach = false;
    if (jvm->GetEnv((void**)&env, JNI_VERSION_1_6) != JNI_OK) {
        if (jvm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
            return;
        }
        needDetach = true;
    }

    jobject activity = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_jniMutex);
        if (g_mainActivity != nullptr) {
            activity = env->NewLocalRef(g_mainActivity);
        }
    }
    if (activity == nullptr) {
        if (needDetach) jvm->DetachCurrentThread();
        return;
    }

    jclass activityClass = env->GetObjectClass(activity);
    if (activityClass != nullptr) {
        jmethodID method = env->GetMethodID(activityClass,
                                            "sendAudioError", "(Ljava/lang/String;)V");
        if (method != nullptr) {
            // Map Oboe error codes to reason strings
            const char* reason = "UNKNOWN";
            switch (error) {
                case oboe::Result::ErrorDisconnected:
                    reason = "DISCONNECTED";
                    break;
                case oboe::Result::ErrorInternal:
                    reason = "INTERNAL";
                    break;
                case oboe::Result::ErrorInvalidState:
                    reason = "INVALID_STATE";
                    break;
                case oboe::Result::ErrorClosed:
                    reason = "CLOSED";
                    break;
                default:
                    reason = "AUDIO_ERROR";
                    break;
            }

            jstring reasonStr = env->NewStringUTF(reason);
            if (reasonStr != nullptr) {
                env->CallVoidMethod(activity, method, reasonStr);
                if (env->ExceptionCheck()) {
                    env->ExceptionDescribe();
                    env->ExceptionClear();
                }
                env->DeleteLocalRef(reasonStr);
            }
        }
        env->DeleteLocalRef(activityClass);
    }
    env->DeleteLocalRef(activity);

    if (needDetach) {
        jvm->DetachCurrentThread();
    }
}

// Talking-event worker plumbing. The audio callback used to do its own JNI
// dispatch (AttachCurrentThread, GetMethodID, CallVoidMethod) plus take
// g_jniMutex for the global ref snapshot. Both are unbounded-latency
// operations on a real-time audio thread — JVM safepoints can stall an
// AttachCurrentThread for milliseconds at a time, which corrupts playback.
//
// New plumbing: the audio callback push()es a single bool onto a lock-free
// SPSC ring (no allocation, no syscalls, no mutex). A worker thread polls
// the ring at a 20 ms cadence and runs the JNI dispatch on its own
// (long-attached) JNIEnv. The worker is owned by the engine — it starts in
// `start()` after the streams open and stops in `stop()` before the streams
// close, so an in-flight audio callback cannot push to a dead queue.
static TalkingEventQueue g_talkingQueue;
static std::atomic<bool> g_talkingWorkerStop{false};
static std::thread g_talkingWorkerThread;

// JNI dispatch for a single VAD edge. Runs on the worker thread, NOT the
// audio thread — taking g_jniMutex and attaching to the JVM here is fine.
static void emitTalkingEventJni(bool talking) {
    JavaVM* jvm = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_jniMutex);
        jvm = g_jvm;
        if (jvm == nullptr || g_mainActivity == nullptr) return;
    }

    JNIEnv* env = nullptr;
    bool needDetach = false;
    if (jvm->GetEnv((void**)&env, JNI_VERSION_1_6) != JNI_OK) {
        if (jvm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
            return;
        }
        needDetach = true;
    }

    // Snapshot the global ref into a local ref while holding g_jniMutex.
    // This rules out the race where nativeUnregisterCallbacks runs
    // DeleteGlobalRef between our earlier null-check and the GetObjectClass
    // below — the local ref keeps the underlying jobject alive across the
    // JNI calls regardless of what happens to the global. Outside the lock,
    // we do all the JNI work on the local ref.
    jobject activity = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_jniMutex);
        if (g_mainActivity != nullptr) {
            activity = env->NewLocalRef(g_mainActivity);
        }
    }
    if (activity == nullptr) {
        if (needDetach) jvm->DetachCurrentThread();
        return;
    }

    jclass activityClass = env->GetObjectClass(activity);
    if (activityClass != nullptr) {
        jmethodID method = env->GetMethodID(activityClass,
                                            "sendLocalTalkingEvent", "(Z)V");
        if (method != nullptr) {
            env->CallVoidMethod(activity, method, talking);
            if (env->ExceptionCheck()) {
                env->ExceptionDescribe();
                env->ExceptionClear();
            }
        }
        env->DeleteLocalRef(activityClass);
    }
    env->DeleteLocalRef(activity);

    if (needDetach) {
        jvm->DetachCurrentThread();
    }
}

// Worker loop: drain everything in the queue, sleep, repeat. The 20 ms
// cadence is below the human-perceivable limit for VAD UI feedback (typical
// VAD edges fire on the order of seconds; 20 ms latency is invisible) while
// keeping the worker mostly asleep — when no events are pending the loop is
// effectively a `nanosleep` once per tick.
static void talkingEventWorkerLoop() {
    while (!g_talkingWorkerStop.load(std::memory_order_acquire)) {
        bool talking;
        while (g_talkingQueue.pop(talking)) {
            emitTalkingEventJni(talking);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    // Drain any residual events queued just before the stop flag was set so
    // the Dart side gets a final consistent talking-state.
    bool talking;
    while (g_talkingQueue.pop(talking)) {
        emitTalkingEventJni(talking);
    }
}

static void startTalkingEventWorker() {
    if (g_talkingWorkerThread.joinable()) return;
    g_talkingWorkerStop.store(false, std::memory_order_release);
    g_talkingWorkerThread = std::thread(talkingEventWorkerLoop);
}

static void stopTalkingEventWorker() {
    if (!g_talkingWorkerThread.joinable()) return;
    g_talkingWorkerStop.store(true, std::memory_order_release);
    g_talkingWorkerThread.join();
}

// Error callback for Oboe streams. Emits structured events to Flutter rather
// than crashing the foreground service. Handles permission revocation (which
// presents as ErrorDisconnected or ErrorInternal) and other stream errors.
//
// Note: Oboe invokes both onErrorBeforeClose and onErrorAfterClose for the same
// failure. We emit only in onErrorBeforeClose to avoid duplicate Flutter events.
class AudioEngineErrorCallback : public oboe::AudioStreamErrorCallback {
public:
    void onErrorBeforeClose(oboe::AudioStream* stream, oboe::Result error) override {
        LOGE("Oboe stream error: %s", oboe::convertToText(error));
        emitAudioErrorEvent(error);
    }

    void onErrorAfterClose(oboe::AudioStream* stream, oboe::Result error) override {
        LOGE("Oboe stream error after close: %s (event already emitted)",
             oboe::convertToText(error));
        // Do not emit — onErrorBeforeClose already sent the event.
    }
};

class AudioEngine : public oboe::AudioStreamDataCallback {
private:
    std::shared_ptr<oboe::AudioStream> recordingStream;
    std::shared_ptr<oboe::AudioStream> playbackStream;
    std::mutex audioMutex;

    // Error callback shared between recording and playback streams
    std::shared_ptr<AudioEngineErrorCallback> errorCallback;

    // Audio configuration — Oboe runs at 48 kHz; the codec/mixer rate is
    // 16 kHz; the resamplers below bridge the two.
    static constexpr int32_t kSampleRate = audio_config::kPlayoutSampleRate;
    static constexpr int32_t kChannelCount = audio_config::kPlayoutChannels;
    static constexpr oboe::AudioFormat kFormat = oboe::AudioFormat::I16;

    // Voice activity detection. RMS is computed at the playout rate so the
    // hysteresis threshold scales with the mic's actual sample count, not
    // the codec's downsampled count.
    static constexpr double kTalkingThreshold = 0.01;  // -40 dBFS
    static constexpr int32_t kOnHysteresisMs = 100;
    static constexpr int32_t kOffHysteresisMs = 300;
    bool lastTalking = false;
    int32_t aboveThresholdFrames = 0;
    int32_t belowThresholdFrames = 0;
    const int32_t onHysteresisFrames = (kSampleRate * kOnHysteresisMs) / 1000;
    const int32_t offHysteresisFrames = (kSampleRate * kOffHysteresisMs) / 1000;

    // Resampler bridge between 48 kHz Oboe and the 16 kHz codec/mixer plane.
    // These are owned by the engine because their FIR history must persist
    // across callbacks — a per-callback construction would discard the
    // history and produce a click at every Oboe burst boundary.
    Resampler48to16 micResampler_;
    Resampler16to48 playbackResampler_;

    // Pre-allocated scratch sized for a generous Oboe burst (~80 ms at
    // 48 kHz). The hot-path callback must never allocate; under normal
    // operation `numFrames` is ~960 (one 20 ms tick) and these are vastly
    // oversized, but Oboe is allowed to burst on stream open.
    static constexpr int kMaxBurstPlayoutFrames =
        audio_config::kPlayoutFrameSize * 4;  // 80 ms @ 48 kHz = 3840
    static constexpr int kMaxBurstCodecFrames =
        audio_config::kCodecFrameSize * 4;  // 80 ms @ 16 kHz = 1280
    int16_t codecScratch_[kMaxBurstCodecFrames]{};
    int16_t playoutScratch_[kMaxBurstPlayoutFrames]{};

    // Compute RMS (Root Mean Square) of audio samples
    double computeRms(const int16_t* samples, int32_t numFrames) {
        if (numFrames == 0) return 0.0;
        double sum = 0.0;
        for (int32_t i = 0; i < numFrames; ++i) {
            double normalized = samples[i] / 32768.0;
            sum += normalized * normalized;
        }
        return std::sqrt(sum / numFrames);
    }

    // Emit a VAD edge from the audio thread.
    //
    // Lock-free, allocation-free, no JNI. We push onto a SPSC ring; a
    // dedicated worker thread (see talkingEventWorkerLoop above) drains the
    // ring and runs the actual JNI dispatch. If the ring is full the event
    // is dropped — at the operating rate (one edge per VAD transition,
    // hard-bounded by the audio callback cadence) the ring is effectively
    // unfillable, so a drop signals catastrophic worker stall, not a
    // recoverable condition.
    void emitTalkingEvent(bool talking) {
        g_talkingQueue.push(talking);
    }

public:
    AudioEngine() : errorCallback(std::make_shared<AudioEngineErrorCallback>()) {}

    ~AudioEngine() { stop(); }

    bool start() {
        LOGI("Starting audio engine (playout %d Hz, codec %d Hz)...", kSampleRate,
             audio_config::kCodecSampleRate);

        oboe::AudioStreamBuilder recordingBuilder;
        recordingBuilder.setDirection(oboe::Direction::Input)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
            ->setSharingMode(oboe::SharingMode::Exclusive)
            ->setFormat(kFormat)
            ->setChannelCount(kChannelCount)
            ->setSampleRate(kSampleRate)
            ->setDataCallback(this)
            ->setErrorCallback(errorCallback.get());

        oboe::Result result = recordingBuilder.openStream(recordingStream);
        if (result != oboe::Result::OK) {
            LOGE("Failed to create recording stream: %s",
                 oboe::convertToText(result));
            return false;
        }

        oboe::AudioStreamBuilder playbackBuilder;
        playbackBuilder.setDirection(oboe::Direction::Output)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
            ->setSharingMode(oboe::SharingMode::Exclusive)
            ->setFormat(kFormat)
            ->setChannelCount(kChannelCount)
            ->setSampleRate(kSampleRate)
            ->setErrorCallback(errorCallback.get());

        result = playbackBuilder.openStream(playbackStream);
        if (result != oboe::Result::OK) {
            LOGE("Failed to create playback stream: %s",
                 oboe::convertToText(result));
            // Don't leave the (already-opened) recording stream dangling — in
            // exclusive mode that blocks the next start() attempt until the
            // engine is destroyed. stop() handles both streams idempotently.
            stop();
            return false;
        }

        // Reset resampler history on every (re)start so the first samples
        // don't carry transients from a previous session.
        micResampler_.reset();
        playbackResampler_.reset();

        // Bring the worker thread up before starting the streams so any
        // VAD edge from the very first callback finds a draining consumer.
        startTalkingEventWorker();

        result = recordingStream->requestStart();
        if (result != oboe::Result::OK) {
            LOGE("Failed to start recording stream: %s",
                 oboe::convertToText(result));
            stop();
            return false;
        }
        result = playbackStream->requestStart();
        if (result != oboe::Result::OK) {
            LOGE("Failed to start playback stream: %s",
                 oboe::convertToText(result));
            stop();
            return false;
        }

        LOGI("Audio engine started successfully");
        return true;
    }

    void stop() {
        // Close streams first so no more audio callbacks can run — close()
        // blocks until any in-flight callback returns. After both close
        // calls return, the audio thread is guaranteed quiescent and no new
        // events can be pushed onto the talking queue.
        if (recordingStream) {
            recordingStream->requestStop();
            recordingStream->close();
        }
        if (playbackStream) {
            playbackStream->requestStop();
            playbackStream->close();
        }
        // Now stop the worker. It will drain any remaining queued events
        // (including ones pushed during the close() drain above) and exit.
        stopTalkingEventWorker();
        LOGI("Audio engine stopped");
    }

    bool pauseStreams() {
        bool ok = true;
        if (recordingStream) {
            oboe::Result r = recordingStream->requestPause();
            if (r != oboe::Result::OK) {
                LOGE("Failed to pause recording stream: %s",
                     oboe::convertToText(r));
                ok = false;
            }
        }
        if (playbackStream) {
            oboe::Result r = playbackStream->requestPause();
            if (r != oboe::Result::OK) {
                LOGE("Failed to pause playback stream: %s",
                     oboe::convertToText(r));
                ok = false;
            }
        }
        LOGI("Audio streams paused (ok=%d)", ok ? 1 : 0);
        return ok;
    }

    bool resumeStreams() {
        bool ok = true;
        if (recordingStream) {
            oboe::Result r = recordingStream->requestStart();
            if (r != oboe::Result::OK) {
                LOGE("Failed to resume recording stream: %s",
                     oboe::convertToText(r));
                ok = false;
            }
        }
        if (playbackStream) {
            oboe::Result r = playbackStream->requestStart();
            if (r != oboe::Result::OK) {
                LOGE("Failed to resume playback stream: %s",
                     oboe::convertToText(r));
                ok = false;
            }
        }
        LOGI("Audio streams resumed (ok=%d)", ok ? 1 : 0);
        return ok;
    }

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* audioStream,
                                           void* audioData,
                                           int32_t numFrames) override {
        if (audioStream->getDirection() != oboe::Direction::Input) {
            return oboe::DataCallbackResult::Continue;
        }

        auto* inputData = static_cast<int16_t*>(audioData);

        // Focus-pause short-circuit: a callback already in flight when
        // requestPause() ran still gets one final delivery. Drop it.
        if (g_focusPaused.load(std::memory_order_relaxed)) {
            std::memset(inputData, 0, numFrames * sizeof(int16_t));
            return oboe::DataCallbackResult::Continue;
        }

        const bool isMuted = g_muted.load(std::memory_order_relaxed);

        // VAD on the raw 48 kHz mic signal — pre-mute so the UI shows
        // "talking" feedback even when transmit is muted.
        const double rms = computeRms(inputData, numFrames);
        const bool nowAboveThreshold = rms > kTalkingThreshold;
        if (nowAboveThreshold) {
            aboveThresholdFrames += numFrames;
            belowThresholdFrames = 0;
            if (!lastTalking && aboveThresholdFrames >= onHysteresisFrames) {
                lastTalking = true;
                emitTalkingEvent(true);
            }
        } else {
            belowThresholdFrames += numFrames;
            aboveThresholdFrames = 0;
            if (lastTalking && belowThresholdFrames >= offHysteresisFrames) {
                lastTalking = false;
                emitTalkingEvent(false);
            }
        }

        // Mute zeros the mic signal before resampling so the wire path sees
        // pure silence (Opus then DTX'es the frame and saves bandwidth).
        if (isMuted) {
            std::memset(inputData, 0, numFrames * sizeof(int16_t));
        }

        // Burst-size guard. Oboe is allowed to deliver more than the typical
        // 960 samples on stream open or after a buffer growth. If the burst
        // would overflow our scratch we'd corrupt memory; clamp instead.
        // Under normal operation this branch never fires.
        if (numFrames > kMaxBurstPlayoutFrames) {
            LOGE("Oboe burst %d > scratch %d; truncating", numFrames,
                 kMaxBurstPlayoutFrames);
            numFrames = kMaxBurstPlayoutFrames;
        }

        // Mic 48 kHz → codec 16 kHz. The decimator carries phase across
        // calls; for the typical 960-sample burst we get exactly 320 codec
        // samples back, but it tolerates non-multiple-of-3 callbacks.
        const int codecFrames =
            micResampler_.process(inputData, numFrames, codecScratch_);

        // Snapshot the mixer singleton into an owning local shared_ptr.
        // Holding this strong reference for the rest of the callback rules
        // out the use-after-free that the bare-pointer global allowed:
        // nativeClear can run concurrently and reset the global, but the
        // underlying AudioMixer cannot be destroyed until this local ref
        // drops at the end of the callback.
        auto mixer = std::atomic_load(&g_audioMixer);
        if (mixer && codecFrames > 0) {
            // Local mic occupies device id 0 in the mix-minus matrix.
            mixer->updateDeviceAudio(0, codecScratch_, codecFrames);

            // Pull this device's mix-minus (everyone but us) back from the
            // mixer. The buffer it returns is at the codec rate.
            int16_t mixedCodec[kMaxBurstCodecFrames];
            if (codecFrames > kMaxBurstCodecFrames) {
                // Defensive: should be unreachable since the resampler can
                // never expand its input, but the static-array indexing
                // below is too dangerous to leave un-asserted.
                LOGE("codecFrames %d > scratch %d", codecFrames,
                     kMaxBurstCodecFrames);
                return oboe::DataCallbackResult::Continue;
            }
            mixer->getMixedAudioForDevice(0, mixedCodec, codecFrames);

            // Codec 16 kHz → playout 48 kHz. Always 3:1, so output count is
            // exactly `codecFrames * kResampleRatio`.
            const int playoutFrames = playbackResampler_.process(
                mixedCodec, codecFrames, playoutScratch_);

            // Apply ducking on the playout-rate buffer so the multiplier
            // hits every output sample (not every third).
            const float duckVol =
                g_duckingVolume.load(std::memory_order_relaxed);
            if (duckVol < 1.0f) {
                for (int32_t i = 0; i < playoutFrames; ++i) {
                    playoutScratch_[i] = static_cast<int16_t>(
                        playoutScratch_[i] * duckVol);
                }
            }

            if (playbackStream &&
                playbackStream->getState() == oboe::StreamState::Started) {
                // Non-blocking write (timeout=0). The result is a
                // ResultWithValue<int32_t>: a positive value is the count of
                // frames written, a negative value is an error. We don't
                // bubble the error up to the caller (we're inside the
                // input-direction callback), but we log it so a stuck
                // playback stream is visible in logcat. A persistent
                // negative result here indicates the stream needs to be
                // restarted by the engine owner — that's tracked separately
                // and isn't fixable from inside the callback.
                auto wr = playbackStream->write(playoutScratch_, playoutFrames, 0);
                if (!wr) {
                    LOGE("playbackStream->write failed: %s",
                         oboe::convertToText(wr.error()));
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
Java_com_elodin_walkie_1talkie_MainActivity_nativeRegisterForCallbacks(
    JNIEnv* env, jobject thiz) {
    std::lock_guard<std::mutex> lock(g_jniMutex);

    if (g_jvm == nullptr) {
        env->GetJavaVM(&g_jvm);
    }

    if (g_mainActivity != nullptr) {
        env->DeleteGlobalRef(g_mainActivity);
    }
    g_mainActivity = env->NewGlobalRef(thiz);
    LOGI("MainActivity registered for voice activity callbacks");
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_MainActivity_nativeUnregisterCallbacks(
    JNIEnv* env, jobject thiz) {
    std::lock_guard<std::mutex> lock(g_jniMutex);

    if (g_mainActivity != nullptr && env->IsSameObject(thiz, g_mainActivity)) {
        env->DeleteGlobalRef(g_mainActivity);
        g_mainActivity = nullptr;
        g_jvm = nullptr;
        LOGI("MainActivity unregistered from voice activity callbacks");
    }
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeStart(JNIEnv* env,
                                                                jobject thiz) {
    std::lock_guard<std::mutex> lock(g_engineMutex);
    if (g_audioEngine == nullptr) {
        g_audioEngine = new AudioEngine();
    }
    return g_audioEngine->start();
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeStop(JNIEnv* env,
                                                              jobject thiz) {
    std::lock_guard<std::mutex> lock(g_engineMutex);
    if (g_audioEngine != nullptr) {
        g_audioEngine->stop();
        delete g_audioEngine;
        g_audioEngine = nullptr;
    }
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeSetMuted(
    JNIEnv* env, jobject thiz, jboolean muted) {
    g_muted.store(muted, std::memory_order_relaxed);
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativePauseStreams(
    JNIEnv* env, jobject thiz) {
    g_focusPaused.store(true, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(g_engineMutex);
    if (g_audioEngine != nullptr) {
        return g_audioEngine->pauseStreams() ? JNI_TRUE : JNI_FALSE;
    }
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeResumeStreams(
    JNIEnv* env, jobject thiz) {
    g_focusPaused.store(false, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(g_engineMutex);
    if (g_audioEngine != nullptr) {
        return g_audioEngine->resumeStreams() ? JNI_TRUE : JNI_FALSE;
    }
    return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeSetDuckingVolume(
    JNIEnv* env, jobject thiz, jfloat volume) {
    float clamped = volume < 0.0f ? 0.0f : (volume > 1.0f ? 1.0f : volume);
    g_duckingVolume.store(clamped, std::memory_order_relaxed);
}

// Legacy hooks — kept for now so AudioEngineManager.kt doesn't unsatisfied-
// link. Both are no-ops; the native pipeline is internal to the audio
// callback.
JNIEXPORT jshortArray JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeGetAudioData(
    JNIEnv* env, jobject thiz, jint numFrames) {
    return nullptr;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativePlayAudioData(
    JNIEnv* env, jobject thiz, jshortArray audioData) {}

}  // extern "C"
