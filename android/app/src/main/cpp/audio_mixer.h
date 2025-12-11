#ifndef AUDIO_MIXER_H
#define AUDIO_MIXER_H

#include <vector>
#include <map>
#include <mutex>
#include <cstring>
#include <algorithm>

class AudioMixer {
private:
    std::mutex mixerMutex;
    std::map<int, std::vector<int16_t>> deviceBuffers;
    static constexpr int kMaxDevices = 3;
    
public:
    bool addDevice(int deviceId);
    void removeDevice(int deviceId);
    void updateDeviceAudio(int deviceId, const int16_t* audioData, int numFrames);
    void getMixedAudioForDevice(int deviceId, int16_t* outputBuffer, int numFrames);
    void clear();
};

extern AudioMixer* g_audioMixer;

#endif // AUDIO_MIXER_H
