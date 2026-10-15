#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
swiftc -O scripts/make-icon.swift -o "$work/make-icon"
"$work/make-icon" "$work"
iconutil -c icns "$work/AppIcon.iconset" -o AppIcon.icns
cp "$work/AppIcon-1024.png" "${ICON_PREVIEW:-$work/preview.png}" 2>/dev/null || true
echo "$work"
