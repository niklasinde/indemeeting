#!/bin/bash
# Builds a signed universal app and packs it into dist/WorkTime-<version>.dmg for sharing.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)"
STAGE="dist/WorkTime-$VERSION"
APP="$STAGE/WorkTime.app"
DMG="dist/WorkTime-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
./build.sh --release "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|Identifier|Runtime|flags"
lipo -info "$APP/Contents/MacOS/MeetingRecorder"
echo "Gatekeeper (expected to reject: the app is not notarized):"
spctl -a -vv "$APP" 2>&1 || true

ln -s /Applications "$STAGE/Applications"
cp "scripts/How to open.txt" "$STAGE/"
hdiutil create -volname "WorkTime $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
rm -rf "$STAGE"
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
