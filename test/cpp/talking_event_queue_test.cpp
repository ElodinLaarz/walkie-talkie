#include <atomic>
#include <cassert>
#include <cstdio>
#include <iostream>
#include <thread>
#include <vector>

#include "../../android/app/src/main/cpp/talking_event_queue.h"

// Empty queue: pop must return false and leave the out-param untouched.
void testEmptyPopReturnsFalse() {
    TalkingEventQueue q;
    bool out = true;  // sentinel — must remain untouched
    assert(!q.pop(out));
    assert(out == true);
    std::cout << "Test Empty Pop Returns False: PASSED" << std::endl;
}

// Round-trip: a pushed value comes back.
void testPushPopRoundTrip() {
    TalkingEventQueue q;
    assert(q.push(true));
    bool out = false;
    assert(q.pop(out));
    assert(out == true);
    // Now empty again.
    assert(!q.pop(out));
    std::cout << "Test Push/Pop Round Trip: PASSED" << std::endl;
}

// Order preservation across the wrap-around point. The ring uses a power-of-
// two capacity with a mask, so the indices walk past kCapacity multiple times
// without aliasing. This pins that the FIFO order survives that wraparound.
void testFifoOrderAcrossWraparound() {
    TalkingEventQueue q;
    // Walk past the capacity twice. Push/pop alternated keeps the queue
    // never-full but exercises every slot index.
    const size_t kIters = TalkingEventQueue::kCapacity * 4;
    for (size_t i = 0; i < kIters; ++i) {
        const bool v = (i % 2) == 0;
        assert(q.push(v));
        bool out;
        assert(q.pop(out));
        assert(out == v);
    }
    assert(q.sizeApprox() == 0);
    std::cout << "Test FIFO Order Across Wraparound: PASSED" << std::endl;
}

// Capacity boundary: pushing exactly kCapacity entries succeeds; the (k+1)th
// push must be rejected. This is the load-shedding contract that the audio
// callback relies on — a full ring drops new events rather than blocking.
void testCapacityBoundaryDrops() {
    TalkingEventQueue q;
    for (size_t i = 0; i < TalkingEventQueue::kCapacity; ++i) {
        assert(q.push(i % 2 == 0));
    }
    // Ring is full. Next push must be rejected.
    assert(!q.push(true));
    assert(q.sizeApprox() == TalkingEventQueue::kCapacity);

    // Drain. Values must come back in push order.
    for (size_t i = 0; i < TalkingEventQueue::kCapacity; ++i) {
        bool out;
        assert(q.pop(out));
        assert(out == (i % 2 == 0));
    }
    bool out;
    assert(!q.pop(out));
    std::cout << "Test Capacity Boundary Drops: PASSED" << std::endl;
}

// After a drop on overflow, the queue must remain consistent — the next
// pop cycle must still return the original (pre-drop) values in order, and
// new pushes after a drain must succeed normally. Regression guard for an
// off-by-one in the overflow check that would corrupt the read index.
void testRecoversAfterOverflowDrop() {
    TalkingEventQueue q;
    // Fill, attempt one over, drain, fill again — the second fill must
    // succeed exactly kCapacity times.
    for (size_t i = 0; i < TalkingEventQueue::kCapacity; ++i) {
        assert(q.push(true));
    }
    assert(!q.push(false));  // overflow drop

    // Drain — must yield exactly kCapacity `true` values.
    for (size_t i = 0; i < TalkingEventQueue::kCapacity; ++i) {
        bool out;
        assert(q.pop(out));
        assert(out == true);
    }

    // Round 2: should be functionally identical to a fresh queue.
    for (size_t i = 0; i < TalkingEventQueue::kCapacity; ++i) {
        assert(q.push(false));
    }
    for (size_t i = 0; i < TalkingEventQueue::kCapacity; ++i) {
        bool out = true;
        assert(q.pop(out));
        assert(out == false);
    }
    std::cout << "Test Recovers After Overflow Drop: PASSED" << std::endl;
}

// SPSC stress: a producer thread pushes a long alternating sequence and a
// consumer thread pops everything. The expected count of `true` values is
// known, so we can assert end-state equality. Drops are tolerated on
// overflow (consumer can fall behind the producer briefly) — we encode
// each event as a known pattern so the consumer can detect any
// out-of-sequence delivery (corrupted slot indices, torn values).
void testSpscStress() {
    TalkingEventQueue q;
    constexpr int kEvents = 100000;

    std::atomic<int> producedTrue{0};
    std::atomic<int> consumedTrue{0};
    std::atomic<int> consumed{0};
    std::atomic<bool> producerDone{false};

    std::thread producer([&] {
        for (int i = 0; i < kEvents; ++i) {
            const bool v = (i & 1) == 0;
            // Spin until accepted — we want every event to arrive so the
            // FIFO contract can be verified end-to-end. (At kCapacity = 16
            // and a fast consumer, this rarely spins more than a few times.)
            while (!q.push(v)) {
                std::this_thread::yield();
            }
            if (v) producedTrue.fetch_add(1, std::memory_order_relaxed);
        }
        producerDone.store(true, std::memory_order_release);
    });

    std::thread consumer([&] {
        bool last = false;
        bool seenAny = false;
        int local = 0;
        int localTrue = 0;
        while (true) {
            bool out;
            if (q.pop(out)) {
                // FIFO: alternating producer means every popped value must
                // differ from the previous one (after the first).
                if (seenAny) assert(out != last);
                last = out;
                seenAny = true;
                ++local;
                if (out) ++localTrue;
            } else if (producerDone.load(std::memory_order_acquire)) {
                // Producer done AND queue empty: we've seen everything.
                bool out2;
                if (!q.pop(out2)) break;
                if (seenAny) assert(out2 != last);
                last = out2;
                ++local;
                if (out2) ++localTrue;
            } else {
                std::this_thread::yield();
            }
        }
        consumed.store(local, std::memory_order_release);
        consumedTrue.store(localTrue, std::memory_order_release);
    });

    producer.join();
    consumer.join();

    assert(consumed.load() == kEvents);
    assert(consumedTrue.load() == producedTrue.load());
    std::cout << "Test SPSC Stress: PASSED" << std::endl;
}

int main() {
    try {
        testEmptyPopReturnsFalse();
        testPushPopRoundTrip();
        testFifoOrderAcrossWraparound();
        testCapacityBoundaryDrops();
        testRecoversAfterOverflowDrop();
        testSpscStress();
        std::cout << "All C++ TalkingEventQueue tests passed!" << std::endl;
    } catch (const std::exception& e) {
        std::cerr << "Test failed with exception: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
