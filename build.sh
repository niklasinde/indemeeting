#!/bin/bash
# Usage: ./build.sh [--release] [path/to/App.app]
# --release builds a universal (arm64 + x86_64) binary and refuses to sign ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0
if [ "${1:-}" = --release ]; then RELEASE=1; shift; fi
APP="${1:-WorkTime.app}"
IDENTITY="MeetingRecorder Local"
ARCHS=""
[ $RELEASE = 1 ] && ARCHS="--arch arm64 --arch x86_64"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    SIGN="$IDENTITY"
elif [ $RELEASE = 1 ]; then
    echo "error: no \"$IDENTITY\" signing identity. Releases must be signed with it so friends keep their permissions"
    echo "       across updates. Import the exported .p12, or run scripts/make-signing-identity.sh for a new one."
    exit 1
else
    SIGN=-
    echo "warning: no \"$IDENTITY\" signing identity, signing ad-hoc. macOS will ask for permissions again after every"
    echo "         rebuild. Run scripts/make-signing-identity.sh once to keep them."
fi

[ -d .deps/ggml.xcframework ] || scripts/build-ggml.sh

if swift build -c release $ARCHS; then
    BIN="$(swift build -c release $ARCHS --show-bin-path)/WorkTime"
elif [ $RELEASE = 1 ]; then
    echo "error: swift build failed"
    exit 1
else
    echo "swift build failed, falling back to swiftc (without Whisper and Ministral)"
    BIN=.build/swiftc/WorkTime
    mkdir -p "$(dirname "$BIN")"
    swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos26.0" -parse-as-library Sources/WorkTime/*.swift Sources/Shared/*.swift -o "$BIN"
fi

if [ -f agent/package.json ] && command -v npm >/dev/null; then
    (cd agent && npm ci --no-audit --no-fund --silent && npm run build --silent) || echo "warning: the agent sidecar did not build; the Agent window will say so"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WorkTime"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null)"; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

codesign --force --options runtime --sign "$SIGN" --entitlements WorkTime.entitlements "$APP"
echo "Built $APP"
