#include "opus_codec.h"
#include <android/log.h>

#define LOG_TAG "OpusCodec"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// OpusEncoder implementation
OpusEncoder::OpusEncoder() : encoder(nullptr) {
    int error;
    encoder = opus_encoder_create(kSampleRate, kChannels, OPUS_APPLICATION_VOIP, &error);
    if (error != OPUS_OK) {
        LOGE("Failed to create Opus encoder: %s", opus_strerror(error));
        encoder = nullptr;
        return;
    }

    // Set bitrate
    opus_encoder_ctl(encoder, OPUS_SET_BITRATE(kBitrate));

    // Enable DTX (discontinuous transmission) for bandwidth savings during silence
    opus_encoder_ctl(encoder, OPUS_SET_DTX(1));

    LOGI("Opus encoder created: %d Hz, %d channels, %d kbps, %d ms frames",
         kSampleRate, kChannels, kBitrate / 1000, kFrameSizeMs);
}

OpusEncoder::~OpusEncoder() {
    if (encoder) {
        opus_encoder_destroy(encoder);
        encoder = nullptr;
    }
}

int OpusEncoder::encode(const int16_t* pcm, int numSamples, uint8_t* output, int maxOutputBytes) {
    if (!encoder) {
        LOGE("Encoder not initialized");
        return -1;
    }

    if (numSamples != kFrameSize) {
        LOGE("Invalid frame size: %d (expected %d)", numSamples, kFrameSize);
        return -1;
    }

    int encodedSize = opus_encode(encoder, pcm, kFrameSize, output, maxOutputBytes);
    if (encodedSize < 0) {
        LOGE("Opus encode error: %s", opus_strerror(encodedSize));
        return encodedSize;
    }

    return encodedSize;
}

// OpusDecoder implementation
OpusDecoder::OpusDecoder() : decoder(nullptr) {
    int error;
    decoder = opus_decoder_create(kSampleRate, kChannels, &error);
    if (error != OPUS_OK) {
        LOGE("Failed to create Opus decoder: %s", opus_strerror(error));
        decoder = nullptr;
        return;
    }

    LOGI("Opus decoder created: %d Hz, %d channels", kSampleRate, kChannels);
}

OpusDecoder::~OpusDecoder() {
    if (decoder) {
        opus_decoder_destroy(decoder);
        decoder = nullptr;
    }
}

int OpusDecoder::decode(const uint8_t* encoded, int encodedSize, int16_t* pcm, int maxSamples) {
    if (!decoder) {
        LOGE("Decoder not initialized");
        return -1;
    }

    int numSamples = opus_decode(decoder, encoded, encodedSize, pcm, maxSamples, 0);
    if (numSamples < 0) {
        LOGE("Opus decode error: %s", opus_strerror(numSamples));
        return numSamples;
    }

    return numSamples;
}
