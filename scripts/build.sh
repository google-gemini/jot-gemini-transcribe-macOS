#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Regenerates the Xcode project and builds the app (Debug).
#
# Works on a clean clone with no Apple account: Debug signs ad-hoc, so no
# certificate, team membership or provisioning profile is needed. To build
# under your own team, pass it through: build.sh DEVELOPMENT_TEAM=XXXXXXXXXX
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate
# Some corporate-managed git configs set safe.bareRepository=explicit, which
# breaks SPM's bare clone cache.
exec env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  xcodebuild build \
    -project Jot.xcodeproj \
    -scheme Jot \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -quiet "$@"
