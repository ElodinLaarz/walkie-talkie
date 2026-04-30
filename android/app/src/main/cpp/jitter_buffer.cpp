#include "jitter_buffer.h"

#include <utility>

bool JitterBuffer::push(uint32_t seq, const uint8_t* data, size_t size) {
    // Late: seq is strictly behind the playhead. Drop and count.
    if (playheadInit_ && seqLess(seq, playhead_)) {
        ++lateCount_;
        return false;
    }

    // Cold start: first frame seeds the playhead. We could pick any value
    // here (the caller's link is just starting), but anchoring at the first
    // received seq lets us reject genuine duplicates and replays from the
    // very next push without needing a separate "armed" state.
    if (!playheadInit_) {
        playhead_ = seq;
        playheadInit_ = true;
    }

    // Insert in modular-sorted order. Working window is small (<= kMaxDepth
    // = 10 frames) so a linear scan is faster than a tree.
    auto it = frames_.begin();
    while (it != frames_.end() && seqLess(it->seq, seq)) {
        ++it;
    }
    if (it != frames_.end() && it->seq == seq) {
        // Duplicate — first arrival wins (a re-transmit would be older or
        // the same payload; either way we don't gain by replacing).
        return false;
    }

    Frame f;
    f.seq = seq;
    f.opusData.assign(data, data + size);
    frames_.insert(it, std::move(f));
    return true;
}

std::optional<JitterBuffer::Frame> JitterBuffer::pop() {
    if (frames_.size() < targetDepth_) {
        ++underrunCount_;
        ++underrunsThisInterval_;
        return std::nullopt;
    }
    Frame f = std::move(frames_.front());
    frames_.pop_front();
    // Advance playhead. Use seq+1 rather than f.seq+1 to keep the meaning
    // ("next expected seq") even if the popped frame was non-contiguous —
    // the gap was already absorbed by whatever PLC ran during the underrun.
    playhead_ = f.seq + 1;
    return f;
}

std::optional<JitterBuffer::Frame> JitterBuffer::popAny() {
    if (frames_.empty()) {
        return std::nullopt;
    }
    Frame f = std::move(frames_.front());
    frames_.pop_front();
    playhead_ = f.seq + 1;
    return f;
}

void JitterBuffer::tick() {
    ++ticksThisInterval_;
    if (ticksThisInterval_ < audio_config::kJitterAdaptIntervalTicks) {
        return;
    }

    // End of an adaptation interval. Decide whether to grow / shrink.
    if (underrunsThisInterval_ > 0) {
        // Any underrun in the window: grow target depth, reset stability
        // counter. We grow conservatively (+1) rather than jumping to max —
        // the link may have just been transiently bad.
        if (targetDepth_ < audio_config::kJitterMaxDepth) {
            ++targetDepth_;
        }
        stableIntervalsCount_ = 0;
    } else {
        // Underrun-free interval. Count it; shrink only after the link has
        // proved itself across several intervals so a brief calm doesn't
        // shrink us right back into the danger zone.
        ++stableIntervalsCount_;
        const size_t shrinkAfter =
            audio_config::kJitterShrinkAfterStableTicks /
            audio_config::kJitterAdaptIntervalTicks;
        if (stableIntervalsCount_ >= shrinkAfter &&
            targetDepth_ > audio_config::kJitterMinDepth) {
            --targetDepth_;
            stableIntervalsCount_ = 0;
        }
    }

    ticksThisInterval_ = 0;
    underrunsThisInterval_ = 0;
}

void JitterBuffer::resetAdaptCounters() {
    ticksThisInterval_ = 0;
    underrunsThisInterval_ = 0;
    stableIntervalsCount_ = 0;
}

void JitterBuffer::reset() {
    frames_.clear();
    playheadInit_ = false;
    playhead_ = 0;
    targetDepth_ = audio_config::kJitterInitialDepth;
    resetAdaptCounters();
    // Lifetime counters intentionally retained for telemetry continuity
    // across a peer re-register.
}
