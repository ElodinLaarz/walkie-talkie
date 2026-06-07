#pragma once

// Output (playback) Oboe stream configuration, factored out of audio_engine.cpp
// so it can be asserted by a host unit test. audio_engine.cpp itself is not
// host-testable (opening an Oboe stream needs a device), but these enum choices
// are pure data, and only <oboe/Definitions.h> — which is header-only — is
// needed to pin them. See playback_stream_config_test.cpp.
//
// These values fix two on-device playout bugs that made incoming voice
// near-inaudible:
//
//  1. Wrong volume stream. The app runs in MODE_IN_COMMUNICATION (so
//     AudioManager.setCommunicationDevice can steer the route). Oboe's default
//     output Usage is Media, which rides STREAM_MUSIC — but in communication
//     mode the hardware volume keys control STREAM_VOICE_CALL. The playing
//     stream was therefore un-raisable and sat quiet. Usage::VoiceCommunication
//     (with ContentType::Speech) puts playout on STREAM_VOICE_CALL, so the
//     volume keys control it and it follows the communication-device route.
//
//  2. MMAP bypasses the speaker DSP. A LowLatency + Exclusive output takes the
//     MMAP fast path on devices that grant it (e.g. Pixel), which bypasses the
//     platform speaker loudness/protection processing — the loudspeaker was
//     near-silent on the Pixel while a non-MMAP device (moto) was loud.
//     PerformanceMode::None + SharingMode::Shared keep playout on the normal
//     mixer path so the speaker DSP applies. Output is write()-driven from the
//     input callback, so dropping LowLatency does not change callback burst
//     sizing.

#include <oboe/Definitions.h>

namespace audio_engine_config {

inline constexpr oboe::Usage kPlaybackUsage = oboe::Usage::VoiceCommunication;
inline constexpr oboe::ContentType kPlaybackContentType =
    oboe::ContentType::Speech;
inline constexpr oboe::PerformanceMode kPlaybackPerformanceMode =
    oboe::PerformanceMode::None;
inline constexpr oboe::SharingMode kPlaybackSharingMode =
    oboe::SharingMode::Shared;

}  // namespace audio_engine_config
