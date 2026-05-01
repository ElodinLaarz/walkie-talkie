// Host-buildable test for the lock-free SPSC RingBuffer in ring_buffer.h.
// ring_buffer.h is header-only and depends only on <atomic>/<cstdint>/<cstring>,
// so it compiles cleanly under host g++ without the Android NDK.
//
// Compile (see scripts/presubmit.sh and .github/workflows/flutter.yml):
//   g++ -std=c++17 -Wall -Wextra -pthread -I android/app/src/main/cpp
//       test/cpp/ring_buffer_test.cpp -o build/cpp_test/ring_buffer_test

#include "ring_buffer.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <thread>
#include <vector>

// CHECK is preferred over assert(): assert() is a no-op when NDEBUG is
// defined (release/optimized builds), which would let tests pass silently
// without any validation. CHECK always fires and aborts the binary with a
// clear diagnostic.
#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            std::cerr << "CHECK failed: " #cond                              \
                      << " (" << __FILE__ << ":" << __LINE__ << ")"          \
                      << std::endl;                                          \
            std::exit(1);                                                    \
        }                                                                    \
    } while (0)

// ── Basic single-threaded correctness ────────────────────────────────────────

void testEmptyReadReturnsZero() {
    RingBuffer<int16_t, 32> rb;
    int16_t out[8];
    size_t n = rb.read(out, 8);
    CHECK(n == 0);
    CHECK(rb.availableToRead() == 0);
    std::cout << "Test Empty Read Returns Zero: PASSED" << std::endl;
}

