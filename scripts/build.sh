#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Prefer the complete Xcode toolchain so SwiftUI macros and the SDK match.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p .build/app-cache dist
export CLANG_MODULE_CACHE_PATH="$PWD/.build/app-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/app-cache"
xcrun swift build -c release --disable-sandbox --cache-path .build/package-cache --scratch-path .build/app --build-system native
grammy_bin_dir="$(xcrun swift build -c release --show-bin-path --disable-sandbox --cache-path .build/package-cache --scratch-path .build/app --build-system native)"
grammy_bundle="$PWD/dist/Grammy.app"
mkdir -p "$grammy_bundle/Contents/MacOS" "$grammy_bundle/Contents/Resources"
cp "$grammy_bin_dir/Grammy" "$grammy_bundle/Contents/MacOS/Grammy"
cp Resources/Info.plist "$grammy_bundle/Contents/Info.plist"
if [[ -n "${GRAMMY_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$GRAMMY_SIGNING_IDENTITY" "$grammy_bundle"
else
    codesign --force --sign - "$grammy_bundle"
fi
codesign --verify --strict "$grammy_bundle"
printf 'Built %s\n' "$grammy_bundle"
