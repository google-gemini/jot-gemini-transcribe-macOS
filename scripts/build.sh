#!/bin/bash
# Regenerates the Xcode project and builds the app (Debug).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
exec env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  xcodebuild build \
    -project GoogleTranscribe.xcodeproj \
    -scheme GoogleTranscribe \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -quiet "$@"
