# MeetingRecorder

Menu-bar app that records system audio (ScreenCaptureKit) and the microphone into one mono AAC file at
`~/Movies/MeetingRecordings/Meeting-YYYY-MM-DD-HHmm.m4a`. Both sources are converted to 48 kHz mono float,
summed, and encoded. Works independently of Notion or any other meeting tool.

## Build

    ./build.sh

Produces `MeetingRecorder.app`, ad-hoc signed with `MeetingRecorder.entitlements`. Requires macOS 13+ and the
Swift toolchain. If `swift build` fails (e.g. a broken Command Line Tools SwiftPM), the script falls back to `swiftc`.

## Run

    open MeetingRecorder.app

A waveform icon appears in the menu bar (no Dock icon). Choose Start Recording; the icon turns red and the menu
shows elapsed time. Stop Recording reveals the file in Finder.

## Permissions

On first start macOS asks for:

- Microphone: allow.
- Screen Recording (needed for system audio): allow in System Settings > Privacy & Security > Screen & System Audio Recording,
  then quit and reopen the app, since macOS applies it on relaunch.

If a permission is denied the menu shows a message and an "Open Privacy Settings" button. Ad-hoc signing changes the
app identity on each rebuild, so you may need to re-grant (remove the old entry and add the app again).
