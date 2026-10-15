#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

OUT="$(mktemp -d)/tests"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
    Sources/MeetingRecorder/AudioMixer.swift \
    Sources/MeetingRecorder/AudioAppender.swift \
    Sources/MeetingRecorder/RecordingLogic.swift \
    Sources/MeetingRecorder/MeetingDetection.swift \
    Sources/MeetingRecorder/ProcessingLogic.swift \
    Sources/MeetingRecorder/LibraryLogic.swift \
    Sources/MeetingRecorder/SQLiteDatabase.swift \
    Sources/MeetingRecorder/MeetingStore.swift \
    Tests/MeetingRecorderTests/Tests.swift \
    Tests/MeetingRecorderTests/StoreTests.swift \
    Tests/Runner/main.swift \
    -o "$OUT"
"$OUT"
