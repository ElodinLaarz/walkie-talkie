#ifndef JITTER_BUFFER_H
#define JITTER_BUFFER_H

#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <vector>

#include "audio_config.h"

// Adaptive per-peer jitter buffer for incoming Opus frames over BLE L2CAP CoC.
//
// **Why we need it.** L2CAP CoC delivery isn't smooth — frames burst at the
// connection-event boundary (CE jitter is 7.5–50 ms in practice), and the
// occasional CE collision drops a packet. A naive "decode-on-arrival" path
// glitches every time the host's CE shifts. The jitter buffer absorbs that
// variance at the cost of a small constant playout delay.
//
// **Design.** Frames are keyed by their over-the-wire `seq` (the protocol's
// per-link uint32). On `push`, frames slot into modular-sorted order. On
// `pop`, the oldest in-window frame is released only if the buffer's depth
// has reached its current target — otherwise we report an underrun and the
// caller runs PLC on the decoder. Late frames (seq before the current
// playhead) are dropped and counted.
//
// **Adaptive target depth.** `tick()` is called every mixer tick by the
// consumer; once per `kJitterAdaptIntervalTicks` it acts on the recent
// underrun count: if any underruns occurred in the window, target depth
// grows by one frame (capped at `kJitterMaxDepth`). If no underruns happened
// for `kJitterShrinkAfterStableTicks`, target depth shrinks by one (floored
// at `kJitterMinDepth`). Result: the buffer rides the smallest depth that
// doesn't glitch on the current link.
//
// **Cold-start handling.** Underruns are counted only after the buffer has
// been "primed" — i.e. has successfully released at least one frame to the
// consumer. Pre-priming pop()s return nullopt without touching the underrun
// counter. Post-priming, a continuous starvation episode counts as exactly
// one underrun (not one per tick), so an idle peer or a long talkspurt gap
// doesn't ratchet target depth upward in the absence of real network jitter.
//
// **Bounded memory.** `push()` enforces `kJitterMaxDepth`: if the buffer is
// already at the cap, the new frame is dropped (with a `lateFrameCount` bump
// for telemetry). This caps both memory and worst-case playout latency.
//
// **Threading.** This class is **not** thread-safe on its own. The caller
// must serialize all `push`/`pop`/`popAny`/`tick`/`reset` calls — typically
// via a per-peer mutex on the `PeerAudioManager::PeerState`. Stat-getter
// methods (`underrunCount`, etc.) read non-atomic counters and likewise
// require the same lock to be held by the caller.
//
// **Wraparound.** `seq` is uint32 and wraps. All ordering uses signed-int32
// modular arithmetic — `seqLess(a, b) := static_cast<int32_t>(a - b) < 0` —
// which is correct for any pair of seqs within ±2^31 of each other. With
// 20 ms frames at 16 kHz, 2^31 frames is ~497 days of monotonic transmit;
// well past any realistic session.
class JitterBuffer {
public:
    struct Frame {
        uint32_t seq{0};
        std::vector<uint8_t> opusData;
    };

    JitterBuffer() = default;

    // Insert a peer-arrived frame. Returns true if accepted, false if dropped:
    //   - older than the current playhead (counts toward `lateFrameCount`),
    //   - exact duplicate of an already-queued seq (first arrival wins; not
    //     counted as late, since this is a transport retransmit, not actual
    //     packet ordering trouble),
    //   - buffer already at `kJitterMaxDepth` (counts toward `lateFrameCount`
    //     so the link-quality reporter sees the overflow as a sustained
    //     mismatch between produce and consume rates).
    bool push(uint32_t seq, const uint8_t* data, size_t size);

    // Pop the next in-order frame for playback. Returns nullopt and
    // increments the underrun counter if the buffer hasn't filled to the
    // current target depth — caller should run PLC on the decoder.
    //
    // On success, advances the playhead so subsequent push()es of older
    // seqs are rejected as late.
    std::optional<Frame> pop();

    // Pop the oldest queued frame regardless of depth. Used when the caller
    // detects that PLC has run for several consecutive ticks and wants to
    // drain whatever was buffered (e.g. on transition out of a stall).
    // Returns nullopt only if the buffer is empty.
    std::optional<Frame> popAny();

    // Periodic adaptation. Call once per mixer tick. Internally counts ticks
    // and only performs depth changes every kJitterAdaptIntervalTicks. The
    // primed/inUnderrun gating in `pop()` prevents pre-priming starvation
    // from biasing the first adapt() decision, so this is safe to call from
    // tick zero.
    void tick();

    // Stats — read by the host's link-quality reporter (future PR will wire
    // these to the LinkQuality control-plane message).
    size_t underrunCount() const { return underrunCount_; }
    size_t lateFrameCount() const { return lateCount_; }
    size_t targetDepth() const { return targetDepth_; }
    size_t currentDepth() const { return frames_.size(); }
    bool playheadInitialized() const { return playheadInit_; }
    uint32_t playhead() const { return playhead_; }

    // Reset the rolling counters used by adapt(). Stats above continue to
    // accumulate for telemetry; this only affects adaptation decisions.
    void resetAdaptCounters();

    // Hard reset: clear queued frames and rolling state. Use on peer
    // unregister / re-register or on a session-level reset. Does NOT clear
    // lifetime stats (underrunCount, lateFrameCount).
    void reset();

private:
    // Modular-safe ordering predicate. a < b iff (b - a) is in (0, 2^31).
    static bool seqLess(uint32_t a, uint32_t b) {
        return static_cast<int32_t>(a - b) < 0;
    }

    std::deque<Frame> frames_;  // modular-sorted; front is oldest in-window.

    bool playheadInit_{false};
    uint32_t playhead_{0};   // next-expected seq

    size_t targetDepth_{audio_config::kJitterInitialDepth};

    // Priming + episode tracking. `primed_` flips to true on the first
    // successful `pop()` and never resets (a real client doesn't unprime
    // mid-session; on `reset()` we explicitly clear it). `inUnderrun_` flips
    // true when a primed pop misses, and false when a pop succeeds — so a
    // multi-tick starvation episode counts as exactly one underrun.
    bool primed_{false};
    bool inUnderrun_{false};

    // Lifetime stats.
    size_t underrunCount_{0};
    size_t lateCount_{0};

    // Adaptation rolling state.
    size_t ticksThisInterval_{0};
    size_t underrunsThisInterval_{0};
    size_t stableIntervalsCount_{0};  // consecutive intervals with 0 underruns
};

#endif  // JITTER_BUFFER_H
