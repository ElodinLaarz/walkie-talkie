#ifndef OPUS_CODEC_H
#define OPUS_CODEC_H

#include <opus.h>
#include <cstdint>
#include <memory>
#include <vector>

#include "audio_config.h"

// Opus voice codec — encoder/decoder pair for one peer link.
//
// Sample rate, channel count, and frame size live in audio_config.h. They
// match the wire protocol (16 kHz mono / 20 ms frames) and the mixer's
// internal rate. The codec does NOT see the 48 kHz Oboe rate; the resampler
// in audio_engine.cpp bridges the two.
//
// **Dynamic bitrate.** The encoder starts at audio_config::kDefaultBitrate.
// Callers can shift between {Low, Mid, High} via setBitrate() based on link
// telemetry — a future PR will wire the LinkQuality control message to this
// path. Bitrates outside the kBitrateLow .. kBitrateHigh range are clamped.
//
// **FEC.** Inband FEC (LBRR) is enabled at construction. setExpectedLossPct
// tells Opus how aggressively to allocate bandwidth to the side-channel; pair
// with the decoder's decodeFec() entry point to actually use it.
//
// **PLC.** decodeMissing() generates one frame of packet-loss concealment
// (the buffer fill) using opus_decode(NULL, 0, ...). decodeFec() generates
// one frame using the FEC side-channel of the *next* arriving packet.

class OpusEncoder {
public:
    OpusEncoder();
    ~OpusEncoder();

    OpusEncoder(const OpusEncoder&) = delete;
    OpusEncoder& operator=(const OpusEncoder&) = delete;

    // Encode 16-bit PCM samples to Opus. Returns encoded size, or negative
    // on error. `numSamples` must be exactly audio_config::kCodecFrameSize.
    int encode(const int16_t* pcm, int numSamples, uint8_t* output,
               int maxOutputBytes);

    // Set the encoder bitrate. Clamped to [kBitrateLow, kBitrateHigh].
    // Returns the actual bitrate applied.
    int setBitrate(int bps);

    // Tell Opus how much packet loss to expect, as a percentage [0, 100].
    // Drives FEC bandwidth allocation; a value of 0 silences the FEC side-
    // channel entirely. Idempotent.
    void setExpectedLossPct(int pct);

    // Toggle inband FEC. Called from the constructor with `true`; exposed
    // so a future low-bandwidth mode can disable it explicitly.
    void setInbandFec(bool enabled);

    static constexpr int getFrameSize() {
        return audio_config::kCodecFrameSize;
    }
    static constexpr int getSampleRate() {
        return audio_config::kCodecSampleRate;
    }

private:
    ::OpusEncoder* encoder_;
    int currentBitrate_{audio_config::kDefaultBitrate};
};

class OpusDecoder {
public:
    OpusDecoder();
    ~OpusDecoder();

    OpusDecoder(const OpusDecoder&) = delete;
    OpusDecoder& operator=(const OpusDecoder&) = delete;

    // Decode Opus packet to 16-bit PCM. Returns number of samples decoded,
    // or negative on error. `maxSamples` should be at least
    // audio_config::kCodecMaxFrameSize to handle the worst-case Opus frame.
    int decode(const uint8_t* encoded, int encodedSize, int16_t* pcm,
               int maxSamples);

    // Generate one frame of PLC for a missing packet. `frameSize` must be a
    // valid Opus frame length at the codec sample rate (commonly
    // audio_config::kCodecFrameSize for 20 ms). Returns the number of
    // samples written, or negative on error.
    //
    // Use this when the jitter buffer underruns and no FEC side-channel is
    // available (i.e. the next packet hasn't arrived yet). The output is
    // a smoothly decaying extrapolation of the prior decoded audio — it
    // sounds OK for one or two consecutive frames but degrades after that.
    int decodeMissing(int16_t* pcm, int frameSize);

    // Generate one frame of audio from the FEC side-channel of `nextPacket`.
    // Use this when a packet arrives whose seq is `playhead + 1` and you
    // know `playhead` itself was missed: Opus's FEC carries a low-bitrate
    // copy of the *previous* frame inside each packet. Returns number of
    // samples written, or negative on error (including when the next packet
    // had no FEC side-channel — caller should fall back to decodeMissing).
    int decodeFec(const uint8_t* nextPacket, int nextSize, int16_t* pcm,
                  int frameSize);

    static constexpr int getFrameSize() {
        return audio_config::kCodecFrameSize;
    }
    static constexpr int getSampleRate() {
        return audio_config::kCodecSampleRate;
    }

private:
    ::OpusDecoder* decoder_;
};

#endif  // OPUS_CODEC_H
