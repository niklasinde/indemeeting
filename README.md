# MeetingRecorder

Menu-bar app that records you (the microphone) and the meeting (system audio, i.e. the other participants, through a
Core Audio process tap) into one mono AAC file at `~/Movies/MeetingRecordings/Meeting-YYYY-MM-DD-HHmm.m4a`
(`-2`, `-3`, … when a minute already has one). All sources are converted to 48 kHz mono float, summed, and encoded.
Works independently of Notion or any other meeting tool.

Next to the mix, each source is also written on its own with the same AAC settings: `Meeting-…-HHmm.stem-mic.m4a`
(you) and `Meeting-…-HHmm.stem-system.m4a` (the others), padded with silence so both line up with the mix. They are
used to tell the speakers apart in the transcript, are not listed in the app, and are moved to the Trash with their
meeting.

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

`test.sh` compiles the mixer, the appender, the database layer and the pure recording, processing and library helpers (chunking, timestamps, markdown, file
names, paused time, part and combined files and their length and bit rate, stems and their appends, merging the
stems' transcripts and dropping echoes, speaker turns, auto-stop decisions, the recordings list, summary parsing, the meta sidecar, date groups, titles and search) with `swiftc` together with `Tests/MeetingRecorderTests/*.swift` and runs them (exit code is non-zero on failure). The database tests run against a temporary file: schema and
migrations (including adding the speaker column to an existing database), a database that cannot be opened in an
unwritable folder, reading and writing every field, full-text search, deletes and the sidecar import. `swift test` runs the same list through Swift Testing (or XCTest where that is the only framework). Tests that
need real permissions, hardware, speech models or Apple Intelligence are not covered; use the command-line mode below.

## Run

    open MeetingRecorder.app

A waveform icon appears in the menu bar (no Dock icon). Choose Start Recording; the icon turns red and the menu
shows elapsed time. Stop Recording reveals the file in Finder.

Pause Recording (menu or the window's toolbar) stops writing until Resume Recording: the menu, toolbar and sidebar show
"Paused 00:12:34", the timer stands still and the file simply continues where it left off, without the paused gap.
Quitting while paused saves the recording like Stop.

## App window

"Open Meeting Recorder" (Cmd-O) at the top of the menu, or opening the app again from Finder or Spotlight, shows the
main window (with a Dock icon while it is open). The sidebar lists the recordings in `~/Movies/MeetingRecordings`
grouped by Today, Yesterday, This week and Earlier. Each row shows the meeting title (a rename, else the title of the
summary, else "Meeting") and the time and length. The search field at the top searches titles, transcripts, summaries
and notes in the database (every word has to match as the start of a word, ignoring case and accents); the arrow keys
move through the list. In-progress `.recording.m4a` files are left out, and the list follows the folder as files
appear or are removed.

A selected meeting shows its title (click to rename), the date, time, length and language, and three tabs:

- Summary: the action items as checkboxes ("Åtgärdspunkter" for Swedish meetings), then one heading with bullets per
  topic. Without a summary it says why (for example that Apple Intelligence is off) and offers Summarise.
- Notes: your own notes, saved automatically shortly after you stop typing.
- Transcript: the transcript in paragraphs; clicking a paragraph's time plays the recording from there. Meetings
  recorded with stems name the speaker ("You" / "Others", "Du" / "Övriga" in Swedish) before each run of paragraphs
  by the same speaker.

A player bar at the bottom has play/pause, the position and a scrubber. The toolbar has New Meeting (Pause/Resume and
Stop with the elapsed time while recording, like the menu; a recording stopped here is selected instead of revealed in
Finder) and a "…" menu with Continue Recording, Reveal in Finder, Transcribe & summarise (same processing as the menu),
Export as Markdown… and Delete, which moves the audio to the Trash and deletes the meeting's data after a confirmation.
Export as Markdown… (also File > Export as Markdown…, Shift-Cmd-E) writes the summary, the action items with their
checked state, the notes and the transcript into one `.md` file you choose. When a permission is missing the sidebar offers
"Open Setup…".

Two ways to record from the window:

- New meeting ("+" next to the search field, Cmd-N, or New Meeting in the toolbar) records a new file. Its row appears
  at the top under Today right away with a live "Recording 00:00:12" and its page opens, so you can write notes while it
  records; the transcript and summary follow after Stop. While a recording runs the "+" shows that meeting instead.
- Continue Recording (next to a meeting's title, in the toolbar and in the "…" menu, when nothing is recording) picks a
  meeting back up. The new part is recorded to `Meeting-…-HHmm.part-<time>.m4a`; on Stop it is appended to the
  meeting's own file, so the meeting keeps its name, row, notes, title and checked action items, and it is then
  transcribed and summarised again as a whole. The append decodes the meeting plus the part and encodes them with the
  same AAC settings as a recording (48 kHz mono, 96 kbit/s) to `Meeting-…-HHmm.combined.m4a`, checks that its length is the old length plus the part's (within half a
  second, or 0.1% for long meetings) and only then replaces the meeting. If anything fails the meeting is left as it
  was, the part file is kept next to it and the error names it. Part and combined files are not listed. The part's
  stems are appended to the meeting's stems the same way; when the meeting has no stems (recorded before they
  existed) or a stem append fails, the stems are removed and the meeting is transcribed from its mix as before.

Edits never touch the recording. Renames, notes and checked action items are saved in the database. Transcribing again
keeps them; a checked item stays checked as long as the new summary has the same owner and task.

## Data

The audio stays in `~/Movies/MeetingRecordings` as `.m4a` files. Everything else is in one SQLite database,
`~/Library/Application Support/MeetingRecorder/meetings.sqlite` (WAL mode, foreign keys on, opened through the system
`SQLite3` library):

- `meetings`: one row per audio file name, with the date, length, language, renamed title, summary title, notes,
  processing status (`none`, `summarised`, `unavailable`, `failed`) with its message (for example why there is no
  summary) and the transcription engine.
- `transcript_segments` (start time, sentence and speaker: `you`, `others` or NULL for transcripts of the mix),
  `action_items` (owner, task, checked), `summary_topics` and
  `summary_points`, all deleted with their meeting.
- `meetings_fts`: an FTS5 index over the title, transcript, summary and notes, used by the sidebar search.
- `schema_version`: the migrations applied; new ones are appended to `MeetingStore.migrations` and run once, in order,
  on launch.

If the database cannot be opened (for example the folder is not writable), the app does not fall back to a temporary
database. The window shows a banner and the menu a "Meeting database unavailable" section, both with the database path,
the error and Reveal in Finder (the file, or the nearest folder that exists). Titles, notes and action item checkboxes
are disabled so nothing is typed that cannot be saved; recording keeps working and the audio is saved to disk as
usual, and transcribing fails with the database error. `--process` exits with the error before transcribing. Quit
and reopen the app once the database is fixed.

The list is the audio files on disk joined with their rows: a new `.m4a` gets a row, a row whose file is gone is
hidden (and kept). Earlier versions kept the data next to each recording in `<name>.transcript.md`, `<name>.summary.md`,
`<name>.meta.json` and `<name>.notes.md`. When a recording gets its row (on the first launch of this version for
existing ones) those files are read once and imported; they are never changed or used again, so after checking the
app you can delete them.

`--data-dir <folder>` (or `MEETING_RECORDER_DATA_DIR=<folder>`) makes the app use `<folder>/MeetingRecordings` and
`<folder>/meetings.sqlite` instead, for trying a copy of the library without touching the real one.

To check the window's layout without a screen, a debug build can render it offscreen with a Swedish sample meeting
(the sample data and the flag are only compiled into debug builds):

    swift build && .build/debug/MeetingRecorder --render-previews /tmp/previews

It writes the sample library to `/tmp/previews/library` as audio and old-style sidecar files, imports it into
`/tmp/previews/library.sqlite` and saves PNGs of the Summary, Notes and Transcript tabs (the transcript with speakers),
an older summary and a missing summary, each in light and dark appearance, plus the window with an unavailable
database.

## Transcripts and summaries

Everything runs on the Mac; no audio or text leaves it. After Stop Recording the app transcribes the file and then
summarises it into the database: the transcript as timed sentences, and a short title, the action items (with an owner
only when someone is named) and two to five topics with bullets, in the meeting language.

When the meeting has both stems, each stem is transcribed on its own and the sentences are merged by start time, each
with its speaker. The other participants also reach the microphone through the speakers; a microphone sentence that
starts within 3 seconds of a system sentence with mostly the same words (Dice coefficient of the words at least 0.7)
is that echo and is dropped in favour of the system one. The summariser gets the lines with their speaker, told that
"You" is the person who recorded the meeting, so action items you take on are attributed to you. Recordings without
stems (all made before this) are transcribed from the mix without speakers. The Markdown export writes the speaker
after each timestamp. Summaries imported from
earlier versions (summary, key points, decisions) still show in the app.

The menu shows "Transcribing…", "Summarising…" and then "Open summary", which opens the meeting in the app window; so
does the notification when it is ready. "Transcribe & summarise a recording…" processes any existing audio file. Errors are shown in the menu and as a
notification. The audio file is only read, never changed or deleted.

"Meeting language" (Svenska / English, default Svenska) picks the transcription language and the language of the
summary.

- Transcription uses `SpeechAnalyzer` (macOS 26). English uses `SpeechTranscriber`. Swedish is not supported by
  `SpeechTranscriber` (checked on macOS 26.6), so it uses `DictationTranscriber`, the on-device dictation model in the same
  API. Missing language models are downloaded through `AssetInventory` on first use. No permission prompt is needed.
- Summaries use Apple's on-device Foundation Models (`SystemLanguageModel`), which require Apple Intelligence. Its
  context is about 4,096 tokens, so long transcripts are summarised in parts and the part summaries are combined. If the
  model is unavailable (Apple Intelligence off, Mac not eligible, model still downloading, language unsupported) the
  transcript is still saved, the meeting and the menu say why, and how to enable it in System Settings >
  Apple Intelligence & Siri. Re-run "Transcribe & summarise a recording…" afterwards.

For a headless check, run the binary with a file:

    .build/debug/MeetingRecorder --process /path/to/Meeting.m4a --language sv-SE   # or en-US

It prints the progress, the database it saved to and the summary title (or why there is none) and exits non-zero on
failure, without starting the menu-bar app.

To record headlessly through the same code path as the menu:

    .build/debug/MeetingRecorder --record 5 --out /tmp/test.m4a   # --out optional, defaults to the recordings folder

It prints the RMS level of each source (`(silent)` below 0.001) and the saved path. Ctrl-C stops early and still
finalizes the file. `--pause-after A --resume-after B` pauses after A seconds for B seconds (default 1) and then
records the rest, so the file is still `--record` seconds long. `--continue /path/to/Meeting.m4a` records a part and
appends it to that meeting instead of writing a new file (`--out` is ignored):

    .build/debug/MeetingRecorder --record 4 --pause-after 2 --resume-after 1 --out /tmp/paused.m4a
    .build/debug/MeetingRecorder --continue /tmp/copy-of-Meeting.m4a --record 3 Privacy prompts are attributed to the process that launched the binary (e.g. Terminal), so run
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

While recording, the app also checks every second which processes take audio input (Core Audio process objects,
macOS 14.2+, no extra permission). Once another app has held the microphone during the recording (the meeting that was
detected, or any call you started recording in) and then releases it, a notification "Meeting ended — stop recording?"
appears with Stop and Keep recording. Stop finishes the recording like the menu (without revealing it in Finder) and
transcribes it. Keep recording turns auto-stop off for the rest of this recording. If the notification is ignored,
the recording stops after 2 minutes of continuous silence on both the microphone and system audio (every chunk below
RMS 0.003), counted from when the meeting ended; a paused recording is never stopped, and resuming counts as sound. If
the other app takes the microphone again the notification is withdrawn. Turn it off with "Stop automatically when the
meeting ends" in the menu (on by default).

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
