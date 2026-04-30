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
    test/cpp/resampler_test.cpp; do
  if [ ! -f "$required" ]; then
    echo "$required missing — failing fast"
    exit 1
  fi
done

${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    test/cpp/mixer_test.cpp \
    -o build/cpp_test/mixer_test
build/cpp_test/mixer_test

${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I android/app/src/main/cpp \
    test/cpp/jitter_buffer_test.cpp \
    android/app/src/main/cpp/jitter_buffer.cpp \
    -o build/cpp_test/jitter_buffer_test
build/cpp_test/jitter_buffer_test

${CXX:-g++} -std=c++17 -Wall -Wextra -pthread \
    -I android/app/src/main/cpp \
    test/cpp/resampler_test.cpp \
    -o build/cpp_test/resampler_test
build/cpp_test/resampler_test
