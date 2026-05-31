#ifndef AUDIO_CONFIG_H
#define AUDIO_CONFIG_H

#include <cstddef>
#include <cstdint>

// Single source of truth for sample rates, frame sizes, and audio-pipeline
// constants. Three rates exist in the pipeline and conflating them was the
// source of the original "chipmunk audio" bug:
//
//   - kPlayoutSampleRate (48 kHz): what Oboe captures and plays back. Phones
//     prefer 48 kHz for hardware-mixer alignment; we follow.
//   - kCodecSampleRate (24 kHz): what Opus and the mix-minus matrix run at.
//     Opus super-wideband — 12 kHz audio bandwidth covers the full speech
//     range plus presence, a clear step up from the old 16 kHz wideband.
//     Easily fits BLE L2CAP CoC bandwidth at 32 kbps.
//   - The bridge is a 2:1 polyphase resampler (see resampler.h).
//
// Frame size (20 ms) is the same wall-clock duration on both sides — one Oboe
// callback of 960 samples @ 48 kHz downsamples to exactly one Opus frame of
// 480 samples @ 24 kHz, so there is no fractional-frame bookkeeping in the
// hot path.
namespace audio_config {

// Playout (Oboe streams).
constexpr int kPlayoutSampleRate = 48000;
constexpr int kPlayoutChannels = 1;

// Codec / mixer / wire.
constexpr int kCodecSampleRate = 24000;
constexpr int kCodecChannels = 1;

// Frame duration. 20 ms is the Opus VoIP default and divides cleanly at both
// 48 kHz (960 samples) and 24 kHz (480 samples).
constexpr int kFrameDurationMs = 20;
constexpr int kPlayoutFrameSize =
    (kPlayoutSampleRate * kFrameDurationMs) / 1000;  // 960
constexpr int kCodecFrameSize =
    (kCodecSampleRate * kFrameDurationMs) / 1000;  // 480

// Opus's documented worst-case PCM output: 120 ms @ 48 kHz. Used to size
// scratch buffers so a malformed peer frame can't overflow.
constexpr int kCodecMaxFrameSize = 5760;

// Resampler ratio. Keep playout/codec rates in lockstep with this.
static_assert(kPlayoutSampleRate % kCodecSampleRate == 0,
              "playout rate must be an integer multiple of codec rate");
constexpr int kResampleRatio = kPlayoutSampleRate / kCodecSampleRate;  // 2

// Default Opus parameters. The three operating points are what the dynamic
// bitrate scaler picks between based on link telemetry — a future PR wires
// LinkQuality reports to this; today the encoder starts at kBitrateMid and
// nothing adjusts it yet. BLE L2CAP CoC sustains well over 100 kbps, so these
// are sized for quality first: even kBitrateHigh (48 kbps) is a fraction of
// the link budget. Opus at 24 kHz / 32 kbps is transparent for speech.
constexpr int kBitrateLow = 16000;    // degraded link
constexpr int kBitrateMid = 32000;    // default — transparent super-wideband
constexpr int kBitrateHigh = 48000;   // best link, fullband-grade voice
constexpr int kDefaultBitrate = kBitrateMid;
constexpr int kMaxOpusPacketSize = 4000;

// Adaptive jitter buffer bounds. Depth is measured in 20 ms frames.
//   - kJitterMinDepth=2 → 40 ms playout latency floor (one tick of slack)
//   - kJitterInitialDepth=3 → 60 ms, the BLE CE-jitter sweet spot
//   - kJitterMaxDepth=10 → 200 ms ceiling. Above this the user notices.
constexpr size_t kJitterMinDepth = 2;
constexpr size_t kJitterInitialDepth = 3;
constexpr size_t kJitterMaxDepth = 10;

// How often the jitter buffer reviews its target depth, in adapt() calls.
// adapt() is invoked from the mixer tick (every kFrameDurationMs ms), so
// 50 calls ≈ 1 second between adaptation decisions.
constexpr size_t kJitterAdaptIntervalTicks = 50;

// Stable underrun-free duration before the jitter buffer shrinks one frame.
// 500 ticks ≈ 10 s — long enough that a single CE hiccup doesn't shrink the
// buffer right back into the ground.
constexpr size_t kJitterShrinkAfterStableTicks = 500;

// Mixer tick.
constexpr int kMixerTickIntervalMs = kFrameDurationMs;

}  // namespace audio_config

#endif  // AUDIO_CONFIG_H
