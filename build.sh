#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source scripts/sdk.sh

APP=MeetingRecorder.app
BIN=.build/release/MeetingRecorder

mkdir -p .build/release
if ! swift build -c release; then
    echo "swift build failed (broken SwiftPM toolchain?), falling back to swiftc"
    swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" -parse-as-library \
        Sources/MeetingRecorder/*.swift -o "$BIN"
else
    BIN="$(swift build -c release --show-bin-path)/MeetingRecorder"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MeetingRecorder"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - --entitlements MeetingRecorder.entitlements "$APP"
echo "Built $(pwd)/$APP"
