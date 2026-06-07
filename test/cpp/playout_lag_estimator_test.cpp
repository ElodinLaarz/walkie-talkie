// Host-buildable test for PlayoutLagEstimator (header-only).
//
// Compile (see scripts/run_native_cpp_tests.sh):
//   g++ -std=c++17 -Wall -Wextra -pthread -I android/app/src/main/cpp
//       test/cpp/playout_lag_estimator_test.cpp -o build/cpp_test/playout_lag_estimator_test

#include "playout_lag_estimator.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            std::cerr << "CHECK failed: " #cond                              \
                      << " (" << __FILE__ << ":" << __LINE__ << ")"          \
                      << std::endl;                                          \
            std::exit(1);                                                    \
        }                                                                    \
    } while (0)

// A constant clock offset + constant transit must cancel to zero staleness,
// no matter how large the offset (the whole point: no clock sync needed).
void testConstantOffsetCancels() {
    PlayoutLagEstimator est;
    const int64_t offsetPlusTransit = 100;  // ms baked into every sample
    for (int i = 0; i < 20; ++i) {
        const int64_t recvMs = 1000 + i * 20;
        const uint32_t senderTs =
            static_cast<uint32_t>(recvMs - offsetPlusTransit);
        CHECK(est.feed(senderTs, recvMs) == 0);
    }
    // Even with an absurd offset (sender clock ~100 s behind), excess is 0.
    PlayoutLagEstimator est2;
    for (int i = 0; i < 5; ++i) {
        const int64_t recvMs = 50000 + i * 20;
        const uint32_t senderTs = static_cast<uint32_t>(recvMs - 100000 - 30);
        CHECK(est2.feed(senderTs, recvMs) == 0);
    }
    std::cout << "Test Constant Offset Cancels: PASSED" << std::endl;
}

// A backlog (transit jumps above the established baseline) surfaces as excess.
void testBacklogSurfacesAsExcess() {
    PlayoutLagEstimator est;
    // Clean baseline: transit 100 ms.
    for (int i = 0; i < 10; ++i) {
        const int64_t recvMs = 1000 + i * 20;
        est.feed(static_cast<uint32_t>(recvMs - 100), recvMs);
    }
    // A frame that languished 500 ms longer in transit.
    const int64_t recvMs = 1200;
    const int64_t excess = est.feed(static_cast<uint32_t>(recvMs - 600), recvMs);
    CHECK(excess == 500);
    CHECK(PlayoutLagEstimator::isStale(excess));
    std::cout << "Test Backlog Surfaces As Excess: PASSED" << std::endl;
}

void testIsStaleBoundary() {
    // Budget is 200 ms; strict greater-than.
    CHECK(!PlayoutLagEstimator::isStale(0));
    CHECK(!PlayoutLagEstimator::isStale(200));
    CHECK(PlayoutLagEstimator::isStale(201));
    CHECK(PlayoutLagEstimator::isStale(3000));
    std::cout << "Test isStale Boundary: PASSED" << std::endl;
}

// A new lower transit lowers the baseline; later normal frames then read as
// excess above that new best.
void testLowerBaselinePullsExcessUp() {
    PlayoutLagEstimator est;
    est.feed(static_cast<uint32_t>(1000 - 100), 1000);  // D=100, excess 0
    CHECK(est.lastExcessMs() == 0);
    est.feed(static_cast<uint32_t>(1020 - 50), 1020);   // D=50, new min, excess 0
    CHECK(est.lastExcessMs() == 0);
    const int64_t excess = est.feed(static_cast<uint32_t>(1040 - 100), 1040);  // D=100
    CHECK(excess == 50);  // 100 above the new baseline of 50
    std::cout << "Test Lower Baseline Pulls Excess Up: PASSED" << std::endl;
}

// Once the window slides past the original low-transit sample, the baseline
// rises to the recent minimum and a previously-"stale" steady state reads as
// fresh again.
void testWindowEvictsStaleBaseline() {
    PlayoutLagEstimator est;
    // One good frame at t=1000 (transit 100).
    est.feed(static_cast<uint32_t>(1000 - 100), 1000);
    // Steady state at transit 300, still within the window of the t=1000 sample.
    int64_t excessWithinWindow =
        est.feed(static_cast<uint32_t>(5000 - 300), 5000);  // t-1000 < 5000ms
    CHECK(excessWithinWindow == 200);  // 300 above baseline 100
    // Advance well past the window so the t=1000 baseline is evicted; the
    // recent 300-transit frames become the new baseline -> excess collapses.
    int64_t excessAfterEvict =
        est.feed(static_cast<uint32_t>(7000 - 300), 7000);  // 7000-1000 > 5000ms
    CHECK(excessAfterEvict == 0);
    std::cout << "Test Window Evicts Stale Baseline: PASSED" << std::endl;
}

// senderTsMs wraps at 2^32; modular int32 delay math must still be correct
// when the sender timestamp is near the top of the range.
void testWrapAroundDelay() {
    PlayoutLagEstimator est;
    // recv low-32 small, senderTs just below it minus 100 -> wraps past 0.
    for (int i = 0; i < 5; ++i) {
        const int64_t recvMs = (int64_t{1} << 32) + 50 + i * 20;  // low32 wraps
        const uint32_t senderTs = static_cast<uint32_t>(recvMs - 100);
        CHECK(est.feed(senderTs, recvMs) == 0);  // constant D=100 across the wrap
    }
    const int64_t recvMs = (int64_t{1} << 32) + 150;
    const int64_t excess = est.feed(static_cast<uint32_t>(recvMs - 700), recvMs);
    CHECK(excess == 600);
    std::cout << "Test Wrap-Around Delay: PASSED" << std::endl;
}

void testResetClears() {
    PlayoutLagEstimator est;
    est.feed(static_cast<uint32_t>(1000 - 100), 1000);
    est.feed(static_cast<uint32_t>(1020 - 900), 1020);
    CHECK(est.lastExcessMs() == 800);
    est.reset();
    CHECK(est.lastExcessMs() == 0);
    // After reset the next frame defines a fresh baseline (excess 0).
    CHECK(est.feed(static_cast<uint32_t>(2000 - 5000), 2000) == 0);
    std::cout << "Test Reset Clears: PASSED" << std::endl;
}

int main() {
    testConstantOffsetCancels();
    testBacklogSurfacesAsExcess();
    testIsStaleBoundary();
    testLowerBaselinePullsExcessUp();
    testWindowEvictsStaleBaseline();
    testWrapAroundDelay();
    testResetClears();
    std::cout << "\nAll PlayoutLagEstimator tests passed." << std::endl;
    return 0;
}
