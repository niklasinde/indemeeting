#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=MeetingRecorder.app

if swift build -c release; then
    BIN="$(swift build -c release --show-bin-path)/MeetingRecorder"
else
    echo "swift build failed, falling back to swiftc"
    BIN=.build/swiftc/MeetingRecorder
    mkdir -p "$(dirname "$BIN")"
    swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" -parse-as-library Sources/MeetingRecorder/*.swift -o "$BIN"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MeetingRecorder"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="MeetingRecorder Local"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    SIGN="$IDENTITY"
else
    SIGN=-
    echo "warning: no \"$IDENTITY\" signing identity, signing ad-hoc. macOS will ask for permissions again after every"
    echo "         rebuild. Run scripts/make-signing-identity.sh once to keep them."
fi
codesign --force --deep --sign "$SIGN" --entitlements MeetingRecorder.entitlements "$APP"
echo "Built $(pwd)/$APP"
