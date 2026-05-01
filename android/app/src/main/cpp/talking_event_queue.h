#ifndef TALKING_EVENT_QUEUE_H
#define TALKING_EVENT_QUEUE_H

#include <atomic>
#include <cstddef>

// Single-producer, single-consumer ring buffer of VAD edge events.
//
// The Oboe audio callback (producer) historically called `AttachCurrentThread`
// + `CallVoidMethod` directly on the audio thread, taking `g_jniMutex` along
// the way. JVM safepoints can stall the callback unboundedly, which is
// catastrophic on a real-time audio thread. This queue moves all JNI work to
// a worker thread: the producer just stores a bool and bumps an atomic
// counter (lock-free, allocation-free), and the worker drains and dispatches.
//
// Capacity sized for the worst-case burst between worker polls: at the
// production 20 ms poll interval, even pathological VAD flapping at 50 Hz
// (one edge per audio callback) would only deposit a single edge per poll.
// 16 leaves nearly two orders of magnitude of headroom and aligns the index
// modulo to a cheap mask.
class TalkingEventQueue {
public:
    static constexpr size_t kCapacity = 16;
    static_assert((kCapacity & (kCapacity - 1)) == 0,
                  "kCapacity must be a power of two so we can use a mask");

    // Producer-side push, called from the audio callback. Lock-free and
    // wait-free; allocates nothing. Returns false if the ring is full, in
    // which case the event is dropped — callers should treat that as a soft
    // signal that the worker has fallen catastrophically behind, not as a
    // recoverable error. At the operating rate (one push per VAD edge,
    // ~1 Hz worst-case typical, hard-bounded at 50 Hz by the audio callback
    // cadence) the ring is effectively unfillable.
    bool push(bool talking) {
        const size_t w = writeIdx_.load(std::memory_order_relaxed);
        const size_t r = readIdx_.load(std::memory_order_acquire);
        if (w - r >= kCapacity) {
            return false;
        }
        slots_[w & (kCapacity - 1)] = talking;
        writeIdx_.store(w + 1, std::memory_order_release);
        return true;
    }

    // Consumer-side pop, called from the worker thread. Returns true and
    // stores the value into `out` if a value was popped; returns false if
    // the queue is empty.
    bool pop(bool& out) {
        const size_t r = readIdx_.load(std::memory_order_relaxed);
        const size_t w = writeIdx_.load(std::memory_order_acquire);
        if (r == w) {
            return false;
        }
        out = slots_[r & (kCapacity - 1)];
        readIdx_.store(r + 1, std::memory_order_release);
        return true;
    }

    // Test-only helper for diagnostics. Not safe to call concurrently with
    // push/pop; use only in tests where you control thread scheduling.
    size_t sizeApprox() const {
        const size_t w = writeIdx_.load(std::memory_order_relaxed);
        const size_t r = readIdx_.load(std::memory_order_relaxed);
        return w - r;
    }

private:
    bool slots_[kCapacity]{};
    std::atomic<size_t> writeIdx_{0};
    std::atomic<size_t> readIdx_{0};
};

#endif  // TALKING_EVENT_QUEUE_H
