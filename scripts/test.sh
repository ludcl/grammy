#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# XCTest ships with full Xcode, not the standalone Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p .build/test-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/test-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/test-cache"
xcrun swift test --disable-sandbox --cache-path .build/package-cache --scratch-path .build/tests --build-system native
