#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

OUT="$(mktemp -d)/tests"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    Sources/MeetingRecorder/AudioMixer.swift \
    Sources/MeetingRecorder/AudioAppender.swift \
    Sources/MeetingRecorder/RecordingLogic.swift \
    Sources/MeetingRecorder/MeetingDetection.swift \
    Sources/MeetingRecorder/ProcessingLogic.swift \
    Sources/MeetingRecorder/LanguageLogic.swift \
    Sources/MeetingRecorder/SettingsLogic.swift \
    Sources/MeetingRecorder/WhisperLogic.swift \
    Sources/MeetingRecorder/SpeakerLogic.swift \
    Sources/MeetingRecorder/LibraryLogic.swift \
    Sources/MeetingRecorder/SQLiteDatabase.swift \
    Sources/MeetingRecorder/MeetingStore.swift \
    Sources/MeetingRecorder/ActivityLogic.swift \
    Sources/MeetingRecorder/ActivityLinks.swift \
    Sources/MeetingRecorder/ActivityStore.swift \
    Sources/MeetingRecorder/ClaudeEvents.swift \
    Sources/MeetingRecorder/ClaudePlugin.swift \
    Sources/MeetingRecorder/MCPServer.swift \
    Tests/MeetingRecorderTests/Tests.swift \
    Tests/MeetingRecorderTests/StoreTests.swift \
    Tests/MeetingRecorderTests/ActivityTests.swift \
    Tests/MeetingRecorderTests/PluginTests.swift \
    Tests/Runner/main.swift \
    -o "$OUT"
"$OUT"
