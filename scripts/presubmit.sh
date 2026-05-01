#!/bin/bash
set -e

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
    android/app/src/main/cpp/audio_mixer.cpp \
    android/app/src/main/cpp/talking_event_queue.h; do
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
