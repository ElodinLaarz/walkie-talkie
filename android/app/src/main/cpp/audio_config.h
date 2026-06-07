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
//   - kJitterMaxTargetDepth=6 → 120 ms. Ceiling the *adaptive target depth*
//     may ratchet to. Capped well below the hard cap so a jittery link can't
//     ratchet playout latency to kJitterMaxDepth (the old death spiral: the
//     target grew to 10, the buffer rode the cap, and every fresh frame
//     overflowed → a flood of late-drops). Backlog past this is drained by
//     the decode-path time-scaling, not by growing latency.
//   - kJitterHighWatermark=8 → 160 ms. When the *current* fill reaches this,
//     the producer's 50 Hz clock is outrunning our 50 Hz consume clock (the
//     two domains are unsynced). The decode pass time-compresses one extra
//     frame per tick (crossfade-merge) to drain the backlog smoothly instead
//     of letting it pile up to the hard cap and hard-drop.
//   - kJitterMaxDepth=10 → 200 ms hard cap / push backstop. With the drain
//     active the buffer should rarely reach this; it stays as a memory and
//     worst-case-latency bound.
constexpr size_t kJitterMinDepth = 2;
constexpr size_t kJitterInitialDepth = 3;
constexpr size_t kJitterMaxTargetDepth = 6;
constexpr size_t kJitterHighWatermark = 8;
constexpr size_t kJitterMaxDepth = 10;

static_assert(kJitterMinDepth <= kJitterInitialDepth &&
                  kJitterInitialDepth <= kJitterMaxTargetDepth &&
                  kJitterMaxTargetDepth < kJitterHighWatermark &&
                  kJitterHighWatermark < kJitterMaxDepth,
              "jitter thresholds must be ordered: "
              "min <= init <= maxTarget < highWatermark < maxDepth");

// How often the jitter buffer reviews its target depth, in adapt() calls.
// adapt() is invoked from the mixer tick (every kFrameDurationMs ms), so
// 50 calls ≈ 1 second between adaptation decisions.
constexpr size_t kJitterAdaptIntervalTicks = 50;

// Stable underrun-free duration before the jitter buffer shrinks one frame.
// 500 ticks ≈ 10 s — long enough that a single CE hiccup doesn't shrink the
// buffer right back into the ground.
constexpr size_t kJitterShrinkAfterStableTicks = 500;

// Playout anti-bloat (latency catch-up). The per-device mixer ring is the
// rendezvous between the producer (decode / mic feed, ~50 Hz on a steady_clock)
// and the consumer (the Oboe playout callback, on the audio *hardware* clock).
// Those two clocks are not synchronised, so left unbounded the ring drifts
// toward full (its physical capacity is ~680 ms at the codec rate) and *stays*
// there — pinning everything you hear that far behind real time, and on a link
// stall it then faithfully replays the stale backlog instead of catching up.
//
// The playout consumer caps the ring: before mixing, it drops the oldest
// samples so no more than this many remain, always favouring the freshest
// audio. A small drift trims a few samples per callback; a big burst (e.g. a
// kernel L2CAP TX backlog draining all at once on recovery) is dropped in one
// shot — so this single mechanism is both the continuous cap and the hard
// catch-up. 3 frames = 60 ms: enough slack to ride out callback jitter without
// underrunning, far below the ring's physical capacity.
constexpr size_t kPlayoutMaxRingFillFrames = 3;
constexpr size_t kPlayoutMaxRingFillSamples =
    kPlayoutMaxRingFillFrames * static_cast<size_t>(kCodecFrameSize);  // 1440

// Mixer tick.
constexpr int kMixerTickIntervalMs = kFrameDurationMs;

// End-to-end staleness (Kevin's timestamp-drop). The receiver derives a frame's
// staleness from the VoiceFrame `senderTsMs` versus local arrival, baselined
// against a sliding-window minimum to cancel the unknown cross-device clock
// offset (see playout_lag_estimator.h).
//   - kLagBaselineWindowMs: how far back the "best recent transit" baseline
//     looks. Long enough to span a talkspurt and ride out slow clock drift,
//     short enough that a backlog that builds within it still surfaces as
//     excess. 5 s.
//   - kStaleDropBudgetMs: a frame whose transit sits more than this above the
//     baseline is too late to be worth playing and is dropped before decode
//     (guarded so we never starve the last available frame into silence). Fixed
//     at 200 ms — deliberately not adapted to channel quality (that complexity
//     isn't worth it here).
constexpr uint32_t kLagBaselineWindowMs = 5000;
constexpr uint32_t kStaleDropBudgetMs = 200;

}  // namespace audio_config

#endif  // AUDIO_CONFIG_H
