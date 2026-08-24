#!/bin/bash
# Regenerates the Xcode project and builds the app (Debug).
#
# Works on a clean clone with no Apple account: Debug signs ad-hoc, so no
# certificate, team membership or provisioning profile is needed. To build
# under your own team, pass it through: build.sh DEVELOPMENT_TEAM=XXXXXXXXXX
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate
exec env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  xcodebuild build \
    -project Jot.xcodeproj \
    -scheme Jot \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -quiet "$@"
