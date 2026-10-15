# MeetingRecorder

Menu-bar app that records the microphone, plus system audio (ScreenCaptureKit) when Screen Recording is granted, into one mono AAC file at
`~/Movies/MeetingRecordings/Meeting-YYYY-MM-DD-HHmm.m4a`. All sources are converted to 48 kHz mono float,
summed, and encoded. Works independently of Notion or any other meeting tool.

## Build

    ./build.sh

Produces `MeetingRecorder.app`, ad-hoc signed with `MeetingRecorder.entitlements`. Requires macOS 13+ and the
Swift toolchain. If `swift build` fails (e.g. a broken Command Line Tools SwiftPM), the script falls back to `swiftc`.

## Test

    ./test.sh

Compiles the mixer and pure recording helpers with `swiftc` together with `Tests/MeetingRecorderTests/Tests.swift` and runs
them (exit code is non-zero on failure), so it needs neither SwiftPM nor Xcode. On a machine with a working toolchain
`swift test` runs the same tests through XCTest. Tests that need real permissions or hardware are not covered.

## Run

    open MeetingRecorder.app

A waveform icon appears in the menu bar (no Dock icon). Choose Start Recording; the icon turns red and the menu
shows elapsed time. Stop Recording reveals the file in Finder.

## First-run setup

On first launch a Setup window opens (it does not depend on the menu-bar icon being visible). It walks through
Microphone, optional Screen Recording (with a Relaunch button), a 5-second test recording and a tip on finding the menu-bar
icon. Reopen it any time from the menu bar via "Setup & Help…".

## Permissions

Only the microphone is required. On first start macOS asks for:

- Microphone: allow.
- Screen Recording (optional, needed for system audio, i.e. the other participants): allow in System Settings > Privacy & Security >
  Screen & System Audio Recording, then quit and reopen the app, since macOS applies it on relaunch.

Without Screen Recording the app records your microphone only and the menu shows "Microphone only — system audio off".
The same fallback applies if system audio fails to start. If the microphone is denied the menu shows a message and an
"Open Privacy Settings" button. Ad-hoc signing changes the app identity on each rebuild, so a Screen Recording grant may
need to be redone (remove the old entry and add the app again).
