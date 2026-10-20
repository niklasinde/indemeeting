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
    Sources/MeetingRecorder/ProjectSetup.swift \
    Sources/MeetingRecorder/ActivityStore.swift \
    Sources/MeetingRecorder/ClaudeEvents.swift \
    Sources/MeetingRecorder/ClaudePlugin.swift \
    Sources/MeetingRecorder/MCPServer.swift \
    Sources/MeetingRecorder/ChatLogic.swift \
    Sources/MeetingRecorder/ChatStore.swift \
    Sources/MeetingRecorder/ChatToolbox.swift \
    Sources/MeetingRecorder/GitHubLogic.swift \
    Sources/MeetingRecorder/GitHubDetail.swift \
    Sources/MeetingRecorder/GitHubActivity.swift \
    Sources/MeetingRecorder/GitHubComments.swift \
    Sources/MeetingRecorder/GitHubBranch.swift \
    Sources/MeetingRecorder/GitHubCommentsLogic.swift \
    Sources/MeetingRecorder/GitHubStore.swift \
    Sources/MeetingRecorder/GitHubSelection.swift \
    Sources/MeetingRecorder/GitHubClaude.swift \
    Sources/MeetingRecorder/ClaudeProcess.swift \
    Sources/MeetingRecorder/EmbeddedTerminal.swift \
    Sources/Shared/PhoneAPI.swift \
    Sources/MeetingRecorder/PhoneHTTP.swift \
    Sources/MeetingRecorder/PhonePairingLogic.swift \
    Sources/MeetingRecorder/PhoneSecretStores.swift \
    Sources/MeetingRecorder/PhoneChatLogic.swift \
    Sources/MeetingRecorder/PhoneEndpoints.swift \
    Tests/MeetingRecorderTests/Tests.swift \
    Tests/MeetingRecorderTests/StoreTests.swift \
    Tests/MeetingRecorderTests/ActivityTests.swift \
    Tests/MeetingRecorderTests/PluginTests.swift \
    Tests/MeetingRecorderTests/ChatTests.swift \
    Tests/MeetingRecorderTests/GitHubTests.swift \
    Tests/MeetingRecorderTests/GitHubDetailTests.swift \
    Tests/MeetingRecorderTests/GitHubSelectionTests.swift \
    Tests/MeetingRecorderTests/GitHubActivityTests.swift \
    Tests/MeetingRecorderTests/GitHubCommentsTests.swift \
    Tests/MeetingRecorderTests/GitHubBranchTests.swift \
    Tests/MeetingRecorderTests/GitHubClaudeTests.swift \
    Tests/MeetingRecorderTests/EmbeddedTerminalTests.swift \
    Tests/MeetingRecorderTests/PhoneTests.swift \
    Tests/Runner/main.swift \
    -o "$OUT"
"$OUT"
