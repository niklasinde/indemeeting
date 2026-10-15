#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

OUT="$(mktemp -d)/tests"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    Sources/MeetingRecorder/AudioMixer.swift \
    Sources/MeetingRecorder/RecordingLogic.swift \
    Sources/MeetingRecorder/MeetingDetection.swift \
    Sources/MeetingRecorder/ProcessingLogic.swift \
    Sources/MeetingRecorder/LibraryLogic.swift \
    Tests/MeetingRecorderTests/Tests.swift \
    Tests/Runner/main.swift \
    -o "$OUT"
"$OUT"
