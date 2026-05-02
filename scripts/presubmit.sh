#!/bin/bash
set -e

# Change to the repo root regardless of where the script is invoked from,
# so all subsequent relative paths (dart format, test/cpp/, etc.) resolve
# correctly whether the caller is inside the scripts/ directory or elsewhere.
cd "$(dirname "$0")/.."

echo "Validating Play Store metadata character limits..."
bash scripts/validate_store_metadata.sh

echo "Running formatting checks..."
dart format --output=none --set-exit-if-changed .

echo "Running analysis..."
flutter analyze

echo "Running tests..."
flutter test

echo "Building & running native C++ tests..."
mkdir -p build/cpp_test
for required in \
    test/cpp/mixer_test.cpp \
    test/cpp/jitter_buffer_test.cpp \
    test/cpp/resampler_test.cpp \
    test/cpp/talking_event_queue_test.cpp \
    test/cpp/ring_buffer_test.cpp \
    test/cpp/opus_codec_test.cpp \
    android/app/src/main/cpp/audio_mixer.cpp \
    android/app/src/main/cpp/talking_event_queue.h \
    android/app/src/main/cpp/ring_buffer.h \
    android/app/src/main/cpp/opus_codec.h \
    android/app/src/main/cpp/opus_codec.cpp; do
  if [ ! -f "$required" ]; then
    echo "$required missing — failing fast"
    exit 1
  fi
done

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

# ring_buffer_test exercises header-only ring_buffer.h — SPSC lock-free audio
# ring buffer (#128: previously had zero unit tests).
${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I test/cpp \
    -I android/app/src/main/cpp \
    test/cpp/ring_buffer_test.cpp \
    -o build/cpp_test/ring_buffer_test
build/cpp_test/ring_buffer_test

# opus_codec_test exercises OpusEncoder/OpusDecoder from opus_codec.cpp.
# Requires libopus and pkg-config. Without an explicit preflight, a missing
# libopus surfaces as a confusing "fatal error: opus.h: No such file" from g++
# instead of a clear install hint.
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
