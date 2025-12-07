#!/bin/bash
set -e

echo "Running formatting checks..."
dart format --output=none --set-exit-if-changed .

echo "Running analysis..."
flutter analyze

echo "Running tests..."
flutter test
