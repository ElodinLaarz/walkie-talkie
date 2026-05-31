#include "opus_codec.h"

#include <android/log.h>

#include <algorithm>

#define LOG_TAG "OpusCodec"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

OpusEncoder::OpusEncoder() : encoder_(nullptr) {
    int error = OPUS_OK;
    encoder_ = opus_encoder_create(audio_config::kCodecSampleRate,
                                   audio_config::kCodecChannels,
                                   OPUS_APPLICATION_VOIP, &error);
    if (error != OPUS_OK || encoder_ == nullptr) {
        LOGE("Failed to create Opus encoder: %s", opus_strerror(error));
        encoder_ = nullptr;
        return;
    }

    // Apply an encoder CTL and log on failure. The OPUS_SET_* macros expand
    // to (request, value), so they can't be passed through a wrapper function;
    // this macro keeps the call sites terse while surfacing setup errors that
    // would otherwise be silently ignored.
#define APPLY_ENC_CTL(ctl) \
    do { \
        int _e = opus_encoder_ctl(encoder_, ctl); \
        if (_e != OPUS_OK) { \
            LOGE("%s failed: %s", #ctl, opus_strerror(_e)); \
        } \
    } while (0)

    APPLY_ENC_CTL(OPUS_SET_BITRATE(currentBitrate_));

    // Max encoder complexity. The quality/CPU tradeoff is irrelevant on a
    // modern phone encoding one 20 ms mono frame per tick — spend the cycles.
    APPLY_ENC_CTL(OPUS_SET_COMPLEXITY(10));

    // Inband FEC (LBRR): embed a low-bitrate copy of the previous frame in
    // each packet so the decoder can reconstruct a lost frame from the next
    // one (see OpusDecoder::decodeFec). BLE L2CAP drops packets under RF
    // contention, and unrecovered drops are the main source of the "scratchy"
    // artifact. Seed the loss estimate at a non-zero baseline so the encoder
    // actually produces the LBRR side-channel from the first frame;
    // setExpectedLossPct() refines it later from link telemetry.
    APPLY_ENC_CTL(OPUS_SET_INBAND_FEC(1));
    APPLY_ENC_CTL(OPUS_SET_PACKET_LOSS_PERC(20));

    // DTX off: continuous transmission. DTX saves bandwidth by suppressing
    // silence, but the comfort-noise/restart transitions clip word onsets and
    // add artifacts. L2CAP has bandwidth to spare, so favour clean audio.
    APPLY_ENC_CTL(OPUS_SET_DTX(0));

#undef APPLY_ENC_CTL

    LOGI("Opus encoder created: %d Hz mono, %d kbps, %d ms frames, FEC on, DTX off",
         audio_config::kCodecSampleRate, currentBitrate_ / 1000,
         audio_config::kFrameDurationMs);
}

OpusEncoder::~OpusEncoder() {
    if (encoder_) {
        opus_encoder_destroy(encoder_);
        encoder_ = nullptr;
    }
}

int OpusEncoder::encode(const int16_t* pcm, int numSamples, uint8_t* output,
                        int maxOutputBytes) {
    if (!encoder_) {
        LOGE("Encoder not initialized");
        return -1;
    }
    if (numSamples != audio_config::kCodecFrameSize) {
        LOGE("Invalid frame size: %d (expected %d)", numSamples,
             audio_config::kCodecFrameSize);
        return -1;
    }
    int encodedSize = opus_encode(encoder_, pcm, audio_config::kCodecFrameSize,
                                  output, maxOutputBytes);
    if (encodedSize < 0) {
        LOGE("Opus encode error: %s", opus_strerror(encodedSize));
    }
    return encodedSize;
}

int OpusEncoder::setBitrate(int bps) {
    if (!encoder_) return -1;
    int clamped =
        std::max(audio_config::kBitrateLow,
                 std::min(audio_config::kBitrateHigh, bps));
    if (clamped == currentBitrate_) {
        return clamped;
    }
    int err = opus_encoder_ctl(encoder_, OPUS_SET_BITRATE(clamped));
    if (err != OPUS_OK) {
        LOGE("OPUS_SET_BITRATE(%d) failed: %s", clamped, opus_strerror(err));
        return currentBitrate_;
    }
    LOGI("Encoder bitrate %d -> %d bps", currentBitrate_, clamped);
    currentBitrate_ = clamped;
    return clamped;
}

void OpusEncoder::setExpectedLossPct(int pct) {
    if (!encoder_) return;
    int clamped = std::max(0, std::min(100, pct));
    opus_encoder_ctl(encoder_, OPUS_SET_PACKET_LOSS_PERC(clamped));
}

void OpusEncoder::setInbandFec(bool enabled) {
    if (!encoder_) return;
    opus_encoder_ctl(encoder_, OPUS_SET_INBAND_FEC(enabled ? 1 : 0));
}

OpusDecoder::OpusDecoder() : decoder_(nullptr) {
    int error = OPUS_OK;
    decoder_ = opus_decoder_create(audio_config::kCodecSampleRate,
                                   audio_config::kCodecChannels, &error);
    if (error != OPUS_OK || decoder_ == nullptr) {
        LOGE("Failed to create Opus decoder: %s", opus_strerror(error));
        decoder_ = nullptr;
        return;
    }
    LOGI("Opus decoder created: %d Hz mono", audio_config::kCodecSampleRate);
}

OpusDecoder::~OpusDecoder() {
    if (decoder_) {
        opus_decoder_destroy(decoder_);
        decoder_ = nullptr;
    }
}

int OpusDecoder::decode(const uint8_t* encoded, int encodedSize, int16_t* pcm,
                        int maxSamples) {
    if (!decoder_) {
        LOGE("Decoder not initialized");
        return -1;
    }
    int numSamples = opus_decode(decoder_, encoded, encodedSize, pcm,
                                 maxSamples, /*decode_fec=*/0);
    if (numSamples < 0) {
        LOGE("Opus decode error: %s", opus_strerror(numSamples));
    }
    return numSamples;
}

int OpusDecoder::decodeMissing(int16_t* pcm, int frameSize) {
    if (!decoder_) return -1;
    // opus_decode with NULL payload synthesizes PLC — the documented way to
    // conceal a missing packet when the FEC side-channel is also unavailable.
    int numSamples = opus_decode(decoder_, nullptr, 0, pcm, frameSize,
                                 /*decode_fec=*/0);
    if (numSamples < 0) {
        LOGE("Opus PLC decode error: %s", opus_strerror(numSamples));
    }
    return numSamples;
}

int OpusDecoder::decodeFec(const uint8_t* nextPacket, int nextSize,
                           int16_t* pcm, int frameSize) {
    if (!decoder_) return -1;
    // Pass the *next* packet but ask Opus to emit the LBRR side-channel that
    // packet carries for the *previous* frame. Returns negative if the packet
    // doesn't contain FEC for the requested frame size — caller should fall
    // back to decodeMissing in that case.
    int numSamples = opus_decode(decoder_, nextPacket, nextSize, pcm, frameSize,
                                 /*decode_fec=*/1);
    if (numSamples < 0) {
        // Not necessarily an error — many packets won't carry FEC. Logged at
        // info to help tune setExpectedLossPct without spamming on every miss.
        LOGI("Opus FEC unavailable: %s", opus_strerror(numSamples));
    }
    return numSamples;
}
