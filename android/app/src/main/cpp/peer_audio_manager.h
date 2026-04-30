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
    // Per-peer state. The codecs and jitter buffer are accessed only from
    // the mixer thread (decode side) and the L2CAP receive path (push side);
    // peerStateMutex_ serializes the two. The `bitrate` field is read on
    // the mixer thread and written from JNI; it's atomic to avoid the
    // mutex on every mixer tick.
    struct PeerState {
        int deviceId{-1};
        std::unique_ptr<OpusEncoder> encoder;
        std::unique_ptr<OpusDecoder> decoder;
        std::unique_ptr<JitterBuffer> jitterBuffer;
        std::atomic<int> bitrate{audio_config::kDefaultBitrate};
        // Tracks whether decodeMissing has been the last action on the
        // decoder. Two consecutive PLC frames sound increasingly mechanical;
        // we use this to bias toward popAny() on the second underrun.
        int consecutiveUnderruns{0};
    };

    void mixerTickLoop();

    // Send a freshly-encoded mix-minus frame to a peer via the JNI callback.
    void sendAudioToPeer(const std::string& macAddress, const uint8_t* opusData,
                         int opusSize, uint32_t seq);

    std::mutex peerRegistryMutex_;
    std::map<std::string, std::shared_ptr<PeerState>> peers_;
    std::map<int, std::string> deviceIdToMac_;
    int nextDeviceId_{1};  // 0 reserved for local mic.

    std::thread mixerThread_;
    std::atomic<bool> mixerRunning_{false};

    JavaVM* jvm_{nullptr};
    jobject callbackObject_{nullptr};
};

extern PeerAudioManager* g_peerAudioManager;

#endif  // PEER_AUDIO_MANAGER_H
