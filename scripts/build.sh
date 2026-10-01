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
# Reuse the sole Developer ID identity when available, so rebuilds keep the
# same designated requirement and do not invalidate Accessibility grants.
grammy_identity="${GRAMMY_SIGNING_IDENTITY:-}"
if [[ -z "$grammy_identity" ]]; then
    grammy_identities=()
    while IFS= read -r grammy_candidate; do
        [[ -z "$grammy_candidate" ]] || grammy_identities+=("$grammy_candidate")
    done < <(security find-identity -v -p codesigning | awk -F '\"' '/Developer ID Application:/ {print $2}')
    if [[ ${#grammy_identities[@]} -eq 1 ]]; then
        grammy_identity="${grammy_identities[0]}"
    elif [[ ${#grammy_identities[@]} -gt 1 ]]; then
        printf 'Multiple Developer ID identities found. Set GRAMMY_SIGNING_IDENTITY to choose one.\n' >&2
        exit 1
    fi
fi
if [[ -n "$grammy_identity" ]]; then
    codesign --force --options runtime --timestamp --sign "$grammy_identity" "$grammy_bundle"
else
    printf 'No Developer ID signing identity found; Accessibility may need refreshing after each rebuild.\n' >&2
    codesign --force --sign - "$grammy_bundle"
fi
codesign --verify --strict "$grammy_bundle"
printf 'Built %s\n' "$grammy_bundle"
