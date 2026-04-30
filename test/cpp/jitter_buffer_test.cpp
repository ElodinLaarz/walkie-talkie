// Host-buildable test for the production jitter buffer.
//
// Pulls the production headers + .cpp directly so this is a real test of
// the shipped code, not a fork (the same lesson learned with mixer_test.cpp:
// fork drift is too easy). audio_config.h and jitter_buffer.{h,cpp} have no
// Android-NDK dependencies, so they compile cleanly under a host g++.
//
// Compile (see scripts/presubmit.sh and .github/workflows/flutter.yml):
//   g++ -std=c++17 -Wall -Wextra -pthread -I android/app/src/main/cpp
//       test/cpp/jitter_buffer_test.cpp android/app/src/main/cpp/jitter_buffer.cpp
//       -o build/cpp_test/jitter_buffer_test

#include "jitter_buffer.h"

#include <cassert>
#include <cstring>
#include <iostream>
#include <vector>

namespace {

// Helper: push a bunch of contiguous in-order frames to fill the buffer past
// the target depth so that pop() succeeds.
void seedAtDepth(JitterBuffer& jb, uint32_t startSeq, size_t count) {
    const uint8_t kFiller[2] = {0xab, 0xcd};
    for (size_t i = 0; i < count; ++i) {
        bool ok = jb.push(static_cast<uint32_t>(startSeq + i), kFiller, 2);
        assert(ok);
    }
}

void testColdStartDoesNotCountUnderruns() {
    JitterBuffer jb;
    // Empty buffer, no frames pushed. pop() returns nullopt but MUST NOT
    // count this as an underrun: the buffer hasn't been primed yet, so
    // we're not telling the adapter that the link is glitchy.
    for (int i = 0; i < 10; ++i) {
        auto f = jb.pop();
        assert(!f.has_value());
    }
    assert(jb.underrunCount() == 0);
    assert(jb.currentDepth() == 0);
    std::cout << "Test Cold Start Does Not Count Underruns: PASSED" << std::endl;
}

// Once playout has been primed, a continuous starvation episode counts as
// exactly one underrun — not one per tick. A peer that goes silent during
// a talkspurt gap shouldn't ratchet the target depth on every empty tick.
void testStarvationEpisodeCountsOnce() {
    JitterBuffer jb;
    // Prime the buffer.
    seedAtDepth(jb, 1, audio_config::kJitterInitialDepth);
    auto first = jb.pop();
    assert(first.has_value());
    assert(jb.underrunCount() == 0);

    // Drain everything else.
    while (jb.pop().has_value()) {
    }
    // The pop()s after the buffer drained were tracking starvation; they
    // should produce exactly one underrun, not one per call.
    assert(jb.underrunCount() == 1);

    // Continued empty pops while still in the same episode: still 1.
    for (int i = 0; i < 5; ++i) {
        auto f = jb.pop();
        assert(!f.has_value());
    }
    assert(jb.underrunCount() == 1);

    // New episode: feed the buffer back to target, drain, then starve again.
    seedAtDepth(jb, audio_config::kJitterInitialDepth + 1,
                audio_config::kJitterInitialDepth);
    while (jb.pop().has_value()) {
    }
    // Starvation re-armed; second episode increments the counter once.
    assert(jb.underrunCount() == 2);

    std::cout << "Test Starvation Episode Counts Once: PASSED" << std::endl;
}

// Hole-at-head: when the buffer has depth >= target but the seq the
// playhead expects isn't among the queued frames, pop() must return
// nullopt (so the caller PLCs that frame) and advance playhead by one.
// Regression test for the silent time-compression bug where pop() naively
// returned frames_.front() and skipped the lost slot.
void testHoleAtHeadProducesPLC() {
    JitterBuffer jb;
    const uint8_t data[1] = {0x33};

    // Push 100, 102, 103, 104 — seq 101 was lost. Depth (4) >= target (3)
    // so the depth-underrun branch doesn't fire; this isolates the hole
    // branch. Cold-start playhead = 100.
    assert(jb.push(100, data, 1));
    assert(jb.push(102, data, 1));
    assert(jb.push(103, data, 1));
    assert(jb.push(104, data, 1));

    // First pop: front=100, playhead=100. Match — release.
    auto p1 = jb.pop();
    assert(p1.has_value() && p1->seq == 100);
    assert(jb.underrunCount() == 0);

    // Second pop: depth=3 >= target=3, but front=102 and playhead=101.
    // Hole — return nullopt for PLC, advance playhead to 102, count
    // one underrun.
    auto p2 = jb.pop();
    assert(!p2.has_value());
    assert(jb.underrunCount() == 1);

    // Third pop: front=102, playhead=102. Match — release. The hole
    // recovery should clear inUnderrun_, so a later episode counts again.
    auto p3 = jb.pop();
    assert(p3.has_value() && p3->seq == 102);

    std::cout << "Test Hole At Head Produces PLC: PASSED" << std::endl;
}

// A multi-frame hole produces one nullopt per missing slot — paced to the
// playout clock, not a bulk skip — and counts as one starvation episode.
void testMultiFrameHoleProducesContiguousPLC() {
    JitterBuffer jb;
    const uint8_t data[1] = {0x77};
    // Lost: 11, 12. Present: 10, 13..16. Depth (5) >= target (3) so we
    // can keep popping through the hole without hitting the depth-underrun
    // branch.
    assert(jb.push(10, data, 1));
    assert(jb.push(13, data, 1));
    assert(jb.push(14, data, 1));
    assert(jb.push(15, data, 1));
    assert(jb.push(16, data, 1));

    auto p10 = jb.pop();
    assert(p10.has_value() && p10->seq == 10);

    // Two consecutive hole pops covering seqs 11, 12.
    auto h1 = jb.pop();
    assert(!h1.has_value());
    auto h2 = jb.pop();
    assert(!h2.has_value());

    // Recovery: front=13 now matches the advanced playhead.
    auto p13 = jb.pop();
    assert(p13.has_value() && p13->seq == 13);

    // Episode invariant: h1 and h2 belong to the same starvation episode,
    // counted exactly once.
    assert(jb.underrunCount() == 1);

    std::cout << "Test Multi-Frame Hole Produces Contiguous PLC: PASSED"
              << std::endl;
}

// push() must enforce kJitterMaxDepth. A stalled consumer or flooding
// producer can't grow the buffer without bound.
void testPushCapsAtMaxDepth() {
    JitterBuffer jb;
    const uint8_t data[1] = {0x42};
    // Fill to exactly the cap.
    for (size_t i = 0; i < audio_config::kJitterMaxDepth; ++i) {
        bool ok = jb.push(static_cast<uint32_t>(100 + i), data, 1);
        assert(ok);
    }
    assert(jb.currentDepth() == audio_config::kJitterMaxDepth);

    // Next push must be rejected (counts as late so telemetry sees the
    // overflow signal).
    bool ok = jb.push(
        static_cast<uint32_t>(100 + audio_config::kJitterMaxDepth),
        data, 1);
    assert(!ok);
    assert(jb.currentDepth() == audio_config::kJitterMaxDepth);
    assert(jb.lateFrameCount() == 1);

    std::cout << "Test Push Caps At Max Depth: PASSED" << std::endl;
}

void testNormalFlowAfterFilling() {
    JitterBuffer jb;
    // Fill exactly to initial target depth.
    seedAtDepth(jb, 100, audio_config::kJitterInitialDepth);

    // First pop should succeed (depth reached).
    auto f = jb.pop();
    assert(f.has_value());
    assert(f->seq == 100);
    assert(f->opusData.size() == 2);
    // After pop the depth dropped below target by one — but the playhead
    // also advanced, so the *next* push of a contiguous seq lands cleanly.
    seedAtDepth(jb, 100 + audio_config::kJitterInitialDepth, 1);
    // Now back to initial depth - 1 + 1 = initial depth. Still meets target.
    auto f2 = jb.pop();
    assert(f2.has_value());
    assert(f2->seq == 101);

    std::cout << "Test Normal Flow After Filling: PASSED" << std::endl;
}

void testLateFrameDropped() {
    JitterBuffer jb;
    seedAtDepth(jb, 10, audio_config::kJitterInitialDepth);
    // Pop one to advance the playhead past seq 10.
    auto f = jb.pop();
    assert(f.has_value() && f->seq == 10);
    // Late arrival of seq 5 must be rejected and counted.
    const uint8_t data[1] = {0x42};
    bool ok = jb.push(5, data, 1);
    assert(!ok);
    assert(jb.lateFrameCount() == 1);
    std::cout << "Test Late Frame Dropped: PASSED" << std::endl;
}

void testDuplicateRejected() {
    JitterBuffer jb;
    const uint8_t data[1] = {0x77};
    assert(jb.push(50, data, 1));
    // Same seq again — must be rejected (without counting as late).
    assert(!jb.push(50, data, 1));
    assert(jb.lateFrameCount() == 0);
    assert(jb.currentDepth() == 1);
    std::cout << "Test Duplicate Rejected: PASSED" << std::endl;
}

void testOutOfOrderInsertion() {
    JitterBuffer jb;
    const uint8_t data[1] = {0xa5};
    // Push 10, 12, 11 — must end up sorted 10, 11, 12.
    assert(jb.push(10, data, 1));
    assert(jb.push(12, data, 1));
    assert(jb.push(11, data, 1));

    seedAtDepth(jb, 13, audio_config::kJitterInitialDepth);  // top up

    auto f1 = jb.pop();
    assert(f1.has_value() && f1->seq == 10);
    auto f2 = jb.pop();
    assert(f2.has_value() && f2->seq == 11);
    auto f3 = jb.pop();
    assert(f3.has_value() && f3->seq == 12);

    std::cout << "Test Out-of-Order Insertion: PASSED" << std::endl;
}

void testAdaptGrowsOnUnderrun() {
    JitterBuffer jb;
    const size_t initial = jb.targetDepth();
    assert(initial == audio_config::kJitterInitialDepth);

    // Prime the buffer: underruns are only counted post-priming. Otherwise
    // the cold-start underruns we deliberately create below would be
    // ignored by the adapter (which is the desired behavior, but the test
    // here is exercising the post-priming path).
    seedAtDepth(jb, 1, audio_config::kJitterInitialDepth);
    auto primer = jb.pop();
    assert(primer.has_value());

    // Drain to cause a real underrun.
    while (jb.pop().has_value()) {
    }
    auto starve = jb.pop();
    assert(!starve.has_value());

    for (size_t i = 0; i < audio_config::kJitterAdaptIntervalTicks; ++i) {
        jb.tick();
    }
    // Target depth must have grown by at least 1.
    assert(jb.targetDepth() > initial);

    std::cout << "Test Adapt Grows On Underrun: PASSED" << std::endl;
}

void testAdaptShrinksAfterStability() {
    JitterBuffer jb;
    // Prime, then force a counted underrun, so the adapter grows targetDepth.
    seedAtDepth(jb, 1, audio_config::kJitterInitialDepth);
    auto primer = jb.pop();
    assert(primer.has_value());
    while (jb.pop().has_value()) {
    }
    auto starve = jb.pop();
    assert(!starve.has_value());

    for (size_t i = 0; i < audio_config::kJitterAdaptIntervalTicks; ++i) {
        jb.tick();
    }
    const size_t grownTarget = jb.targetDepth();
    assert(grownTarget > audio_config::kJitterInitialDepth);

    // Drain whatever stale frames remain from the priming phase so the
    // re-fill below doesn't run into the new max-depth cap.
    while (jb.popAny().has_value()) {
    }

    // Now drive enough underrun-free intervals to trigger a shrink. Keep the
    // buffer always above target so pop() never underruns. Ceil-divide so a
    // future bump to kJitterShrinkAfterStableTicks that isn't an exact
    // multiple of kJitterAdaptIntervalTicks doesn't quietly under-tick the
    // shrink threshold and fail the test for the wrong reason.
    const size_t shrinkAfter =
        (audio_config::kJitterShrinkAfterStableTicks +
         audio_config::kJitterAdaptIntervalTicks - 1) /
        audio_config::kJitterAdaptIntervalTicks;

    // Seed contiguously with the current playhead so pop() never triggers
    // hole detection. (If we picked an arbitrary nextSeq, the playhead would
    // chase it for hundreds of ticks before catching up, and every one of
    // those ticks would count as a hole-underrun.)
    uint32_t nextSeq = jb.playhead();
    seedAtDepth(jb, nextSeq, audio_config::kJitterMaxDepth);
    nextSeq += audio_config::kJitterMaxDepth;

    for (size_t interval = 0; interval < shrinkAfter; ++interval) {
        for (size_t i = 0; i < audio_config::kJitterAdaptIntervalTicks; ++i) {
            jb.tick();
            // Drain one frame and immediately push another to keep depth high.
            auto p = jb.pop();
            (void)p;
            seedAtDepth(jb, nextSeq++, 1);
        }
    }

    assert(jb.targetDepth() < grownTarget);

    std::cout << "Test Adapt Shrinks After Stability: PASSED" << std::endl;
}

void testWraparoundOrdering() {
    JitterBuffer jb;
    const uint8_t data[1] = {0x00};
    // Walk a contiguous run of seqs straight across the uint32 rollover.
    // Push one, popAny one — keeps depth low so no kJitterMaxDepth pressure
    // and exercises the seq comparator on every increment, including the
    // 0xFFFFFFFF -> 0x00000000 transition.
    //
    // (Earlier versions of this test relied on a pre-stuffed queue with a
    // giant gap that the new pop() hole-detection branch would now PLC
    // through one tick at a time — that's correct production behavior but
    // stops being a useful unit test of ordering. Walking contiguously
    // tests the wrap-comparator without entangling with hole detection.)
    assert(jb.push(0xFFFFFFF0u, data, 1));
    auto first = jb.popAny();
    assert(first.has_value() && first->seq == 0xFFFFFFF0u);

    for (uint32_t s = 0xFFFFFFF1u; s != 0x00000006u; ++s) {
        assert(jb.push(s, data, 1));
        auto pp = jb.popAny();
        assert(pp.has_value());
        assert(pp->seq == s);
    }

    // playhead is now 0x00000006 (next-expected after the last popped).
    // 0xFFFFFFF5u is ~17 frames "before" 0x00000006 by the modular
    // comparator, so it must be rejected as late and counted.
    const auto preLate = jb.lateFrameCount();
    bool late = jb.push(0xFFFFFFF5u, data, 1);
    assert(!late);
    assert(jb.lateFrameCount() == preLate + 1);

    std::cout << "Test Wraparound Ordering: PASSED" << std::endl;
}

void testPopAnyWhenBelowTarget() {
    JitterBuffer jb;
    const uint8_t data[1] = {0xee};
    assert(jb.push(7, data, 1));
    assert(jb.push(8, data, 1));
    // Below initial target (3); pop() returns nullopt.
    auto miss = jb.pop();
    assert(!miss.has_value());
    // popAny() returns the oldest queued frame regardless.
    auto got = jb.popAny();
    assert(got.has_value());
    assert(got->seq == 7);
    auto got2 = jb.popAny();
    assert(got2.has_value());
    assert(got2->seq == 8);
    auto empty = jb.popAny();
    assert(!empty.has_value());

    std::cout << "Test PopAny When Below Target: PASSED" << std::endl;
}

void testResetClearsQueueAndState() {
    JitterBuffer jb;
    const uint8_t data[1] = {0x12};
    seedAtDepth(jb, 1, audio_config::kJitterMaxDepth);
    auto p = jb.pop();
    (void)p;
    const auto preLate = jb.lateFrameCount();
    const auto preUnder = jb.underrunCount();

    jb.reset();
    assert(jb.currentDepth() == 0);
    assert(jb.targetDepth() == audio_config::kJitterInitialDepth);
    // Lifetime stats are intentionally retained.
    assert(jb.lateFrameCount() == preLate);
    assert(jb.underrunCount() == preUnder);

    // After reset, push of any seq is a fresh cold-start.
    bool ok = jb.push(999, data, 1);
    assert(ok);
    assert(jb.playheadInitialized());
    assert(jb.playhead() == 999);

    std::cout << "Test Reset Clears Queue And State: PASSED" << std::endl;
}

}  // namespace

int main() {
    try {
        testColdStartDoesNotCountUnderruns();
        testStarvationEpisodeCountsOnce();
        testHoleAtHeadProducesPLC();
        testMultiFrameHoleProducesContiguousPLC();
        testPushCapsAtMaxDepth();
        testNormalFlowAfterFilling();
        testLateFrameDropped();
        testDuplicateRejected();
        testOutOfOrderInsertion();
        testAdaptGrowsOnUnderrun();
        testAdaptShrinksAfterStability();
        testWraparoundOrdering();
        testPopAnyWhenBelowTarget();
        testResetClearsQueueAndState();
        std::cout << "All JitterBuffer tests passed!" << std::endl;
    } catch (const std::exception& e) {
        std::cerr << "Test failed: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
