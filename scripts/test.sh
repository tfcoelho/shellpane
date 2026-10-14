#!/bin/sh
# Runs the test suite. Use this instead of bare `swift test` with only the Command Line Tools:
# SwiftPM there doesn't always put swift-testing's macro plugin (host/plugins/testing) on the
# search path for incremental builds, and the tests fail to compile with "plugin for module
# 'TestingMacros' not found". Passing the path explicitly fixes it, with or without Xcode.
#
#   scripts/test.sh                       all tests
#   scripts/test.sh --filter Favorites    any swift test arguments
set -eu
cd "$(dirname "$0")/.."
SWIFT=$(xcrun --find swift 2>/dev/null || command -v swift)
PLUGINS="$(dirname "$(dirname "$SWIFT")")/lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
