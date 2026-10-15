# MeetingRecorder

Menu-bar app that records the microphone, plus system audio (ScreenCaptureKit) when Screen Recording is granted, into one mono AAC file at
`~/Movies/MeetingRecordings/Meeting-YYYY-MM-DD-HHmm.m4a`. All sources are converted to 48 kHz mono float,
summed, and encoded. Works independently of Notion or any other meeting tool.

## Build

    ./build.sh

Produces `MeetingRecorder.app`, ad-hoc signed with `MeetingRecorder.entitlements`. Recording needs macOS 13+;
transcription and summaries need macOS 26+. Builds with `swift build` (Command Line Tools 27 / Swift 6.4 or Xcode); if
SwiftPM fails, the script falls back to plain `swiftc`.

## Test

    ./test.sh
    swift test

`test.sh` compiles the mixer and the pure recording and processing helpers (chunking, timestamps, markdown, file
names) with `swiftc` together with `Tests/MeetingRecorderTests/Tests.swift` and runs them (exit code is non-zero on
failure). `swift test` runs the same list through Swift Testing (or XCTest where that is the only framework). Tests that
need real permissions, hardware, speech models or Apple Intelligence are not covered; use the command-line mode below.

## Run

    open MeetingRecorder.app

A waveform icon appears in the menu bar (no Dock icon). Choose Start Recording; the icon turns red and the menu
shows elapsed time. Stop Recording reveals the file in Finder.

## Transcripts and summaries

Everything runs on the Mac; no audio or text leaves it. After Stop Recording the app transcribes the file and then
summarises it, writing next to the recording:

- `Meeting-YYYY-MM-DD-HHmm.transcript.md`: one `[hh:mm:ss] sentence` line per sentence.
- `Meeting-YYYY-MM-DD-HHmm.summary.md`: title, short summary, key points, decisions and action items (with owners when
  they are named).

The menu shows "Transcribing…", "Summarising…" and then "Open summary"; a notification opens the summary when it is
ready. "Transcribe & summarise a recording…" processes any existing audio file. Errors are shown in the menu and as a
notification. The audio file is only read, never changed or deleted.

"Meeting language" (Svenska / English, default Svenska) picks the transcription language and the language of the
summary.

- Transcription uses `SpeechAnalyzer` (macOS 26). English uses `SpeechTranscriber`. Swedish is not supported by
  `SpeechTranscriber` (checked on macOS 26.6), so it uses `DictationTranscriber`, the on-device dictation model in the same
  API. Missing language models are downloaded through `AssetInventory` on first use. No permission prompt is needed.
- Summaries use Apple's on-device Foundation Models (`SystemLanguageModel`), which require Apple Intelligence. Its
  context is about 4,096 tokens, so long transcripts are summarised in parts and the part summaries are combined. If the
  model is unavailable (Apple Intelligence off, Mac not eligible, model still downloading, language unsupported) the
  transcript is still written, the summary file and the menu say why, and how to enable it in System Settings >
  Apple Intelligence & Siri. Re-run "Transcribe & summarise a recording…" afterwards.

For a headless check, run the binary with a file:

    .build/debug/MeetingRecorder --process /path/to/Meeting.m4a --language sv-SE   # or en-US

It prints the progress and output paths and exits non-zero on failure, without starting the menu-bar app.

## First-run setup

On first launch a Setup window opens (it does not depend on the menu-bar icon being visible). It walks through
Microphone, optional Screen Recording (with a Relaunch button), optional Notifications, a 5-second test recording and a tip on finding the menu-bar
icon. Reopen it any time from the menu bar via "Setup & Help…".

## Meeting notifications

When another app keeps the default input device busy for more than 3 seconds (CoreAudio
`kAudioDevicePropertyDeviceIsRunningSomewhere`, no extra permission) and the app is not recording, a notification
"Meeting started — record it?" appears, naming Zoom, Teams, FaceTime, Slack, Notion or the frontmost browser when one is found.
Its Record button, or clicking it, starts recording. It is shown once per meeting and reset when the microphone is released,
so stopping your own recording mid-meeting does not bring it back. Turn it off with "Notify when a meeting starts" in the menu.

## Permissions

Only the microphone is required. On first start macOS asks for:

- Microphone: allow.
- Screen Recording (optional, needed for system audio, i.e. the other participants): allow in System Settings > Privacy & Security >
  Screen & System Audio Recording, then quit and reopen the app, since macOS applies it on relaunch.

Without Screen Recording the app records your microphone only and the menu shows "Microphone only — system audio off".
The same fallback applies if system audio fails to start. If the microphone is denied the menu shows a message and an
"Open Privacy Settings" button. Ad-hoc signing changes the app identity on each rebuild, so a Screen Recording grant may
need to be redone (remove the old entry and add the app again).
