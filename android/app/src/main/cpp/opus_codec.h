#ifndef OPUS_CODEC_H
#define OPUS_CODEC_H

#include <opus.h>
#include <vector>
#include <memory>
#include <cstdint>

class OpusEncoder {
private:
    ::OpusEncoder* encoder;
    static constexpr int kSampleRate = 16000;  // 16 kHz as per protocol
    static constexpr int kChannels = 1;        // Mono
    static constexpr int kFrameSizeMs = 20;    // 20 ms frames
    static constexpr int kFrameSize = (kSampleRate * kFrameSizeMs) / 1000;  // 320 samples
    static constexpr int kBitrate = 24000;     // 24 kbps as per protocol
    static constexpr int kMaxPacketSize = 4000;  // Max Opus packet size

public:
    OpusEncoder();
    ~OpusEncoder();

    // Encode 16-bit PCM samples to Opus. Returns encoded size, or negative on error.
    // Input: pcm with exactly kFrameSize (320) samples
    // Output: encoded data written to 'output', up to maxOutputBytes
    int encode(const int16_t* pcm, int numSamples, uint8_t* output, int maxOutputBytes);

    static constexpr int getFrameSize() { return kFrameSize; }
    static constexpr int getSampleRate() { return kSampleRate; }
};

class OpusDecoder {
private:
    ::OpusDecoder* decoder;
    static constexpr int kSampleRate = 16000;
    static constexpr int kChannels = 1;
    static constexpr int kFrameSize = 320;  // 20 ms at 16 kHz
    static constexpr int kMaxFrameSize = 5760;  // Max Opus frame size (120 ms at 48 kHz)

public:
    OpusDecoder();
    ~OpusDecoder();

    // Decode Opus packet to 16-bit PCM. Returns number of samples decoded, or negative on error.
    // Input: encoded Opus data
    // Output: decoded PCM written to 'pcm', up to maxSamples
    int decode(const uint8_t* encoded, int encodedSize, int16_t* pcm, int maxSamples);

    static constexpr int getFrameSize() { return kFrameSize; }
    static constexpr int getSampleRate() { return kSampleRate; }
};

#endif // OPUS_CODEC_H
