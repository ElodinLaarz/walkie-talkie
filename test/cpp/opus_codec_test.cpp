// Host-buildable test for OpusEncoder / OpusDecoder in opus_codec.cpp.
// Requires libopus (apt install libopus-dev on Ubuntu).
//
// Compile (see scripts/presubmit.sh and .github/workflows/flutter.yml).

#include "opus_codec.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;

// Generate one Opus frame (kCodecFrameSize samples) of a sine tone at
// `freqHz` sampled at kCodecSampleRate. Amplitude is at half-scale (16384)
// to match the convention in resampler_test and leave codec headroom.
std::vector<int16_t> makeSineFrame(double freqHz,
                                   int16_t amplitude = 16384) {
    const int n = audio_config::kCodecFrameSize;
    std::vector<int16_t> v(n);
    for (int i = 0; i < n; ++i) {
        double s = std::sin(2.0 * kPi * freqHz * i /
                            audio_config::kCodecSampleRate);
        v[i] = static_cast<int16_t>(amplitude * s);
    }
    return v;
}

double rms(const int16_t* x, int n) {
    double sum = 0.0;
    for (int i = 0; i < n; ++i) {
        double v = x[i] / 32768.0;
        sum += v * v;
    }
    return std::sqrt(sum / n);
}

}  // namespace

// ── Construction / teardown ───────────────────────────────────────────────────

void testEncoderDecoderConstruct() {
    OpusEncoder enc;
    OpusDecoder dec;
    // If the ctor fails it stores nullptr; encode/decode would return -1.
    // We exercise that indirectly by encoding a frame below.
    std::cout << "Test Encoder/Decoder Construct: PASSED" << std::endl;
}

// ── Round-trip fidelity with 1 kHz tone ──────────────────────────────────────
//
// Encode several frames then decode. After encoder warm-up the decoded RMS
// must be within 6 dB of the input RMS — a loose bound to accommodate lossy
// compression at 16 kbps while still detecting a silent or grossly distorted
// output.
//
// Note: DTX is enabled by default; a pure tone at nonzero amplitude is
// considered active speech, so Opus will always emit a real packet.
void testRoundTripFidelity1kHz() {
    OpusEncoder enc;
    OpusDecoder dec;

    const int frameSize = audio_config::kCodecFrameSize;
    std::vector<int16_t> pcmIn = makeSineFrame(1000.0);
    uint8_t encoded[audio_config::kMaxOpusPacketSize];
    std::vector<int16_t> pcmOut(frameSize, 0);

    double inputRms = rms(pcmIn.data(), frameSize);
    assert(inputRms > 0.0);

    // Warm up: encode/decode several frames to let the encoder settle.
    int encodedSize = 0;
    for (int i = 0; i < 5; ++i) {
        encodedSize = enc.encode(pcmIn.data(), frameSize, encoded,
                                 audio_config::kMaxOpusPacketSize);
        assert(encodedSize > 0);
        int decoded = dec.decode(encoded, encodedSize, pcmOut.data(), frameSize);
        assert(decoded == frameSize);
    }

    double outputRms = rms(pcmOut.data(), frameSize);
    // Output must be non-silent and within 6 dB of input (~factor of 2).
    assert(outputRms > inputRms / 2.0);
    assert(outputRms < inputRms * 2.0);
    std::cout << "Test Round-Trip Fidelity 1kHz (input RMS=" << inputRms
              << ", output RMS=" << outputRms << "): PASSED" << std::endl;
}

// ── encode() must return negative for wrong frame size ───────────────────────
void testEncodeRejectsWrongFrameSize() {
    OpusEncoder enc;
    uint8_t out[audio_config::kMaxOpusPacketSize];
    std::vector<int16_t> short_frame(audio_config::kCodecFrameSize - 1, 0);
    int ret = enc.encode(short_frame.data(),
                         audio_config::kCodecFrameSize - 1, out,
                         audio_config::kMaxOpusPacketSize);
    assert(ret < 0);
    std::cout << "Test Encode Rejects Wrong Frame Size: PASSED" << std::endl;
}

// ── setBitrate clamping ───────────────────────────────────────────────────────
void testSetBitrateClampsToRange() {
    OpusEncoder enc;
    // Below the floor — must be clamped to kBitrateLow.
    int result = enc.setBitrate(100);
    assert(result == audio_config::kBitrateLow);
    // Above the ceiling — must be clamped to kBitrateHigh.
    result = enc.setBitrate(1000000);
    assert(result == audio_config::kBitrateHigh);
    // Within range — must be accepted exactly.
    result = enc.setBitrate(audio_config::kBitrateMid);
    assert(result == audio_config::kBitrateMid);
    std::cout << "Test SetBitrate Clamps To Range: PASSED" << std::endl;
}

