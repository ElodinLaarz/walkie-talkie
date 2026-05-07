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

# Kotlin unit tests run in CI as `./gradlew :app:testDebugUnitTest --no-daemon`
# (see .github/workflows/flutter.yml). Mirror that here so a Kotlin regression
# (e.g. the L2CAP framing tests) is caught locally instead of on the next push.
# Skip on platforms where Gradle is unavailable; on Windows the script is
# typically invoked from WSL where gradlew works as on Linux/macOS.
if [ -x "android/gradlew" ]; then
  echo "Running Kotlin unit tests..."
  (cd android && ./gradlew :app:testDebugUnitTest --no-daemon)
else
  echo "Skipping Kotlin unit tests: android/gradlew not executable."
  echo "If this is a real environment, run 'chmod +x android/gradlew' once."
fi
