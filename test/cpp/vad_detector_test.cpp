// Unit tests for VadDetector — the two-sided VAD hysteresis state machine
// extracted from audio_engine.cpp.
//
// All tests run at 48 kHz with the default constants:
//   - on  hysteresis: 100 ms = 4800 frames @ 48 kHz
//   - off hysteresis: 300 ms = 14400 frames @ 48 kHz
//
// Tests exercise the acceptance criteria from issue #248:
//   - Talking state is entered only after the on-hysteresis window.
//   - Silence state is entered only after the off-hysteresis window.
//   - Hysteresis does not flicker at threshold edges (brief blips are absorbed).

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <optional>

#include "../../android/app/src/main/cpp/vad_detector.h"

static constexpr int32_t kRate      = 48000;
static constexpr int32_t kFrameSize = 960;  // 20 ms @ 48 kHz

// Feed `durationMs` of above-threshold signal in kFrameSize bursts.
// Returns the total number of VAD edges emitted.
static int feedAbove(VadDetector& vad, int32_t durationMs) {
    int edges = 0;
    const int32_t totalFrames = (kRate * durationMs) / 1000;
    for (int32_t fed = 0; fed < totalFrames; fed += kFrameSize) {
        const int32_t n = std::min(kFrameSize, totalFrames - fed);
        if (vad.update(true, n)) ++edges;
    }
    return edges;
}

// Feed `durationMs` of below-threshold signal in kFrameSize bursts.
// Returns the total number of VAD edges emitted.
static int feedBelow(VadDetector& vad, int32_t durationMs) {
    int edges = 0;
    const int32_t totalFrames = (kRate * durationMs) / 1000;
    for (int32_t fed = 0; fed < totalFrames; fed += kFrameSize) {
        const int32_t n = std::min(kFrameSize, totalFrames - fed);
        if (vad.update(false, n)) ++edges;
    }
    return edges;
}

// ── On-hysteresis: rising edge fires only after 100 ms ──────────────────────

// 80 ms of above-threshold is not enough to trigger talking.
void testOnHysteresisUnder() {
    VadDetector vad(kRate);
    const int edges = feedAbove(vad, 80);
    assert(!vad.talking());
    assert(edges == 0);
    std::cout << "testOnHysteresisUnder: PASSED" << std::endl;
}

// Exactly 100 ms triggers exactly one rising edge.
void testOnHysteresisExact() {
    VadDetector vad(kRate);
    const int edges = feedAbove(vad, 100);
    assert(vad.talking());
    assert(edges == 1);
    std::cout << "testOnHysteresisExact: PASSED" << std::endl;
}

// A brief dip resets the above-threshold accumulator — anti-flicker.
// 80 ms above + 20 ms below + 80 ms above must not trigger talking.
void testOnHysteresisResetByDip() {
    VadDetector vad(kRate);
    feedAbove(vad, 80);
    assert(!vad.talking());
    feedBelow(vad, 20);   // resets above-threshold accumulator
    const int edges = feedAbove(vad, 80);
    // Only 80 ms accumulated since the dip — still below the 100 ms window.
    assert(!vad.talking());
    assert(edges == 0);
    std::cout << "testOnHysteresisResetByDip: PASSED" << std::endl;
}

// ── Off-hysteresis: falling edge fires only after 300 ms ────────────────────

// After talking starts, 200 ms of silence is not enough to stop it.
void testOffHysteresisUnder() {
    VadDetector vad(kRate);
    feedAbove(vad, 100);  // start talking
    assert(vad.talking());
    const int edges = feedBelow(vad, 200);
    assert(vad.talking());
    assert(edges == 0);
    std::cout << "testOffHysteresisUnder: PASSED" << std::endl;
}

// Exactly 300 ms of silence after talking starts triggers exactly one falling edge.
void testOffHysteresisExact() {
    VadDetector vad(kRate);
    feedAbove(vad, 100);  // start talking
    const int edges = feedBelow(vad, 300);
    assert(!vad.talking());
    assert(edges == 1);
    std::cout << "testOffHysteresisExact: PASSED" << std::endl;
}