// ── PLC (decodeMissing) produces non-silent output after a real packet ────────
//
// After decoding one real frame, decodeMissing() should synthesise concealment
// audio. We only assert that it returns the correct frame count and that the
// concealment is not pure silence (Opus PLC extrapolates the prior signal).
void testDecodeMissingReturnsConcealedAudio() {
    OpusEncoder enc;
    OpusDecoder dec;

    const int frameSize = audio_config::kCodecFrameSize;
    std::vector<int16_t> pcmIn = makeSineFrame(1000.0);
    uint8_t encoded[audio_config::kMaxOpusPacketSize];

    // Prime the decoder with one real frame so PLC has state to extrapolate.
    int encodedSize = enc.encode(pcmIn.data(), frameSize, encoded,
                                 audio_config::kMaxOpusPacketSize);
    assert(encodedSize > 0);
    std::vector<int16_t> realOut(frameSize, 0);
    int decodedReal = dec.decode(encoded, encodedSize, realOut.data(), frameSize);
    assert(decodedReal == frameSize);

    // Now synthesise PLC for the next missing frame.
    std::vector<int16_t> plcOut(frameSize, 0);
    int plcSamples = dec.decodeMissing(plcOut.data(), frameSize);
    assert(plcSamples == frameSize);
    // PLC output must not be all-zero — Opus extrapolates from decoder state.
    double plcRms = rms(plcOut.data(), frameSize);
    assert(plcRms > 0.0);
    std::cout << "Test DecodeMissing Returns Concealed Audio (PLC RMS="
              << plcRms << "): PASSED" << std::endl;
}

// ── FEC: decodeFec simulates a lost-packet recovery scenario ─────────────────
//
// Standard usage: pkt1 is "lost" (never decoded), pkt2 arrives. We call
// decodeFec(pkt2) to get a recovered version of frame 1 from pkt2's FEC
// side-channel, then decode(pkt2) normally to get frame 2.
//
// With FEC enabled and loss > 0 the encoder embeds an LBRR copy of the
// previous frame; we verify decodeFec returns frameSize samples without
// crashing. Whether the result is FEC audio or PLC audio (when the encoder
// chose not to embed FEC at this bitrate) is not observable from the API —
// both paths are exercised by calling decodeFec without a prior decode call.
void testDecodeFecDoesNotCrash() {
    const int frameSize = audio_config::kCodecFrameSize;

    OpusEncoder enc;
    enc.setInbandFec(true);
    enc.setExpectedLossPct(30);

    // Encode two consecutive frames. pkt2 may carry an FEC copy of pkt1.
    std::vector<int16_t> pcmIn = makeSineFrame(1000.0);
    uint8_t pkt1[audio_config::kMaxOpusPacketSize];
    uint8_t pkt2[audio_config::kMaxOpusPacketSize];
    int sz1 = enc.encode(pcmIn.data(), frameSize, pkt1,
                         audio_config::kMaxOpusPacketSize);
    assert(sz1 > 0);
    int sz2 = enc.encode(pcmIn.data(), frameSize, pkt2,
                         audio_config::kMaxOpusPacketSize);
    assert(sz2 > 0);

    // Simulate a lost pkt1: skip decode(pkt1) and call decodeFec(pkt2)
    // directly. Opus uses either its FEC side-channel or PLC internally.
    OpusDecoder dec;
    std::vector<int16_t> fecOut(frameSize, 0);
    int fecSamples = dec.decodeFec(pkt2, sz2, fecOut.data(), frameSize);
    // Must return exactly frameSize samples — no crash, no truncation.
    assert(fecSamples == frameSize);

    // Then decode pkt2 normally to advance the decoder state.
    std::vector<int16_t> realOut(frameSize, 0);
    int decoded = dec.decode(pkt2, sz2, realOut.data(), frameSize);
    assert(decoded == frameSize);

    std::cout << "Test DecodeFec Does Not Crash: PASSED" << std::endl;
}

int main() {
    testEncoderDecoderConstruct();
    testRoundTripFidelity1kHz();
    testEncodeRejectsWrongFrameSize();
    testSetBitrateClampsToRange();
    testDecodeMissingReturnsConcealedAudio();
    testDecodeFecDoesNotCrash();
    std::cout << "\nAll OpusCodec tests passed." << std::endl;
    return 0;
}
