#ifndef PEER_AUDIO_MANAGER_H
#define PEER_AUDIO_MANAGER_H

#include <string>
#include <map>
#include <mutex>
#include <atomic>
#include <thread>
#include <jni.h>
#include "audio_mixer.h"
#include "opus_codec.h"

// Manages peer connections, device ID assignment, and the mixer tick thread
class PeerAudioManager {
private:
    std::mutex peerRegistryMutex;
    std::map<std::string, int> macToDeviceId;  // MAC address → device ID
    std::map<int, std::string> deviceIdToMac;  // device ID → MAC address
    int nextDeviceId = 1;  // Start from 1 (0 reserved for local mic)

    // Mixer tick thread
    std::thread mixerThread;
    std::atomic<bool> mixerRunning{false};

    // Opus encoders per peer (one per device ID)
    std::mutex encodersMutex;
    std::map<int, std::unique_ptr<::OpusEncoder>> encoders;

    // JNI callback references
    JavaVM* jvm = nullptr;
    jobject callbackObject = nullptr;  // Global reference to callback object

    // Mixer tick function (runs in separate thread)
    void mixerTickLoop();

    // Send mixed audio to a peer via JNI callback
    void sendAudioToPeer(const std::string& macAddress, const uint8_t* opusData, int opusSize, uint32_t seq);

public:
    PeerAudioManager();
    ~PeerAudioManager();

    // Register a peer (assign device ID). Returns device ID, or -1 on error.
    int registerPeer(const std::string& macAddress);

    // Unregister a peer (remove from mixer)
    void unregisterPeer(const std::string& macAddress);

    // Get device ID for a MAC address (-1 if not found)
    int getDeviceId(const std::string& macAddress);

    // Get MAC address for a device ID (empty string if not found)
    std::string getMacAddress(int deviceId);

    // Start the mixer tick thread
    bool startMixerThread();

    // Stop the mixer tick thread
    void stopMixerThread();

    // Set JNI callback object for sending audio
    void setCallback(JNIEnv* env, jobject callback);

    // Clear all peers
    void clear();
};

extern PeerAudioManager* g_peerAudioManager;

#endif // PEER_AUDIO_MANAGER_H
