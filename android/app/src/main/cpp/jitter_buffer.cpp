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
    // = 10 frames) so a linear scan is faster than a tree. We do the dup
    // check BEFORE the cap check so a retransmit of an already-queued seq
    // doesn't incorrectly bump lateCount_ — that counter signals "buffer
    // overflow" to the link-quality reporter, and a benign retransmit isn't
    // an overflow.
    auto it = frames_.begin();
    while (it != frames_.end() && seqLess(it->seq, seq)) {
        ++it;
    }
    if (it != frames_.end() && it->seq == seq) {
        // Duplicate — first arrival wins. Don't count as late: a dup is a
        // transport retransmit, not actual ordering trouble.
        return false;
    }

    // Bounded memory + bounded playout latency. At the cap, the consumer is
    // behind (clock drift, a stalled tick) or the producer is bursting (e.g. a
    // kernel L2CAP TX backlog draining all at once on link recovery). Favour
    // the freshest audio: evict the OLDEST queued frame to admit this newer
    // arrival, rather than rejecting the arrival and pinning playout at the
    // stale head. lateCount_ still records the overflow for telemetry.
    //
    // Exception: if the arrival is itself older than the oldest queued frame
    // (seqLess(seq, front)), IT is the stale one — drop it and keep what we
    // have. (We already rejected frames behind the playhead above; this guards
    // the narrower "newer than playhead but older than everything buffered"
    // case.)
    if (frames_.size() >= audio_config::kJitterMaxDepth) {
        ++lateCount_;
        if (seqLess(seq, frames_.front().seq)) {
            return false;
        }
        const uint32_t droppedSeq = frames_.front().seq;
        frames_.pop_front();
        // Only advance the playhead when the evicted frame is exactly the one
        // we were about to play — then the deliberate skip isn't miscounted as
        // a hole-at-head (network loss). When there is already a hole at the
        // head (droppedSeq > playhead_), the intervening seqs are genuine
        // losses that pop() must still count and PLC-pace; advancing the
        // playhead over them would hide real loss from the bitrate adapter.
        // (front is never behind the playhead — arrivals before it are rejected
        // as late — so droppedSeq >= playhead_ always; equality is the
        // contiguous case.)
        if (playheadInit_ && droppedSeq == playhead_) {
            ++playhead_;
        }
        // pop_front() invalidated `it`; recompute the insertion point.
        it = frames_.begin();
        while (it != frames_.end() && seqLess(it->seq, seq)) {
            ++it;
        }
    }

    Frame f;
    f.seq = seq;
    f.opusData.assign(data, data + size);
    frames_.insert(it, std::move(f));
    return true;
}

std::optional<JitterBuffer::Frame> JitterBuffer::pop() {
    if (frames_.size() < targetDepth_) {
        // Buffer-underrun: too few frames to release. Count only after
        // priming, and only on the *transition* into starvation. This
        // prevents two failure modes:
        //   1. Cold-start: pop() loops on an empty buffer for many ticks
        //      before the first frame arrives — we shouldn't ratchet the
        //      target depth up because of those, since they're a fact of
        //      the link starting, not a sign of network jitter.
        //   2. Talkspurt gap: a peer goes silent (DTX) for several ticks;
        //      every tick is technically an underrun but it's one episode,
        //      so it counts once.
        if (primed_ && !inUnderrun_) {
            ++underrunCount_;
            ++underrunsThisInterval_;
            inUnderrun_ = true;
        }
        return std::nullopt;
    }

    // Hole-at-head: the buffer has enough frames but the seq we're expecting
    // (playhead_) isn't among them. The expected seq was lost in transit.
    // Return nullopt so the caller runs PLC for one frame and advance the
    // playhead by exactly one — the next tick will release the queued frame
    // (or detect another hole if more than one was lost in a row).
    //
    // We deliberately don't bulk-advance: a 3-frame hole produces 3 PLC
    // ticks paced to the playout clock, which is the correct way to mask
    // loss. Bulk-advancing would skip directly to the next queued frame
    // and time-compress audio, which is exactly the bug this branch fixes.
    if (playheadInit_ && seqLess(playhead_, frames_.front().seq)) {
        // The expected seq was never received even though the buffer is full
        // enough to play — this is confirmed packet loss, not a capacity or
        // jitter artifact. Count every missing seq (a 3-frame hole fires this
        // branch three times, once per advanced playhead), unlike the
        // episode-gated underrun counter: the bitrate adapter wants the true
        // per-frame loss rate.
        ++lostCount_;
        if (primed_ && !inUnderrun_) {
            ++underrunCount_;
            ++underrunsThisInterval_;
            inUnderrun_ = true;
        }
        ++playhead_;
        return std::nullopt;
    }

    Frame f = std::move(frames_.front());
    frames_.pop_front();
    // playhead_ tracks the next expected seq from this peer. Advance to
    // f.seq + 1 (modular increment is fine; uint32 overflow is the wrap
    // path the rest of this class is built around).
    playhead_ = f.seq + 1;
    primed_ = true;
    inUnderrun_ = false;
    return f;
}

std::optional<JitterBuffer::Frame> JitterBuffer::popAny() {
    if (frames_.empty()) {
        return std::nullopt;
    }
    Frame f = std::move(frames_.front());
    frames_.pop_front();
    playhead_ = f.seq + 1;
    // popAny still counts as primed — the consumer got real audio out.
    primed_ = true;
    inUnderrun_ = false;
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
        // the link may have just been transiently bad. The ceiling is
        // kJitterMaxTargetDepth (NOT kJitterMaxDepth): the adaptive target
        // must not ratchet playout latency up to the hard cap, where the
        // buffer would ride the overflow boundary and hard-drop every fresh
        // frame. Sustained over-fill past the target is the time-scaling
        // drain's job, not the target's.
        if (targetDepth_ < audio_config::kJitterMaxTargetDepth) {
            ++targetDepth_;
        }
        stableIntervalsCount_ = 0;
    } else {
        // Underrun-free interval. Count it; shrink only after the link has
        // proved itself across several intervals so a brief calm doesn't
        // shrink us right back into the danger zone.
        ++stableIntervalsCount_;
        // Ceil-divide so a future bump of kJitterShrinkAfterStableTicks to
        // a non-multiple of kJitterAdaptIntervalTicks doesn't quietly cause
        // the buffer to shrink one interval earlier than configured. The
        // host test (testAdaptShrinksAfterStability) uses the same formula.
        const size_t shrinkAfter =
            (audio_config::kJitterShrinkAfterStableTicks +
             audio_config::kJitterAdaptIntervalTicks - 1) /
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

void JitterBuffer::resyncPlayheadIfEmpty(uint32_t seq) {
    // Only safe while empty: with frames queued, pop() would clobber the
    // playhead from the front frame's seq anyway, and we could strand a
    // queued frame behind an advanced playhead.
    if (!frames_.empty()) {
        return;
    }
    // Never rewind: if seq is already behind the playhead, leave it.
    if (playheadInit_ && seqLess(seq, playhead_)) {
        return;
    }
    playhead_ = seq;
    playheadInit_ = true;
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
    primed_ = false;
    inUnderrun_ = false;
    resetAdaptCounters();
    // Lifetime counters intentionally retained for telemetry continuity
    // across a peer re-register.
}
