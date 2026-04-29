#ifndef AUDIO_MIXER_H
#define AUDIO_MIXER_H

#include <vector>
#include <map>
#include <mutex>
#include <atomic>
#include <memory>
#include <cstring>
#include <algorithm>
#include "ring_buffer.h"

// Per-device audio buffer with lock-free ring buffer for real-time safety.
//
// `hasSeenSeq` / `lastSeq` / `poisoned` track the per-peer voice-frame stream
// so a stuck or wildly-skipping producer cannot poison the mix. The seq
// fields are touched from the L2CAP receive thread (single producer per
// device); mixer tick reads `poisoned` only for telemetry/diagnostics, hence
// atomic on `poisoned` but plain on `lastSeq` / `hasSeenSeq`.
//
// `hasSeenSeq` is a separate flag rather than `lastSeq != 0` because seq is
// uint32 and wraps: after a legitimate wrap to seq=0, that 0 is a valid
// watermark that must still gate subsequent delta checks.
struct DeviceAudioBuffer {
    AudioRingBuffer ringBuffer;
    std::atomic<bool> poisoned{false};   // true while producer is being skipped
    bool hasSeenSeq{false};              // false until the first frame arrives
    uint32_t lastSeq{0};                 // last accepted (or poison-advanced) seq
};

class AudioMixer {
private:
    // Device registry protected by mutex (rare changes: peer join/leave)
    std::mutex deviceRegistryMutex;
    std::map<int, std::shared_ptr<DeviceAudioBuffer>> devices;  // shared_ptr for safe concurrent access

    // Pre-allocated buffers for mixing (avoid heap allocations in audio path)
    std::vector<std::pair<int, std::shared_ptr<DeviceAudioBuffer>>> deviceSnapshotBuffer;
    std::vector<int16_t> tempMixBuffer;

    static constexpr int kMaxDevices = 8;  // Increased from 3 to support more peers
    static constexpr int kMaxFrames = 1024;  // Max frames for tempMixBuffer

public:
    // Stuck-producer prune threshold. A frame whose forward delta from the
    // last accepted seq exceeds this value is dropped and the peer is marked
    // poisoned. Recovery happens on the next frame whose forward delta from
    // the (poison-advanced) watermark falls in (0, kPoisonThreshold] — see
    // the [onVoiceFrame] contract below for the full state machine. Matches
    // the protocol spec ("after 16 missed sequence numbers ... stops mixing
    // that peer's stream until the next valid frame arrives").
    static constexpr uint32_t kPoisonThreshold = 16;

    AudioMixer();

    // Add a device (peer) to the mixer. Returns true on success.
    bool addDevice(int deviceId);

    // Remove a device from the mixer
    void removeDevice(int deviceId);

    // Update audio data for a device (called from local mic path).
    // Lock-free: writes to the device's ring buffer without blocking.
    // Used for the local-mic device (id 0) which has no over-the-wire seq.
    void updateDeviceAudio(int deviceId, const int16_t* audioData, int numFrames);

    // Feed a peer-arrived voice frame (with its over-the-wire seq) into the
    // mixer. Implements the stuck-producer prune from
    // [docs/protocol.md] § Voice frame format:
    //
    //  - Forward delta > [kPoisonThreshold]: poison the peer, drop the frame,
    //    advance the watermark to [seq] so the next within-threshold frame
    //    recovers.
    //  - Forward delta in (0, kPoisonThreshold]: accept, mix, clear poison
    //    if it was set.
    //  - Delta <= 0 (out-of-order or duplicate): silently drop without
    //    touching the watermark or the poison flag.
    //
    // Comparison uses a wrap-safe int32 delta so the rule holds across the
    // uint32 [seq] rollover at 2^32.
    //
    // Lock-free for the audio path; the registry mutex is taken only briefly
    // to look up the device.
    void onVoiceFrame(int deviceId, uint32_t seq, const int16_t* pcm, int numFrames);

    // Returns true if the device is currently being skipped due to a recent
    // big seq gap. Returns false for unknown deviceIds. Intended for tests
    // and diagnostics.
    bool isPoisoned(int deviceId);

    // Get mixed audio for a specific device (mix-minus: all others except this device).
    // Lock-free: reads from ring buffers without blocking.
    void getMixedAudioForDevice(int deviceId, int16_t* outputBuffer, int numFrames);

    // Clear all devices
    void clear();

    // Get list of active device IDs (for mixer tick thread)
    std::vector<int> getActiveDevices();
};

extern AudioMixer* g_audioMixer;

#endif // AUDIO_MIXER_H