void testWriteReadRoundTrip() {
    RingBuffer<int16_t, 64> rb;
    int16_t in[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    int16_t out[8] = {};
    size_t written = rb.write(in, 8);
    CHECK(written == 8);
    CHECK(rb.availableToRead() == 8);
    size_t read = rb.read(out, 8);
    CHECK(read == 8);
    CHECK(rb.availableToRead() == 0);
    for (int i = 0; i < 8; ++i) {
        CHECK(out[i] == in[i]);
    }
    std::cout << "Test Write/Read Round Trip: PASSED" << std::endl;
}

void testPartialWriteOnFull() {
    // Capacity is N-1 for a ring of size N (one slot reserved as sentinel).
    RingBuffer<int16_t, 8> rb;  // holds 7 samples
    int16_t data[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    size_t written = rb.write(data, 8);
    CHECK(written == 7);
    CHECK(rb.availableToWrite() == 0);
    // A further write must be rejected entirely.
    int16_t extra[1] = {99};
    CHECK(rb.write(extra, 1) == 0);
    std::cout << "Test Partial Write On Full: PASSED" << std::endl;
}

void testPartialReadOnUnderrun() {
    RingBuffer<int16_t, 32> rb;
    int16_t in[4] = {10, 20, 30, 40};
    rb.write(in, 4);
    int16_t out[8] = {};
    size_t read = rb.read(out, 8);  // ask for more than available
    CHECK(read == 4);
    for (int i = 0; i < 4; ++i) {
        CHECK(out[i] == in[i]);
    }
    std::cout << "Test Partial Read On Underrun: PASSED" << std::endl;
}

// Wrap-around: write past the end of the underlying array, read back correctly.
void testWraparoundCorrectness() {
    // Capacity = 7 (ring size 8). Write 5, read 5, write 5 again — the
    // second write wraps around the internal buffer array boundary.
    RingBuffer<int16_t, 8> rb;
    int16_t in[5] = {1, 2, 3, 4, 5};
    int16_t out[5] = {};

    // First write-read cycle — advance the write index to 5.
    CHECK(rb.write(in, 5) == 5);
    CHECK(rb.read(out, 5) == 5);
    for (int i = 0; i < 5; ++i) {
        CHECK(out[i] == in[i]);
    }

    // Second write wraps around (writeIndex = 5, will reach 2 after mod 8).
    int16_t in2[5] = {10, 20, 30, 40, 50};
    CHECK(rb.write(in2, 5) == 5);

    int16_t out2[5] = {};
    CHECK(rb.read(out2, 5) == 5);
    for (int i = 0; i < 5; ++i) {
        CHECK(out2[i] == in2[i]);
    }
    CHECK(rb.availableToRead() == 0);
    std::cout << "Test Wraparound Correctness: PASSED" << std::endl;
}

// peek() must not advance the read pointer.
void testPeekDoesNotConsume() {
    RingBuffer<int16_t, 32> rb;
    int16_t in[4] = {7, 8, 9, 10};
    rb.write(in, 4);

    int16_t peeked[4] = {};
    size_t n = rb.peek(peeked, 4);
    CHECK(n == 4);
    for (int i = 0; i < 4; ++i) {
        CHECK(peeked[i] == in[i]);
    }
    CHECK(rb.availableToRead() == 4);  // still 4

    // A subsequent read must return the same data.
    int16_t out[4] = {};
    CHECK(rb.read(out, 4) == 4);
    for (int i = 0; i < 4; ++i) {
        CHECK(out[i] == in[i]);
    }
    std::cout << "Test Peek Does Not Consume: PASSED" << std::endl;
}

void testClearResetsState() {
    RingBuffer<int16_t, 32> rb;
    int16_t in[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    rb.write(in, 8);
    CHECK(rb.availableToRead() == 8);
    rb.clear();
    CHECK(rb.availableToRead() == 0);
    constexpr size_t kCap32 = RingBuffer<int16_t, 32>::capacity();
    CHECK(rb.availableToWrite() == kCap32);
    // Write and read again after clear to confirm state is consistent.
    rb.write(in, 8);
    int16_t out[8] = {};
    CHECK(rb.read(out, 8) == 8);
    for (int i = 0; i < 8; ++i) {
        CHECK(out[i] == in[i]);
    }
    std::cout << "Test Clear Resets State: PASSED" << std::endl;
}

void testAvailableToWriteAccountsForData() {
    RingBuffer<int16_t, 16> rb;  // capacity = 15
    constexpr size_t kCap = RingBuffer<int16_t, 16>::capacity();
    CHECK(rb.availableToWrite() == kCap);

    int16_t data[5] = {};
    rb.write(data, 5);
    CHECK(rb.availableToWrite() == kCap - 5);
    CHECK(rb.availableToRead() == 5);
    rb.read(data, 5);
    CHECK(rb.availableToWrite() == kCap);
    std::cout << "Test AvailableToWrite Accounts For Data: PASSED" << std::endl;
}

// ── SPSC stress: producer/consumer threads running concurrently ───────────────
//
// The producer writes 1-sample frames and the consumer reads them. After the
// producer finishes, we drain remaining samples and verify that every value
// written was eventually read in order (no corruption, no reordering).
//
// This exercises the release/acquire ordering on writeIndex/readIndex under
// genuine concurrent access — a sanitizer run (TSAN) would catch races here.
//
// Watchdog: a regression in RingBuffer (or a platform-specific atomic bug)
// could leave a thread spinning forever inside the unbounded write/yield
// loop. The kWatchdogTimeout below caps the total wall-clock time so a hung
// test fails the CI job in seconds rather than minutes.
void testSpscStress() {
    // Use a small ring so wrap-around happens frequently.
    constexpr size_t kRingSize = 64;
    RingBuffer<int16_t, kRingSize> rb;

    constexpr int kFrames = 200000;
    // We use values 1..32767 cycling; 0 is reserved as "unwritten".
    constexpr int16_t kMod = 32767;

    // Generous on a slow CI runner but still well below a "hang" threshold.
    constexpr auto kWatchdogTimeout = std::chrono::seconds(30);

    std::atomic<bool> producerDone{false};
    std::atomic<bool> abort{false};
    std::atomic<long long> totalWritten{0};
    std::atomic<long long> totalRead{0};
    std::atomic<bool> orderViolation{false};

    std::atomic<int16_t> nextExpected{1};

    const auto start = std::chrono::steady_clock::now();

    std::thread producer([&] {
        for (int i = 0; i < kFrames; ++i) {
            if (abort.load(std::memory_order_acquire)) return;
            int16_t v = static_cast<int16_t>((i % kMod) + 1);
            // Spin until the ring has room — but bail if the watchdog fires.
            while (rb.write(&v, 1) == 0) {
                if (abort.load(std::memory_order_acquire)) return;
                std::this_thread::yield();
            }
            totalWritten.fetch_add(1, std::memory_order_relaxed);
        }
        producerDone.store(true, std::memory_order_release);
    });

    std::thread consumer([&] {
        while (!producerDone.load(std::memory_order_acquire) ||
               rb.availableToRead() > 0) {
            if (abort.load(std::memory_order_acquire)) return;
            int16_t v;
            if (rb.read(&v, 1) == 1) {
                // Check FIFO ordering.
                int16_t expected = nextExpected.load(std::memory_order_relaxed);
                if (v != expected) {
                    orderViolation.store(true, std::memory_order_relaxed);
                }
                int16_t next = static_cast<int16_t>((expected % kMod) + 1);
                nextExpected.store(next, std::memory_order_relaxed);
                totalRead.fetch_add(1, std::memory_order_relaxed);
            } else {
                std::this_thread::yield();
            }
        }
    });

    // Watchdog thread: trips the abort flag if either producer or consumer
    // stalls past the budget. Without this, a regression in RingBuffer could
    // leave the CI job hanging until the workflow-level timeout (typically
    // many minutes).
    std::thread watchdog([&] {
        while (!producerDone.load(std::memory_order_acquire) ||
               totalRead.load(std::memory_order_relaxed) < kFrames) {
            if (std::chrono::steady_clock::now() - start > kWatchdogTimeout) {
                abort.store(true, std::memory_order_release);
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    });

    producer.join();
    consumer.join();
    // Wake the watchdog so it doesn't sleep out the rest of its budget when
    // the test completed successfully — its loop exit condition already
    // covers the success case, but a stale `abort=false` would just mean a
    // few extra polls before it observes producerDone+totalRead.
    abort.store(true, std::memory_order_release);
    watchdog.join();

    // Belt-and-suspenders drain after the producer has joined: the consumer
    // loop's TOCTOU between `producerDone` and `availableToRead()` is
    // already covered by the producer's release-store sequencing, but an
    // explicit drain here makes the contract obvious and catches any
    // future regression where the ordering invariant slips.
    while (rb.availableToRead() > 0) {
        int16_t v;
        if (rb.read(&v, 1) == 1) {
            int16_t expected = nextExpected.load(std::memory_order_relaxed);
            if (v != expected) {
                orderViolation.store(true, std::memory_order_relaxed);
            }
            int16_t next = static_cast<int16_t>((expected % kMod) + 1);
            nextExpected.store(next, std::memory_order_relaxed);
            totalRead.fetch_add(1, std::memory_order_relaxed);
        }
    }

    CHECK(!orderViolation.load());
    CHECK(totalWritten.load() == kFrames);
    CHECK(totalRead.load() == kFrames);
    std::cout << "Test SPSC Stress (" << kFrames << " frames): PASSED"
              << std::endl;
}

int main() {
    testEmptyReadReturnsZero();
    testWriteReadRoundTrip();
    testPartialWriteOnFull();
    testPartialReadOnUnderrun();
    testWraparoundCorrectness();
    testPeekDoesNotConsume();
    testClearResetsState();
    testAvailableToWriteAccountsForData();
    testSpscStress();
    std::cout << "\nAll RingBuffer tests passed." << std::endl;
    return 0;
}
