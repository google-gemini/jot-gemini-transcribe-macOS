#!/bin/bash
# Runs the TranscribeCore test suite.
# The GIT_CONFIG override is needed on machines whose managed git config sets
# safe.bareRepository=explicit (e.g. google-git), which breaks SPM's bare clone cache.
set -euo pipefail
cd "$(dirname "$0")/.."
exec env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  swift test --package-path TranscribeCore "$@"
