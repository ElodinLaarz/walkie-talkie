#ifndef PLAYOUT_LAG_ESTIMATOR_H
#define PLAYOUT_LAG_ESTIMATOR_H

#include <cstdint>
#include <deque>

#include "audio_config.h"

// Estimates per-peer end-to-end playout staleness from the VoiceFrame's
// `senderTsMs` (the sender's encode-time on a MONOTONIC clock —
// `SystemClock.elapsedRealtime`, low 32 bits of ms-since-boot, NOT wall-clock)
// and the local arrival time.
//
// **Why this is not just `now - senderTsMs`.** `senderTsMs` and the local
// arrival time come from two *different* monotonic clocks (sender:
// SystemClock.elapsedRealtime; receiver: steady_clock), each with its own
// arbitrary epoch — so the raw difference `arrival - senderTsMs` carries an
// unknown constant offset (and the best-case one-way transit). That absolute
// number is meaningless on its own. What *is* meaningful is how far a given
// frame sits **above the best recent frame**: that excess is real
// queuing/backlog delay (e.g. a frame that languished seconds in the sender's
// kernel L2CAP TX buffer), independent of the offset. Both clocks are
// monotonic, so neither jumps under NTP — only their (constant) difference
// matters, and the window cancels it.
//
// **Method.** Maintain the minimum of `rawDelay = arrival - senderTsMs` over a
// sliding time window (`kLagBaselineWindowMs`). The offset cancels in the
// subtraction, so `excess = rawDelay - windowMin` is a clock-sync-free measure
// of staleness in milliseconds. A call that "starts clean then degrades" seeds
// the baseline during the good period, so the later backlog surfaces as a
// growing excess. Slow clock drift between the crystals is tracked out by the
// sliding window (a stale lifetime-min would otherwise drift the baseline).
//
// **Wraparound.** `senderTsMs` is uint32 and wraps every ~49.7 days; `rawDelay`
// is computed as a signed int32 modular difference, which is correct for any
// pair within ±2^31 ms of each other — far beyond the few-second spread within
// one window.
//
// **Threading.** Not thread-safe; the caller serialises feeds (the receive
// path is single-producer per peer). Cheap: O(1) amortised per feed via a
// monotonic deque.
class PlayoutLagEstimator {
public:
    PlayoutLagEstimator() = default;

    // Record a frame arrival and return its staleness in ms: how far this
    // frame's transit delay sits above the best frame seen in the last
    // kLagBaselineWindowMs. Always >= 0. `recvMs` must be non-decreasing
    // across calls (a monotonic local clock, e.g. steady_clock ms).
    int64_t feed(uint32_t senderTsMs, int64_t recvMs) {
        const int32_t rawDelay = static_cast<int32_t>(
            static_cast<uint32_t>(recvMs) - senderTsMs);

        // Monotonic-min deque: keep delays increasing front->back so the front
        // is always the window minimum. Drop larger trailing entries the new
        // sample dominates.
        while (!window_.empty() && window_.back().rawDelay >= rawDelay) {
            window_.pop_back();
        }
        window_.push_back({recvMs, rawDelay});
        // Evict samples older than the baseline window.
        const int64_t cutoff =
            recvMs - static_cast<int64_t>(audio_config::kLagBaselineWindowMs);
        while (!window_.empty() && window_.front().recvMs < cutoff) {
            window_.pop_front();
        }

        baselineRawDelay_ = window_.front().rawDelay;
        lastExcessMs_ = static_cast<int64_t>(rawDelay) - baselineRawDelay_;
        return lastExcessMs_;
    }

    // Staleness of the most recent feed(), in ms (>= 0).
    int64_t lastExcessMs() const { return lastExcessMs_; }

    // True if `excessMs` exceeds the drop budget — the frame is too stale to be
    // worth playing. The no-silence guard (never drop the only available
    // frame) lives at the call site, not here.
    static bool isStale(int64_t excessMs) {
        return excessMs > static_cast<int64_t>(audio_config::kStaleDropBudgetMs);
    }

    void reset() {
        window_.clear();
        baselineRawDelay_ = 0;
        lastExcessMs_ = 0;
    }

private:
    struct Sample {
        int64_t recvMs;
        int32_t rawDelay;
    };
    std::deque<Sample> window_;
    int32_t baselineRawDelay_{0};
    int64_t lastExcessMs_{0};
};

#endif  // PLAYOUT_LAG_ESTIMATOR_H
