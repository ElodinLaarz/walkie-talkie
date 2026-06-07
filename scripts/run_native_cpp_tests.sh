#!/bin/bash
# Build and run all native C++ unit tests.
# Called by both scripts/presubmit.sh and .github/workflows/flutter.yml so that
# both entry points execute exactly the same commands and cannot drift apart.
set -e

cd "$(dirname "$0")/.."

for required in \
    test/cpp/mixer_test.cpp \
    test/cpp/jitter_buffer_test.cpp \
    test/cpp/resampler_test.cpp \
    test/cpp/talking_event_queue_test.cpp \
    test/cpp/ring_buffer_test.cpp \
    test/cpp/opus_codec_test.cpp \
    test/cpp/vad_detector_test.cpp \
    test/cpp/playback_stream_config_test.cpp \
    test/cpp/peer_audio_manager_test.cpp \
    android/app/src/main/cpp/audio_mixer.cpp \
    android/app/src/main/cpp/playback_stream_config.h \
    android/app/src/main/cpp/talking_event_queue.h \
    android/app/src/main/cpp/ring_buffer.h \
    android/app/src/main/cpp/opus_codec.h \
    android/app/src/main/cpp/opus_codec.cpp \
    android/app/src/main/cpp/vad_detector.h \
    android/app/src/main/cpp/peer_audio_manager.cpp \
    android/app/src/main/cpp/peer_audio_manager.h \
    android/app/src/main/cpp/jitter_buffer.cpp \
    android/app/src/main/cpp/jitter_buffer.h; do
  if [ ! -f "$required" ]; then
    echo "$required missing — failing fast"
    exit 1
  fi
done

mkdir -p build/cpp_test

# mixer_test links the production audio_mixer.cpp via the host shims under
# test/cpp/ (introduced by #96 to retire the fork).
${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I test/cpp \
    -I android/app/src/main/cpp \
    test/cpp/mixer_test.cpp \
    android/app/src/main/cpp/audio_mixer.cpp \
    -o build/cpp_test/mixer_test
build/cpp_test/mixer_test

# jitter_buffer_test exercises the production jitter_buffer.cpp.
${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I test/cpp \
    -I android/app/src/main/cpp \
    test/cpp/jitter_buffer_test.cpp \
    android/app/src/main/cpp/jitter_buffer.cpp \
    -o build/cpp_test/jitter_buffer_test
build/cpp_test/jitter_buffer_test

# resampler_test exercises header-only resampler.h.
${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I test/cpp \
    -I android/app/src/main/cpp \
    test/cpp/resampler_test.cpp \
    -o build/cpp_test/resampler_test
build/cpp_test/resampler_test

# talking_event_queue_test exercises header-only talking_event_queue.h —
# the SPSC ring that moves JNI dispatch off the audio thread (#99).
${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I test/cpp \
    -I android/app/src/main/cpp \
    test/cpp/talking_event_queue_test.cpp \
    -o build/cpp_test/talking_event_queue_test
build/cpp_test/talking_event_queue_test

# ring_buffer_test exercises header-only ring_buffer.h (#128).
${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I test/cpp \
    -I android/app/src/main/cpp \
    test/cpp/ring_buffer_test.cpp \
    -o build/cpp_test/ring_buffer_test
build/cpp_test/ring_buffer_test

# vad_detector_test exercises the two-sided hysteresis state machine extracted
# from audio_engine.cpp (#248). Header-only; no extra link deps beyond the STL.
${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I test/cpp \
    -I android/app/src/main/cpp \
    test/cpp/vad_detector_test.cpp \
    -o build/cpp_test/vad_detector_test
build/cpp_test/vad_detector_test

# playback_stream_config_test pins the output Oboe stream config that fixes the
# quiet-playout bug. Header-only: needs Oboe's (header-only) Definitions.h, no
# Oboe library and no NDK.
${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I test/cpp \
    -I android/app/src/main/cpp \
    -I android/app/src/main/cpp/oboe/include \
    test/cpp/playback_stream_config_test.cpp \
    -o build/cpp_test/playback_stream_config_test
build/cpp_test/playback_stream_config_test

# opus_codec_test exercises OpusEncoder/OpusDecoder from opus_codec.cpp.
# Requires libopus and pkg-config.
if ! command -v pkg-config >/dev/null 2>&1; then
    echo "pkg-config not found — install it (apt install pkg-config) to run opus_codec_test."
    exit 1
fi
if ! pkg-config --exists opus; then
    echo "libopus not found via pkg-config — install it (apt install libopus-dev) to run opus_codec_test."
    exit 1
fi
${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I test/cpp \
    -I android/app/src/main/cpp \
    $(pkg-config --cflags opus) \
    test/cpp/opus_codec_test.cpp \
    android/app/src/main/cpp/opus_codec.cpp \
    $(pkg-config --libs opus) \
    -o build/cpp_test/opus_codec_test
build/cpp_test/opus_codec_test

# peer_audio_manager_test exercises PeerAudioManager::onVoiceFramePushed —
# the C++ half of the Kotlin/JNI seq-range-check path from issue #247.
# Links audio_mixer, jitter_buffer, and opus_codec. Also requires libopus.
${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I test/cpp \
    -I android/app/src/main/cpp \
    $(pkg-config --cflags opus) \
    test/cpp/peer_audio_manager_test.cpp \
    android/app/src/main/cpp/peer_audio_manager.cpp \
    android/app/src/main/cpp/audio_mixer.cpp \
    android/app/src/main/cpp/jitter_buffer.cpp \
    android/app/src/main/cpp/opus_codec.cpp \
    $(pkg-config --libs opus) \
    -o build/cpp_test/peer_audio_manager_test
build/cpp_test/peer_audio_manager_test
