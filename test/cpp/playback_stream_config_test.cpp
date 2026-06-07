// Host-buildable regression guard for the output (playback) Oboe stream
// configuration in playback_stream_config.h.
//
// audio_engine.cpp can't be host-tested (opening an Oboe stream needs a real
// device), so the playout config it applies is factored into the header and
// pinned here. <oboe/Definitions.h> is header-only, so the enum values compile
// under a host g++ with no Oboe library or NDK.
//
// These exact values fix the "incoming voice too quiet / volume keys do
// nothing" bug:
//   - Usage::VoiceCommunication + ContentType::Speech put playout on
//     STREAM_VOICE_CALL — the stream the hardware volume keys control while the
//     app is in MODE_IN_COMMUNICATION — instead of the un-raisable STREAM_MUSIC
//     that the default Media usage rode.
//   - PerformanceMode::None + SharingMode::Shared keep playout off the MMAP
//     fast path, which bypasses the speaker loudness/protection DSP on devices
//     that grant MMAP (the loudspeaker was near-silent on a Pixel while a
//     non-MMAP device was loud).
// If playout is "optimized" back to LowLatency/Exclusive or loses the
// VoiceCommunication usage, this test fails loudly.
//
// Compile (see scripts/run_native_cpp_tests.sh):
//   g++ -std=c++17 -Wall -Wextra -I android/app/src/main/cpp
//       -I android/app/src/main/cpp/oboe/include
//       test/cpp/playback_stream_config_test.cpp
//       -o build/cpp_test/playback_stream_config_test

#include "playback_stream_config.h"

#include <cassert>
#include <iostream>

#include <oboe/Definitions.h>

namespace {

void testPlayoutUsesVoiceCallStream() {
    // STREAM_VOICE_CALL is the stream the volume keys control in
    // MODE_IN_COMMUNICATION; Media usage rode STREAM_MUSIC, which the keys
    // cannot touch in that mode, so playout was stuck quiet.
    assert(audio_engine_config::kPlaybackUsage ==
           oboe::Usage::VoiceCommunication);
    assert(audio_engine_config::kPlaybackContentType ==
           oboe::ContentType::Speech);
}

void testPlayoutAvoidsMmapFastPath() {
    // LowLatency + Exclusive selects the MMAP path on devices that grant it,
    // which bypasses the platform speaker loudness/protection DSP and makes the
    // loudspeaker near-inaudible.
    assert(audio_engine_config::kPlaybackPerformanceMode ==
           oboe::PerformanceMode::None);
    assert(audio_engine_config::kPlaybackSharingMode ==
           oboe::SharingMode::Shared);
    assert(audio_engine_config::kPlaybackPerformanceMode !=
           oboe::PerformanceMode::LowLatency);
    assert(audio_engine_config::kPlaybackSharingMode !=
           oboe::SharingMode::Exclusive);
}

}  // namespace

int main() {
    try {
        testPlayoutUsesVoiceCallStream();
        testPlayoutAvoidsMmapFastPath();
        std::cout << "All playback_stream_config tests passed!" << std::endl;
    } catch (const std::exception& e) {
        std::cerr << "Test failed: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
