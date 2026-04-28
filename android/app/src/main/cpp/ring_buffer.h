#ifndef RING_BUFFER_H
#define RING_BUFFER_H

#include <atomic>
#include <cstdint>
#include <cstring>
#include <algorithm>

// Lock-free single-producer-single-consumer (SPSC) ring buffer for audio samples.
// Safe for use from real-time audio threads (no blocking, no allocation).
template<typename T, size_t Capacity>
class RingBuffer {
private:
    T buffer[Capacity];
    std::atomic<size_t> writeIndex{0};
    std::atomic<size_t> readIndex{0};

    // Get next index with wraparound
    static constexpr size_t nextIndex(size_t current) {
        return (current + 1) % Capacity;
    }

public:
    RingBuffer() {
        std::memset(buffer, 0, sizeof(buffer));
    }

    // Write samples to the ring buffer. Returns number of samples actually written.
    // May write fewer than requested if buffer is full.
    size_t write(const T* data, size_t count) {
        size_t writePos = writeIndex.load(std::memory_order_relaxed);
        size_t readPos = readIndex.load(std::memory_order_acquire);

        size_t available = availableToWrite(writePos, readPos);
        size_t toWrite = std::min(count, available);

        // Write in up to two chunks (handle wraparound)
        size_t firstChunk = std::min(toWrite, Capacity - writePos);
        std::memcpy(&buffer[writePos], data, firstChunk * sizeof(T));

        if (toWrite > firstChunk) {
            size_t secondChunk = toWrite - firstChunk;
            std::memcpy(&buffer[0], data + firstChunk, secondChunk * sizeof(T));
        }

        size_t newWritePos = (writePos + toWrite) % Capacity;
        writeIndex.store(newWritePos, std::memory_order_release);

        return toWrite;
    }

    // Read samples from the ring buffer. Returns number of samples actually read.
    // May read fewer than requested if buffer doesn't have enough data.
    size_t read(T* output, size_t count) {
        size_t readPos = readIndex.load(std::memory_order_relaxed);
        size_t writePos = writeIndex.load(std::memory_order_acquire);

        size_t available = availableToRead(readPos, writePos);
        size_t toRead = std::min(count, available);

        // Read in up to two chunks (handle wraparound)
        size_t firstChunk = std::min(toRead, Capacity - readPos);
        std::memcpy(output, &buffer[readPos], firstChunk * sizeof(T));

        if (toRead > firstChunk) {
            size_t secondChunk = toRead - firstChunk;
            std::memcpy(output + firstChunk, &buffer[0], secondChunk * sizeof(T));
        }

        size_t newReadPos = (readPos + toRead) % Capacity;
        readIndex.store(newReadPos, std::memory_order_release);

        return toRead;
    }

    // Peek at samples without consuming them. Returns number of samples copied.
    size_t peek(T* output, size_t count) const {
        size_t readPos = readIndex.load(std::memory_order_relaxed);
        size_t writePos = writeIndex.load(std::memory_order_acquire);

        size_t available = availableToRead(readPos, writePos);
        size_t toPeek = std::min(count, available);

        // Peek in up to two chunks (handle wraparound)
        size_t firstChunk = std::min(toPeek, Capacity - readPos);
        std::memcpy(output, &buffer[readPos], firstChunk * sizeof(T));

        if (toPeek > firstChunk) {
            size_t secondChunk = toPeek - firstChunk;
            std::memcpy(output + firstChunk, &buffer[0], secondChunk * sizeof(T));
        }

        return toPeek;
    }

    // Get number of samples available to read
    size_t availableToRead() const {
        size_t readPos = readIndex.load(std::memory_order_relaxed);
        size_t writePos = writeIndex.load(std::memory_order_acquire);
        return availableToRead(readPos, writePos);
    }

    // Get number of samples available to write
    size_t availableToWrite() const {
        size_t writePos = writeIndex.load(std::memory_order_relaxed);
        size_t readPos = readIndex.load(std::memory_order_acquire);
        return availableToWrite(writePos, readPos);
    }

    // Clear the buffer
    void clear() {
        // Reset indices (safe because this shouldn't be called during concurrent access)
        writeIndex.store(0, std::memory_order_release);
        readIndex.store(0, std::memory_order_release);
    }

    // Get capacity
    static constexpr size_t capacity() { return Capacity - 1; }  // -1 because we can't fill completely

private:
    size_t availableToRead(size_t readPos, size_t writePos) const {
        if (writePos >= readPos) {
            return writePos - readPos;
        } else {
            return Capacity - readPos + writePos;
        }
    }

    size_t availableToWrite(size_t writePos, size_t readPos) const {
        size_t used = availableToRead(readPos, writePos);
        return (Capacity - 1) - used;  // -1 to distinguish full from empty
    }
};

// Common ring buffer types for audio
// 1 second at 16 kHz = 16000 samples
using AudioRingBuffer = RingBuffer<int16_t, 16384>;  // ~1 sec at 16 kHz (power of 2)

#endif // RING_BUFFER_H