// A brief blip during silence resets the below-threshold accumulator — anti-flicker.
// 200 ms below + 20 ms above + 200 ms below must not trigger a falling edge.
void testOffHysteresisResetByBlip() {
    VadDetector vad(kRate);
    feedAbove(vad, 100);  // start talking
    feedBelow(vad, 200);
    assert(vad.talking());
    feedAbove(vad, 20);   // brief blip resets below-threshold accumulator
    const int edges = feedBelow(vad, 200);
    assert(vad.talking());
    assert(edges == 0);
    std::cout << "testOffHysteresisResetByBlip: PASSED" << std::endl;
}

// ── Full cycle ───────────────────────────────────────────────────────────────

// Start silent → talk → stop → talk again. Each cycle must produce exactly
// one rising and one falling edge.
void testFullTalkSilenceCycle() {
    VadDetector vad(kRate);
    assert(!vad.talking());

    int e = feedAbove(vad, 100);
    assert(e == 1 && vad.talking());

    e = feedBelow(vad, 300);
    assert(e == 1 && !vad.talking());

    // Second talk cycle.
    e = feedAbove(vad, 100);
    assert(e == 1 && vad.talking());

    e = feedBelow(vad, 300);
    assert(e == 1 && !vad.talking());

    std::cout << "testFullTalkSilenceCycle: PASSED" << std::endl;
}

// ── reset() ─────────────────────────────────────────────────────────────────

// reset() during accumulated-but-not-yet-triggered above-threshold signal
// must zero the accumulator so the hysteresis window restarts from scratch.
void testResetClearsAccumulator() {
    VadDetector vad(kRate);
    feedAbove(vad, 80);  // 80 ms — almost at threshold
    assert(!vad.talking());
    vad.reset();
    // 80 ms more is not enough for the fresh accumulator.
    const int edges = feedAbove(vad, 80);
    assert(!vad.talking());
    assert(edges == 0);
    std::cout << "testResetClearsAccumulator: PASSED" << std::endl;
}

// reset() while talking must immediately drop talking() to false without
// emitting a falling edge through update().
void testResetWhileTalking() {
    VadDetector vad(kRate);
    feedAbove(vad, 100);
    assert(vad.talking());
    vad.reset();
    assert(!vad.talking());
    std::cout << "testResetWhileTalking: PASSED" << std::endl;
}

// ── Fine-grained frame-count boundary ───────────────────────────────────────

// Feed exactly (onFrames - 1) frames, then one more: edge must fire on the
// last call, not before. Exercises the >= boundary in the accumulator check.
void testOnBoundaryFrameByFrame() {
    VadDetector vad(kRate);
    const int32_t onFrames = (kRate * VadDetector::kOnHysteresisMs) / 1000;

    // Feed all but one frame.
    std::optional<bool> edge;
    for (int32_t i = 0; i < onFrames - 1; ++i) {
        edge = vad.update(true, 1);
        assert(!edge.has_value());
    }
    assert(!vad.talking());

    // The final frame must cross the threshold.
    edge = vad.update(true, 1);
    assert(edge.has_value() && *edge == true);
    assert(vad.talking());
    std::cout << "testOnBoundaryFrameByFrame: PASSED" << std::endl;
}

// Same test for the off boundary.
void testOffBoundaryFrameByFrame() {
    VadDetector vad(kRate);
    feedAbove(vad, 100);  // start talking
    assert(vad.talking());

    const int32_t offFrames = (kRate * VadDetector::kOffHysteresisMs) / 1000;

    std::optional<bool> edge;
    for (int32_t i = 0; i < offFrames - 1; ++i) {
        edge = vad.update(false, 1);
        assert(!edge.has_value());
    }
    assert(vad.talking());

    edge = vad.update(false, 1);
    assert(edge.has_value() && *edge == false);
    assert(!vad.talking());
    std::cout << "testOffBoundaryFrameByFrame: PASSED" << std::endl;
}

int main() {
    try {
        testOnHysteresisUnder();
        testOnHysteresisExact();
        testOnHysteresisResetByDip();
        testOffHysteresisUnder();
        testOffHysteresisExact();
        testOffHysteresisResetByBlip();
        testFullTalkSilenceCycle();
        testResetClearsAccumulator();
        testResetWhileTalking();
        testOnBoundaryFrameByFrame();
        testOffBoundaryFrameByFrame();
        std::cout << "All VadDetector tests passed!" << std::endl;
    } catch (const std::exception& e) {
        std::cerr << "Test failed with exception: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
