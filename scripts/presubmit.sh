#!/bin/bash
set -e

echo "Running formatting checks..."
dart format --output=none --set-exit-if-changed .

echo "Running analysis..."
flutter analyze

echo "Running tests..."
flutter test

echo "Building & running native mixer test..."
if [ ! -f test/cpp/mixer_test.cpp ]; then
  echo "test/cpp/mixer_test.cpp missing — failing fast"
  exit 1
fi
mkdir -p build/cpp_test
g++ -std=c++17 test/cpp/mixer_test.cpp -o build/cpp_test/mixer_test
build/cpp_test/mixer_test
