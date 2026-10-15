# MeetingRecorder

Menu-bar app that records you (the microphone) and the meeting (system audio, i.e. the other participants, through a
Core Audio process tap) into one mono AAC file at `~/Movies/MeetingRecordings/Meeting-YYYY-MM-DD-HHmm.m4a`
(`-2`, `-3`, … when a minute already has one). All sources are converted to 48 kHz mono float, summed, and encoded.
Works independently of Notion or any other meeting tool.

While recording, the file is named `Meeting-…-HHmm.recording.m4a`; Stop Recording finalizes it and renames it. Quitting
the app (menu, Cmd-Q, logout, `kill`/SIGTERM, SIGINT, SIGHUP) stops and finalizes the recording first. Only a hard crash
or `kill -9` leaves a `.recording.m4a` behind. It has no index, so players cannot open it, but the audio written so far
is in it as raw AAC (48 kHz mono) and can be decoded with ffmpeg's libavcodec.

## Build

    ./build.sh

Produces `MeetingRecorder.app`, signed with `MeetingRecorder.entitlements`. Recording needs macOS 13+ (system audio
needs 14.2+); transcription and summaries need macOS 26+. Builds with `swift build` (Command Line Tools 27 / Swift 6.4 or Xcode); if
SwiftPM fails, the script falls back to plain `swiftc`.

### Keep permissions across rebuilds

macOS ties privacy grants to the app's code signature. An ad-hoc signature (`codesign --sign -`) changes with every
build, so macOS treats each build as a new app and asks again (or silently keeps the old, now useless, grant). Create a
stable local signing identity once:

    scripts/make-signing-identity.sh

It creates a self-signed code-signing certificate "MeetingRecorder Local" in the login keychain and trusts it for code
signing (macOS asks for your password; the first build may ask to let `codesign` use the key, choose Always Allow).
`build.sh` signs with it whenever `security find-identity -v -p codesigning` lists it and otherwise falls back to ad-hoc
with a warning. After the first build with the stable identity, remove the old Meeting Recorder entries in Privacy &
Security, grant the permissions once more, and they then persist across rebuilds.

## Test

    ./test.sh
    swift test

`test.sh` compiles the mixer and the pure recording, processing and library helpers (chunking, timestamps, markdown, file
names, the recordings list) with `swiftc` together with `Tests/MeetingRecorderTests/Tests.swift` and runs them (exit code is non-zero on
failure). `swift test` runs the same list through Swift Testing (or XCTest where that is the only framework). Tests that
need real permissions, hardware, speech models or Apple Intelligence are not covered; use the command-line mode below.

## Run

    open MeetingRecorder.app

A waveform icon appears in the menu bar (no Dock icon). Choose Start Recording; the icon turns red and the menu
shows elapsed time. Stop Recording reveals the file in Finder.

## App window

"Open Meeting Recorder" (Cmd-O) at the top of the menu, or opening the app again from Finder or Spotlight, shows the
main window (with a Dock icon while it is open). The sidebar lists the recordings in `~/Movies/MeetingRecordings`,
newest first, with date, time, duration and icons for an existing transcript and summary. In-progress
`.recording.m4a` files are left out. The list follows the folder as files appear or are removed.

Selecting a recording shows a player with a scrubber, its Summary and Transcript (rendered from the `.md` files), and
buttons to Reveal in Finder, Transcribe & summarise (same processing as the menu, with progress) and Delete, which
moves the audio, transcript and summary to the Trash after a confirmation. The toolbar has Start/Stop Recording with
the elapsed time, like the menu; a recording stopped here is selected instead of revealed in Finder. When a permission
is missing the sidebar offers "Open Setup…".

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

To record headlessly through the same code path as the menu:

    .build/debug/MeetingRecorder --record 5 --out /tmp/test.m4a   # --out optional, defaults to the recordings folder

It prints the RMS level of each source (`(silent)` below 0.001) and the saved path. Ctrl-C stops early and still
finalizes the file. Privacy prompts are attributed to the process that launched the binary (e.g. Terminal), so run
the app itself to test with its own grants.

## First-run setup

On first launch a Setup window opens (it does not depend on the menu-bar icon being visible). It walks through
Microphone, System audio (the other participants), optional Notifications, a 5-second test recording and a tip on
finding the menu-bar icon. The system audio step shows the live status with Allow and Open Settings buttons. Reopen it any time from the menu bar via "Setup & Help…", or
from the app window while a permission is missing.

## Meeting notifications

When another app keeps the default input device busy for more than 3 seconds (CoreAudio
`kAudioDevicePropertyDeviceIsRunningSomewhere`, no extra permission) and the app is not recording, a notification
"Meeting started — record it?" appears, naming Zoom, Teams, FaceTime, Slack, Notion or the frontmost browser when one is found.
Its Record button, or clicking it, starts recording. It is shown once per meeting and reset when the microphone is released,
so stopping your own recording mid-meeting does not bring it back. Turn it off with "Notify when a meeting starts" in the menu.

## Permissions

- Microphone (required): records you.
- System Audio Recording Only (needed to record the meeting): records what the Mac plays, i.e. the other participants.
  macOS asks the first time recording starts or when you press Allow System Audio in Setup. It is listed in System
  Settings > Privacy & Security > Screen & System Audio Recording, under "System Audio Recording Only". Screen Recording is
  not needed and no relaunch is required.

If system audio is denied the app still records the microphone and the menu shows "Microphone only — system audio
off". If the microphone is denied the menu shows a message and an "Open Privacy Settings" button. Build with the stable
signing identity (above) so the grants survive rebuilds.

There is no public API for the system audio permission status; Setup reads it through the TCC framework at runtime and
shows it as not yet known when that is unavailable. Without the grant macOS delivers silence rather than an error.
