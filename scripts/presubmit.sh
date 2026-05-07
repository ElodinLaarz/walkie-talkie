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
bash scripts/run_native_cpp_tests.sh
