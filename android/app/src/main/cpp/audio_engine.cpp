#include <jni.h>
#include <android/log.h>
#include <oboe/Oboe.h>
#include <memory>
#include <vector>
#include <mutex>

#define LOG_TAG "WalkieTalkieAudio"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

class AudioEngine : public oboe::AudioStreamDataCallback {
private:
    std::shared_ptr<oboe::AudioStream> recordingStream;
    std::shared_ptr<oboe::AudioStream> playbackStream;
    std::mutex audioMutex;
    
    // Audio configuration
    static constexpr int32_t kSampleRate = 48000;  // LE Audio standard
    static constexpr int32_t kChannelCount = 1;    // Mono for voice
    static constexpr oboe::AudioFormat kFormat = oboe::AudioFormat::I16;  // 16-bit PCM
    
    // Circular buffer for audio data
    std::vector<int16_t> audioBuffer;
    size_t bufferSize;
    size_t writeIndex = 0;
    size_t readIndex = 0;

public:
    AudioEngine() : bufferSize(kSampleRate * 2) {  // 2 seconds buffer
        audioBuffer.resize(bufferSize, 0);
    }

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
        
        std::lock_guard<std::mutex> lock(audioMutex);
        
        if (audioStream->getDirection() == oboe::Direction::Input) {
            // Recording: write to buffer
            auto *inputData = static_cast<int16_t *>(audioData);
            for (int32_t i = 0; i < numFrames; i++) {
                audioBuffer[writeIndex] = inputData[i];
                writeIndex = (writeIndex + 1) % bufferSize;
            }
        }
        
        return oboe::DataCallbackResult::Continue;
    }
    
    // Get audio data for transmission
    void getAudioData(int16_t* buffer, int32_t numFrames) {
        std::lock_guard<std::mutex> lock(audioMutex);
        for (int32_t i = 0; i < numFrames; i++) {
            buffer[i] = audioBuffer[readIndex];
            readIndex = (readIndex + 1) % bufferSize;
        }
    }
    
    // Play received audio data
    void playAudioData(const int16_t* buffer, int32_t numFrames) {
        if (playbackStream && playbackStream->getState() == oboe::StreamState::Started) {
            playbackStream->write(buffer, numFrames, 0);
        }
    }
};

// Global audio engine instance
static AudioEngine* g_audioEngine = nullptr;

extern "C" {

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

JNIEXPORT jshortArray JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativeGetAudioData(
        JNIEnv *env, jobject thiz, jint numFrames) {
    if (g_audioEngine == nullptr) {
        return nullptr;
    }
    
    jshortArray result = env->NewShortArray(numFrames);
    jshort* buffer = env->GetShortArrayElements(result, nullptr);
    
    g_audioEngine->getAudioData(buffer, numFrames);
    
    env->ReleaseShortArrayElements(result, buffer, 0);
    return result;
}

JNIEXPORT void JNICALL
Java_com_elodin_walkie_1talkie_AudioEngineManager_nativePlayAudioData(
        JNIEnv *env, jobject thiz, jshortArray audioData) {
    if (g_audioEngine == nullptr) {
        return;
    }
    
    jsize length = env->GetArrayLength(audioData);
    jshort* buffer = env->GetShortArrayElements(audioData, nullptr);
    
    g_audioEngine->playAudioData(buffer, length);
    
    env->ReleaseShortArrayElements(audioData, buffer, JNI_ABORT);
}

} // extern "C"
