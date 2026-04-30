#ifndef PEER_AUDIO_MANAGER_H
#define PEER_AUDIO_MANAGER_H

#include <atomic>
#include <jni.h>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "audio_config.h"
#include "audio_mixer.h"
#include "jitter_buffer.h"
#include "opus_codec.h"

// Owns the per-peer audio plumbing on the host (or the host's mirror image
// running on a guest):
//
//   - Device-id assignment (MAC ↔ id) keyed off the BLE MAC string.
//   - Per-peer Opus encoder / decoder pair.
//   - Per-peer adaptive jitter buffer (see jitter_buffer.h).
//   - The mixer tick that drives mix-minus encoding once every
//     audio_config::kFrameDurationMs ms.
//
// Lifecycle: `PeerAudioManager` is constructed once at JNI init via
// `nativeInit`. The mixer thread runs from `startMixerThread` to
// `stopMixerThread`. The class is intentionally not copyable; all access
// goes through the singleton `g_peerAudioManager`.
class PeerAudioManager {
public:
    PeerAudioManager();
    ~PeerAudioManager();

    PeerAudioManager(const PeerAudioManager&) = delete;
    PeerAudioManager& operator=(const PeerAudioManager&) = delete;

    // Per-peer telemetry snapshot. Read by JNI to feed the LinkQuality
    // control-plane message — wiring of the message itself is a follow-up,
    // but the C++ surface is in place so the BLE side can poll today.
    struct LinkTelemetry {
        uint32_t underrunCount{0};
        uint32_t lateFrameCount{0};
        uint32_t jitterTargetDepth{0};
        uint32_t jitterCurrentDepth{0};
        int currentBitrate{audio_config::kDefaultBitrate};
        bool valid{false};
    };

    // Register a peer (assign device ID). Returns device ID, or -1 on error.
    int registerPeer(const std::string& macAddress);

    // Unregister a peer (remove from mixer). Tears down the peer's Opus
    // codec pair and jitter buffer.
    void unregisterPeer(const std::string& macAddress);

    // Get device ID for a MAC address (-1 if not found).
    int getDeviceId(const std::string& macAddress);
    std::string getMacAddress(int deviceId);

    // Push a peer-arrived Opus frame into the peer's jitter buffer. Called
    // from the L2CAP receive path. `seq` is the protocol's per-link uint32.
    // Returns true if accepted; false if dropped (late, duplicate, or peer
    // not registered).
    bool onVoiceFramePushed(const std::string& macAddress, uint32_t seq,
                            const uint8_t* opusData, int opusSize);

    // Set this peer's outbound encoder bitrate. Called when LinkQuality
    // telemetry suggests adapting. Clamped to [kBitrateLow, kBitrateHigh].
    // Returns the actual bitrate applied, or -1 if the peer isn't registered.
    int setPeerBitrate(const std::string& macAddress, int bps);

    // Snapshot current link telemetry for a peer.
    LinkTelemetry getTelemetry(const std::string& macAddress);

    // Start / stop the mixer tick thread. The thread runs decode →
    // updateDeviceAudio → mix-minus → encode → JNI callback once every
    // audio_config::kFrameDurationMs ms.
    bool startMixerThread();
    void stopMixerThread();

    // Set JNI callback object for sending audio (Java-side
    // PeerAudioManager.onMixedAudioReady).
    void setCallback(JNIEnv* env, jobject callback);

    // Clear all peers. Stops the mixer thread first. Idempotent.
    void clear();

private:
    // Per-peer state. `mutex` serializes access from the BLE receive thread
    // (push side via `onVoiceFramePushed`) and the mixer thread (pop/decode
    // and encode sides) — neither `JitterBuffer` nor the Opus codec wrappers
    // are internally thread-safe, so all access to those three fields must
    // happen with `mutex` held.
    //
    // `bitrate` is `std::atomic<int>` so a JNI caller can publish a hint
    // without contending the mixer-tick lock. The applied bitrate value
    // also passes through `OpusEncoder::setBitrate`, which is itself called
    // under `mutex`.
    //
    // `consecutiveUnderruns` is touched only on the mixer thread.
    struct PeerState {
        std::mutex mutex;
        int deviceId{-1};
        std::unique_ptr<OpusEncoder> encoder;
        std::unique_ptr<OpusDecoder> decoder;
        std::unique_ptr<JitterBuffer> jitterBuffer;
        std::atomic<int> bitrate{audio_config::kDefaultBitrate};
        // Two consecutive PLC frames sound increasingly mechanical; we use
        // this to bias toward popAny() on the third underrun in a row.
        int consecutiveUnderruns{0};
    };

    void mixerTickLoop();

    // Send a freshly-encoded mix-minus frame to a peer via the JNI callback.
    // `env` must be valid for the calling (mixer) thread — see mixerTickLoop
    // for the once-per-thread Attach.
    void sendAudioToPeer(JNIEnv* env, const std::string& macAddress,
                         const uint8_t* opusData, int opusSize, uint32_t seq);

    std::mutex peerRegistryMutex_;
    std::map<std::string, std::shared_ptr<PeerState>> peers_;
    std::map<int, std::string> deviceIdToMac_;
    int nextDeviceId_{1};  // 0 reserved for local mic.

    std::thread mixerThread_;
    std::atomic<bool> mixerRunning_{false};

    // jvm_ is published lazily by setCallback() (which captures it from
    // the calling JNIEnv) and read by mixerTickLoop's lazy-attach path on
    // every tick. std::atomic with release/acquire prevents the C++ data
    // race that a plain pointer would create between the publishing thread
    // and the polling mixer thread.
    std::atomic<JavaVM*> jvm_{nullptr};

    // Guards `callbackObject_` against the race between the JNI thread's
    // `setCallback` (which deletes + replaces the global ref) and the
    // mixer thread's `sendAudioToPeer` (which reads and uses the global
    // ref). The lock is held only across the snapshot — JNI calls happen
    // on the snapshotted local reference outside the lock.
    std::mutex callbackMutex_;
    jobject callbackObject_{nullptr};
};

extern PeerAudioManager* g_peerAudioManager;

#endif  // PEER_AUDIO_MANAGER_H
