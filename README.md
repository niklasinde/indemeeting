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

## Install (for friends)

Needs macOS 26 (Tahoe) or later. Download `MeetingRecorder-<version>.dmg` from the GitHub release and open it.

1. Drag Meeting Recorder onto Applications.
2. Open it. macOS says "Apple could not verify…" because the app is not notarized; click Done.
3. System Settings → Privacy & Security, scroll down, click **Open Anyway** next to Meeting Recorder and confirm.
   (Since macOS 15, right-click → Open no longer gets past this.)
4. In the Setup window, allow the Microphone and System Audio Recording, then record the test.
5. For summaries, turn on Apple Intelligence (System Settings → Apple Intelligence & Siri). The Siri language and the
   Mac's language must match.

The app lives in the menu bar (waveform icon, no Dock icon). Updates: drag the new version over the old one; the
permissions are kept.

## Build

    ./build.sh

Produces `MeetingRecorder.app`, signed with `MeetingRecorder.entitlements` and the hardened runtime, versioned with
`CFBundleShortVersionString` from `Info.plist` and `git rev-list --count HEAD` as the build number. Needs macOS 26+
(SpeechAnalyzer for transcription, Foundation Models for summaries). Builds with `swift build` (Command Line Tools 27 /
Swift 6.4 or Xcode); if SwiftPM fails, the script falls back to plain `swiftc`. `./build.sh --release <path>.app`
builds a universal (arm64 + x86_64) app at that path and fails instead of signing ad-hoc.

The first build also needs `cmake` (`brew install cmake`): `build.sh` runs `scripts/build-whisper.sh` when
`.deps/whisper.xcframework` is missing, which compiles whisper.cpp for KB-Whisper (see below). Run that script once
before a plain `swift build`; without it SwiftPM builds the app without KB-Whisper. SwiftPM also fetches the FluidAudio source
package (speaker recognition, pinned in `Package.resolved`) from GitHub on the first build; the `swiftc` fallback
builds without it.

### Release

    scripts/package.sh

Builds `--release` into `dist/`, verifies the signature (`codesign --verify --deep --strict`, and `spctl`, which
rejects it because it is not notarized), and creates `dist/MeetingRecorder-<version>.dmg` with the app, an
Applications link and `How to open.txt` (from `scripts/`). Upload it as a GitHub release asset. Bump
`CFBundleShortVersionString` in `Info.plist` for a new version.

Releases must be signed with the "MeetingRecorder Local" identity: it is what lets friends keep their permissions
across updates. Back it up with `scripts/export-signing-identity.sh [file.p12]` (default
`~/Documents/MeetingRecorder-Local-signing.p12`, password protected); the script prints how to restore it.

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
stems' transcripts and dropping echoes, speaker labels, speaker recognition (numbering, overlap assignment, cosine matching and its threshold, voice blending), auto-stop decisions, the recordings list, summary parsing, the meta sidecar, date groups, titles and search) with `swiftc` together with `Tests/MeetingRecorderTests/*.swift` and runs them (exit code is non-zero on failure). The database tests run against a temporary file: schema and
migrations (including adding the speaker column and the speakers and known voices tables to an existing database), naming speakers and remembering their voices, a database that cannot be opened in an
unwritable folder, reading and writing every field, full-text search, deletes and the sidecar import. `swift test` runs the same list through Swift Testing (or XCTest where that is the only framework). The iPhone tests cover request parsing and its limits, ranges, pairing urls and codes, one-use and expiry of a pairing, the auth decision and the failure limiter, the data types, and every endpoint against a scratch database (including stripped activity blocks and a stored file name that tries to leave the recordings folder). Tests that
need real permissions, hardware, speech models or Apple Intelligence are not covered; use the command-line mode below.

## Run

    open MeetingRecorder.app

A waveform icon appears in the menu bar (no Dock icon). Choose Start Recording; the icon turns red and the menu
shows elapsed time. Stop Recording reveals the file in Finder.

⌃⌥⌘R starts and stops recording from anywhere (a Carbon `RegisterEventHotKey` hot key, so no Accessibility permission
is needed); the menu shows it next to Start/Stop Recording. Stopping with the shortcut does not reveal the file in
Finder; the recording is transcribed and summarised as usual.

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
  recorded with stems name the speaker ("You", "Others", or "Speaker 1", "Speaker 2", … with speaker recognition)
  whenever it changes. Click a speaker to name them for this meeting (see Speaker recognition).

A player bar at the bottom has play/pause, the position and a scrubber. The toolbar has New Meeting (Pause/Resume and
Stop with the elapsed time while recording, like the menu; a recording stopped here is selected instead of revealed in
Finder) and a "…" menu with Continue Recording, Reveal in Finder, Transcribe & summarise (same processing as the menu),
Recognise speakers, Export as Markdown… and Delete, which moves the audio to the Trash and deletes the meeting's data after a confirmation.
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

- `meetings`: one row per audio file name, with the date, length, language (and whether it was detected), renamed title, summary title, notes,
  processing status (`none`, `summarised`, `unavailable`, `failed`) with its message (for example why there is no
  summary) and the transcription engine.
- `transcript_segments` (start time, sentence and speaker: `you`, `others`, `speaker-<n>` once speakers are
  recognised, or NULL for transcripts of the mix),
  `action_items` (owner, task, checked), `summary_topics` and
  `summary_points`, all deleted with their meeting.
- `speakers` (meeting, label, the name you gave it, voice embedding as little-endian float32 BLOB), deleted with their
  meeting, and `known_voices` (name, embedding, updated) for recognising voices across meetings.
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
an older summary and a missing summary, the Activity day and week views with a sample week, each in light and dark
appearance, the Settings tabs, plus the window with an unavailable database.

## Transcripts and summaries

Everything runs on the Mac; no audio or text leaves it. After Stop Recording the app transcribes the file and then
summarises it into the database: the transcript as timed sentences, and a short title, the action items (with an owner
only when someone is named) and two to five topics with bullets, in the meeting language.

When the meeting has both stems, each stem is transcribed on its own and the sentences are merged by start time, each
with its speaker. The other participants also reach the microphone through the speakers; a microphone sentence that
starts within 3 seconds of a system sentence with mostly the same words (Dice coefficient of the words at least 0.7)
is that echo and is dropped in favour of the system one. The summariser gets the lines with their speaker, told that
"You" is the person who recorded the meeting, so action items you take on are attributed to you. Recordings without
stems (all made before this) are transcribed from the mix without speakers, unless speaker recognition is on. The Markdown export writes the speaker
after each timestamp. Summaries imported from
earlier versions (summary, key points, decisions) still show in the app.

The menu shows "Transcribing…", "Summarising…" and then "Open summary", which opens the meeting in the app window; so
does the notification when it is ready. "Transcribe & summarise a recording…" processes any existing audio file. Errors are shown in the menu and as a
notification. The audio file is only read, never changed or deleted.

Settings > Meeting languages lists the languages to listen for (Svenska and English, both on by default; the menu bar
menu has the same choice under "Languages: …"). A recording is transcribed and summarised in the language spoken,
detected among those; with only one on, that language is always used and nothing is detected. Upgrading from a version
with a single default language keeps that language as the only one. The header shows the language with "(auto)" when
it was detected, and the window's "…" menu > Language transcribes and summarises a meeting again in another language
(which then sticks when it is transcribed again).

Detection takes up to 45 seconds of speech (silent half-second chunks are skipped; recordings longer than three minutes
give 25 seconds from the start and 25 from halfway), transcribes it with Apple's model for each candidate language, and
scores each transcript by the recogniser's mean word confidence times how much `NLLanguageRecognizer` (constrained to
the candidates) reads it as that language. Swedish dictation hears English as English words, so its transcript of an
English meeting does not read as Swedish; the English model hears Swedish as low-confidence English. Dictation leaves
the confidence out of some results, so a transcript with confidence on less than half its text counts as half sure.
The winner needs 55% of the combined score, else the first candidate in the Mac's preferred languages (System Settings >
General > Language & Region) is used, else Svenska. It adds about 2–3 seconds per meeting. KB-Whisper's language
detection is not used: fine-tuned on Swedish, it rates clear English as Swedish with probability 1.0. To see the scores:

    .build/debug/MeetingRecorder --detect-language /path/to/Meeting.m4a [--languages sv-SE,en-US]

A language is a `MeetingLanguage` case with its locale, names and headings; Settings, the menus and detection follow
`allCases`.

- Transcription uses `SpeechAnalyzer` (macOS 26). English uses `SpeechTranscriber`. Swedish is not supported by
  `SpeechTranscriber` (checked on macOS 26.6), so it uses `DictationTranscriber`, the on-device dictation model in the same
  API. Missing language models are downloaded through `AssetInventory` on first use. No permission prompt is needed.
- Summaries use Apple's on-device Foundation Models (`SystemLanguageModel`), which require Apple Intelligence. Its
  context is about 4,096 tokens, so long transcripts are summarised in parts and the part summaries are combined. If the
  model is unavailable (Apple Intelligence off, Mac not eligible, model still downloading, language unsupported) the
  transcript is still saved, the meeting and the menu say why, and how to enable it in System Settings >
  Apple Intelligence & Siri. Re-run "Transcribe & summarise a recording…" afterwards. "Still downloading" is also what the
  API reports when the Mac and Siri languages differ (e.g. English (Sweden) vs English (US)), so the app says both.

### Speaker recognition

With Settings > Speaker recognition > Download, the other participants are told apart on this Mac as Speaker 1,
Speaker 2, … . It uses [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.5 (Apache-2.0), a SwiftPM
source package pinned exactly in `Package.swift` and built into the executable like the rest of the app (its
`NemoTextProcessing` trait, a prebuilt binary for text-to-speech, is turned off), so there is still no
`Contents/Frameworks` and library validation stays on; it adds about 10 MB per architecture. Its offline pipeline (pyannote segmentation, WeSpeaker
embeddings, PLDA/VBx clustering, on Core ML) needs about 21 MB of models, downloaded only when you
click Download from Hugging Face (`FluidInference/speaker-diarization-coreml` at the revision FluidAudio pins) into
`Models/speaker-diarization/` next to the Whisper models. Remove deletes them. Until they are downloaded, nothing
changes: the transcript says You and Others.

After transcribing, the system stem is diarized (meetings without stems: the mix, so you cannot be separated from the
others there) and each segment not from the microphone gets the diarized speaker it overlaps most in time (a segment
lasts until the next one starts, at most 15 seconds; with no overlap the nearest speaker). Speakers are numbered in
order of first appearance; each one's voice is the mean of its segment embeddings. A failure there is logged and keeps
You / Others. "Recognise speakers" in the "…" menu (and `--recognise-speakers <audio>` headlessly) runs it again on
the stored transcript without transcribing.

Click a speaker label in the transcript to name them ("Speaker 2" → "Anna") for that meeting; an empty name gives the
label back. The names are used in the transcript, the Markdown export and the next summary (the summariser is told
which labels are you, numbered other participants or people's names). Naming a speaker also stores their voice in
`known_voices` (a name already there is blended with it: the mean of both unit vectors). In later meetings each
diarized speaker is matched against the known voices by cosine similarity, best first and each voice at most once;
at a cosine distance of at most 0.5 (FluidAudio's "same speaker, high confidence" range) the speaker is named
automatically, and you can still rename them. Settings > Known voices lists the names with Forget.

To download the models headlessly: `MeetingRecorder --download-speaker-model [--data-dir <folder>]`.

### KB-Whisper (Swedish)

Swedish can instead be transcribed with [KB-Whisper](https://huggingface.co/KBLab), the National Library of Sweden's
Whisper models, through [whisper.cpp](https://github.com/ggml-org/whisper.cpp) on the GPU (Metal). It punctuates and
is usually more accurate than Apple's dictation model. Settings > KB-Whisper lists the models with their size,
Download (with progress, cancellable) and Remove, and Settings > Transcription > "Transcribe Svenska with" picks Apple or
one of the downloaded models (stored in UserDefaults as `transcriptionEngine.sv-SE`). English uses Apple.

| Model  | File on Hugging Face  | Size    |
|--------|-----------------------|---------|
| Tiny   | `ggml-model.bin`      | 78 MB   |
| Base   | `ggml-model.bin`      | 148 MB  |
| Small  | `ggml-model.bin`      | 488 MB  |
| Medium | `ggml-model-q5_0.bin` | 539 MB  |
| Large  | `ggml-model-q5_0.bin` | 1.08 GB |

Models are downloaded from `https://huggingface.co/KBLab/kb-whisper-<size>/resolve/main/<file>`, checked against the
size and SHA-256 that Hugging Face lists, and moved into
`~/Library/Application Support/MeetingRecorder/Models/` (`<data-dir>/Models` with `--data-dir`) as
`kb-whisper-<size>[-q5_0].bin`. The meeting's `transcript_engine` is that name, e.g. `kb-whisper-medium-q5_0`. Stems are
transcribed one by one with the same model, so speakers and echo removal work as with Apple, and the menu shows the
progress. Bracketed sound labels such as `[MUSIK]` are dropped.

The models are one list, `WhisperModel.all` in `WhisperLogic.swift`: each entry has an id (the file and engine name),
display name, family, Hugging Face repo and file, size, SHA-256 and the languages it transcribes. Adding a model is one
entry there; Settings gets a section per family and offers a "Transcribe <language> with" picker for every language some
model supports (a multilingual model listing `.english` would make English selectable too).

whisper.cpp v1.9.4 (commit `927cfce`) is built from source by `scripts/build-whisper.sh` into `.deps/` (gitignored):
one universal static library with the Metal shaders embedded (`GGML_METAL_EMBED_LIBRARY`), wrapped in
`.deps/whisper.xcframework` with a `whisper` module map that also links Metal, Accelerate and libc++. SwiftPM uses it
as a local `binaryTarget` and links it into the executable, so the app has no `Contents/Frameworks` and library
validation stays on under the hardened runtime. It adds about 3.7 MB per architecture. Delete `.deps/` to rebuild it.
`test.sh` compiles `WhisperLogic.swift` only; `WhisperEngine.swift` is behind `#if canImport(whisper)`, so the `swiftc`
fallback builds without KB-Whisper. To try a model headlessly without changing
the saved choice, pass it as an argument default:

    .build/debug/MeetingRecorder --process Meeting.m4a --language sv-SE -transcriptionEngine.sv-SE kb-whisper-tiny

Settings… (Cmd-, in the menu bar menu, the app menu and the window's "…" menu) holds the meeting languages, each
language's speech model (installed, downloading with progress, not downloaded, or unavailable, with Download and Remove;
Remove releases the app's reservation so macOS may delete the model) and the Apple Intelligence status for summaries.

For a headless check, run the binary with a file:

    .build/debug/MeetingRecorder --process /path/to/Meeting.m4a --language sv-SE   # or en-US; leave out to detect

It prints the progress, the database it saved to, the language (and whether it was detected) and the summary title (or why there is none) and exits non-zero on
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
no extra permission). Once another app has held the microphone during the recording (the meeting that was
detected, or any call you started recording in) and then releases it, a notification "Meeting ended — stop recording?"
appears with Stop and Keep recording. Stop finishes the recording like the menu (without revealing it in Finder) and
transcribes it. Keep recording turns auto-stop off for the rest of this recording. If the notification is ignored,
the recording stops after 2 minutes of continuous silence on both the microphone and system audio (every chunk below
RMS 0.003), counted from when the meeting ended; a paused recording is never stopped, and resuming counts as sound. If
the other app takes the microphone again the notification is withdrawn. Turn it off with "Stop automatically when the
meeting ends" in the menu (on by default).

## Activity tracking

Off by default. Turned on in Setup (step 5) or Settings > Activity, the app keeps a local log of what you work in, for
time reports and for giving Claude your recent context. Nothing leaves the Mac; the only way out is the exports below.

Every 5 seconds while the Mac is awake, unlocked and you have touched the keyboard or mouse in the last 2 minutes
("Away after" in Settings), it samples:

- The frontmost app and the title of its focused window, through Accessibility (`AXUIElement`). Tracking does not start
  until this permission is granted; the step in Setup and Settings open System Settings > Privacy & Security >
  Accessibility.
- The address of the front tab in Safari, Chrome, Brave, Edge and Arc, asked through Apple Events (System Settings >
  Privacy & Security > Automation; macOS asks once per browser). Only host and path are kept, never the query string or
  fragment; incognito windows are skipped where the browser reports them; Firefox has no scripting dictionary, so only
  its title is captured.
- The git repository and branch: the folders under `~/git/*` and `~/git/*/*` that have a `.git` entry are matched by
  name, as a whole word, against the titles of terminals and editors (Terminal, iTerm2, Warp, Ghostty, JetBrains IDEs,
  VS Code, Cursor, Xcode, Claude, Sublime, Tower, …). The branch is read from `.git/HEAD`, following a worktree's
  `gitdir:` file; no process is spawned. Ticket keys like `QDLY-8296` are picked out of the branch, title or address.
- Claude Code sessions: with the Claude Code plugin (below), its hook events say exactly which sessions are working
  and which one you last typed into. Without it, or for sessions it has not seen, `~/.claude/projects/<folder>/<session>.jsonl`
  files written to in the last 2 minutes count as working. The
  session's working folder comes from the `cwd` of its first user message and its title from the custom title you gave
  it (`<session>/custom-title.json` or a `custom-title` line), else the first line you typed. These form a parallel
  lane: a block can have a Claude session running while you are in another app. The first 120 characters of the prompt
  you last sent are kept only with "Store last prompt" (Settings > Activity > Capture, off by default); while it is off
  no prompt is stored, shown, sent to Apple Intelligence or included in the context summary and MCP tools. Turning it
  off offers to delete stored prompts, and "Clear stored prompts" removes them any time.
- Optionally ("Text you're writing", off by default) up to 300 characters around the insertion point of the focused
  text field or area, kept once the text has not changed for 5 seconds. Secure text fields are never read and nothing
  is read while secure keyboard entry is on (a password prompt) or in an excluded app. No keystrokes are counted or
  stored.

Consecutive samples with the same app, title, address, repository, branch, ticket and Claude sessions collapse into one
block; a lock, sleep, or idle period becomes an "Away" block. Apps on the exclusion list (1Password, Keychain Access and
Passwords by default; editable in Settings) keep only their name and time. Blocks older than the retention setting
(90 days by default) are deleted once a day. "Pause activity tracking" in the menu bar stops sampling; the menu shows
what is being tracked.

Projects (name and colour) and rules map blocks to projects automatically: a rule matches a repository name, a website
(host or any subdomain of it), an app, or a ticket prefix such as `QDLY`; the first matching rule wins. Clicking a block
in the Activity view sets its project by hand (which beats every rule) and offers "Always map … to <project>", which
adds the rule.

With "Categorise with Apple Intelligence" on (default) and Apple Intelligence available, finished blocks are labelled
on this Mac by `SystemLanguageModel(useCase: .contentTagging)` with a category (coding, code review, meeting, email,
chat, writing/docs, planning/tickets, research/browsing, design, admin, entertainment, other), a description of at most
eight words and a project guess from your own projects. It runs in the background shortly after blocks close, in
batches, and caches the answer per app, normalised title and address, so repeats cost nothing. The guess is shown with
a small sparkle and only applies when no rule or manual choice does; the block popover accepts it with one click.

The Activity entry at the top of the sidebar opens the day view: active time, totals per project and per category, the
time per app, and the timeline of blocks (app icon, title, chips for address, repository · branch, ticket, category and
Claude session, the written excerpt, and the project). Week shows hours per project and per day, the per-day totals
and hours per category: the time report. Export CSV… (`date,project,hours,details`) and Export Markdown… (per day and
project, with the main repositories, tickets and websites) save the week through a save panel; both are also in the
"…" menu with Copy Context, which puts a Markdown summary of the shown day or week on the pasteboard: active time,
projects, apps, repositories with branches, tickets, websites, Claude sessions, window titles, categories, what you
wrote and the meetings in the window. The same summary prints headlessly:

    MeetingRecorder.app/Contents/MacOS/MeetingRecorder --context 4     # the last 4 hours (8 without a number)

Debug builds also take `--simulate-activity <samples.json>` (an array of `{"offset", "app", "bundle", "title", "url",
"repo", "branch", "claude": [...], "idle"}`), which feeds the samples through the tracker into the data directory's
database and prints the resulting blocks, so the pipeline can be checked without Accessibility access.

The data lives in the meeting database: `activity_blocks` (start, end, app, title, address, repository, branch,
ticket, Claude sessions, idle, manual project, typed excerpt, category, AI description and AI project guess),
`projects`, `project_rules` and `activity_ai_cache`. Deleting a project clears the blocks that pointed at it.

## Chat

A chat with Apple's on-device model (`SystemLanguageModel`), grounded in your own meetings and activity. Nothing leaves
the Mac. Open it from the menu-bar menu, the **Chat** row in the main window's sidebar, or **⌘⇧A**.

**Scoped chats.** A chat is about one thing, or about everything:

- **Ask** on a meeting (next to Continue Recording) starts a chat about the meeting, or about its notes while the Notes
  tab is open; the arrow lists the chats already held about it and the button shows how many. **Ask About This Meeting**
  is also in the more menu.
- **Ask About This** on an activity block (right-click, or in the project popover) and **Ask** in the Activity header for
  the day or week.
- The chip in the chat header names the subject; the × on it makes the chat general. Without a subject the chat may look
  at all meetings and activity.

**How answers are grounded.** The context window is small, so the model gets a short overview of the subject (title, time,
speakers, action items, summary, notes; trimmed to a share of `SystemLanguageModel.contextSize`) and looks up the rest with
tools. The general chat uses the MCP server's tools (`search_meetings`, `get_meeting`, `recent_meetings`, `activity_context`,
`time_report`) plus `meetings_on`, `open_action_items` and `activity_on`. A meeting chat has `search_in_meeting` (transcript
lines with speaker and time), `read_transcript` (a time range), `get_notes` and `scan_transcript`, which reads the whole
transcript part by part in separate sessions and returns what is relevant, so broad questions (decisions, action items,
open questions) do not depend on one call seeing everything. An activity chat has `block_details` and `blocks_in_range`.
Every result is cut to about 1,500 tokens. Each lookup shows in the transcript as a note ("Searched meetings for
“release”") that expands to what it returned; meetings it found are links, and in a meeting chat the times in an answer
open the recording at that moment (the transcript scrolls there and the player seeks; it does not start playing).

When the context window overflows, the question is asked again in a fresh session seeded with a recap of the latest
turns, and the transcript says "Started a fresh context". The same recap seeds a stored chat when it is reopened. The
model answers in the language of the question. If Apple Intelligence is unavailable the chat shows the same notice and
**Open Settings** button as summaries.

**Stored chats.** Chats, their messages and the notes of what was looked up are in `meetings.sqlite` (`chats`,
`chat_messages`); the text that was read to answer is not stored. Chats about a meeting are deleted with it. Settings >
Meetings > Chat has **Delete All Chats**. Chat titles come from the model, or from the first 40 characters of the question.

**Command line.** `MeetingRecorder --chat "<question>" [--meeting <id>] [--day <YYYY-MM-DD>] [--data-dir <folder>]` prints the
lookups and the streamed answer and exits, reading the database without writing, for example against a copy of the data
folder:

```sh
MeetingRecorder --data-dir /tmp/copy --meeting 7 --chat "Vilka beslut fattades?"
```

## Claude API chat

A chat that calls the Anthropic Messages API directly with your own API key. It is separate from the on-device chat and from
Claude Code. Open it from the **Claude API** row in the main window's sidebar.

- **Key.** Settings > Claude API has a key field. The key must start with `sk-ant-` and contain no spaces. It is stored in the
  macOS Keychain (service `com.niklasinde.MeetingRecorder.anthropic`, account `api-key`, available after first unlock on this
  device only). Only a masked form (`sk-ant-…abcd`) is ever shown. Remove deletes it.
- **Model.** Settings > Claude API picks the model. The default is Claude Sonnet 5.5. The IDs, from the Models table of the
  Anthropic docs (`claude-api` skill reference, cached 2026-10-06): `claude-sonnet-5-5`, `claude-opus-5-5`, `claude-haiku-5-5`.
- **Chat.** Replies stream in as Markdown. Return sends, Shift+Return starts a new line, the stop button ends a reply and keeps
  what arrived. Each answer shows its input and output tokens. Requests use `max_tokens` 4096 and a short system prompt.
- **Include the current PR.** When a pull request is selected in GitHub, the chip adds its title, URL, repository, checks
  summary and cached description (capped at 4,000 characters) to that message as data. No file contents and no secrets.
- **Stored chats.** Chats and messages are in `meetings.sqlite` (`api_chats`, `api_messages`), apart from the Claude Code and
  on-device chats. Delete a chat from its right-click menu, or **Delete All Claude API Chats** in Settings. The key is never written to the
  database, a log or an error message.
- **Limits.** This stage has no tools: the request never contains a `tools` field, and the chat cannot read files, run commands
  or reach the MCP server or the iPhone API. Nothing is sent anywhere except `api.anthropic.com`.
- **Errors.** No key, invalid key (401), rate limit (429, with the retry-after when given), overloaded (529), no credit
  (billing), network, and an incomplete reply each show a plain message.

To check the client without the real API, `MeetingRecorder --claude-api-check http://127.0.0.1:<port>/v1/messages` runs it with
a fake key against a loopback stub. It refuses any other host.

## GitHub

Off by default. Settings > Activity > GitHub turns on a **GitHub** row in the main window's sidebar: your pull requests
as a list on the left and the selected pull request on the right, read through the GitHub CLI (`gh`) that is already signed in on this Mac. The app never handles a
token, password or API key; if `gh` is missing the page shows `brew install gh`, and if it is not signed in it shows
`gh auth login`, each with a Copy button (the app never runs the interactive login).

This is, together with the optional iPhone access (below), the app's only network use besides model downloads, the Claude
Code plugin install and the Jira links you click: with the switch on, `gh api graphql` runs a search per tab (at most 50 open pull requests each, with their review threads, latest reviews and last comment: about 12
GraphQL points per search, roughly 55 per refresh against the 5000 an hour GitHub allows, so avoid the 1 minute interval; plus the
latest 30 closed or merged ones you created) and `gh auth status` checks the sign-in. Nothing is uploaded; only the
search terms (`author:@me`, `review-requested:@me`, `assignee:@me`, `mentions:@me`) go to GitHub.

- **Tabs:** Created, Review requested, Assigned and Mentioned, with a state filter (Open by default, Merged, Closed,
  All), a repository menu and a search field; rows are sorted by last update. The header counts the rows ("47 created").
- **Sort and quick filters:** the sort menu (right of the filters) has Updated (default), Needs attention, Most discussed,
  Unresolved first and Failing checks first. Pills under the filters narrow the list: Has unresolved comments, New
  feedback, Changes requested, Failing checks, Waiting on me, and Hide bot-only activity. They combine.
- **Needs attention** adds one weight per thing on a pull request, in the order of how much it asks of you: a review waiting
  on you 50, new feedback from people 40, changes requested 30, failing checks 20, unresolved threads 10, plus the number of
  new comments and unresolved threads (each at most 9) to tell equals apart; the last update decides the rest.
- **Rows:** `repo #number` with the status mark at the right, the title (two lines at most), and chips for the Jira ticket (when the title starts with a key; it links
  to Jira once the site is known from your browsing), Draft, the review decision, comments, `+additions -deletions` and
  the time since the last update at the right. Open pull requests also show Waiting on you, "3 unresolved" (the first 20 review threads
  are looked at, so "20+" is a lower bound), "2 new comments", "2 from bots" and who spoke last (initials, or a bot mark).
  *New comments* are comments and reviews by other people after your last commit, review or reply on your own pull
  requests, or after your review on someone else's; bots (Copilot, CodeRabbit, Snyk, dependabot, github-actions) are counted
  apart and never count as new feedback. Waiting on you is a review asked of you, or the author pushing or answering after
  your review. Bot-only means a bot's pull request or last word with nothing for a person to answer. The mark on the right is a green check (checks passed), red cross (failed), amber dot
  (running), grey circle (no checks), purple merge icon (merged) or grey sign (closed).
- **Layout:** the list (tabs, filters, sort, quick filters and rows) is on the left, 360 to 560 points wide (420 by default; a stored width outside that goes back to the default);
  drag the divider to resize it, the width is remembered. Below 781 points the list and the page take turns, with a back button.
  The pull request page is on the right, or "Select a pull request" while nothing is selected. In a wide window the page is centred in its column, at most 1000 points wide, with its text at most
  760 points wide so lines stay near 100 characters; the file, check and commit lists use the whole column. From 2200 points
  the rows add a line with the author, the update time and the changes. When the area right of the sidebar is narrower than 780 points (a window narrower than about
  1000) the two take turns instead: a click shows the page full width with a "Pull requests" back button.
- **Selecting:** a click selects and shows the page at once, from the cache. Up and Down (also with Command) move through the
  filtered and sorted list and keep the row in view, Return moves to the page (Escape back to the list), double-click or
  Command-O opens it in the browser. The selection survives a change of tab, filter, sort or refresh while the pull request is
  still listed, otherwise it is cleared, and the last one is selected again at the next start. Right-click: Show Details, Open
  in Browser, Copy Link, Copy Title, Open Repository, and Ask About This Pull Request, which opens a general chat with the
  title and link in the box.
- **Fast browsing:** the cached page is read synchronously when you select (a few milliseconds), the fetch starts 0.3 seconds
  after the selection settles so holding an arrow key does not query once per row, and the page of the row above and the
  row below is fetched in the background (at most two at a time, only when the cached one is older than 2 minutes). A
  page costs 1 GraphQL point, so walking through 10 pull requests costs about 10 to 20 of the 5000 an hour.
- **Pull request page:** the list keeps its tab, filter, search and scroll position. The page shows the
  state (Open, Draft, Merged, Closed), the Jira ticket from the title or branch (linked once the site is known), the
  conflict state, the review decision, labels, the base and head branch, the size, reviewers (requested people and teams
  plus each person's latest review, as initials circles), assignees, the description (Markdown: headings, lists, task
  lists, fenced code, links; tables as aligned plain text; images as "Image: ..." links that open in the browser, since
  they need your GitHub sign-in; long descriptions collapse), the checks of the head commit (failed first, with duration;
  a click opens the run; refreshed every 30 seconds while one is running), the commits (first 100, per-commit check mark)
  and the files changed (first 100, with a filter; a click opens the pull request's Files tab). It is read only, from one
  GraphQL query through `gh`, cached per pull request in `github_pr_details` so it reopens instantly.
- **Comments:** a section under Files changed (and a Comments button in the page toolbar) with the review threads grouped by file, each with
  the code it was made on, its comments in order (Markdown, suggestions as before and after, bots badged, long bot comments and
  `<details>` collapsed), resolved threads folded into one line and outdated ones dimmed, then the conversation of comments and review
  summaries. Filters: Unresolved, All, Mine, New (comments by others after your last activity, marked with a dot), Hide bots and a search.
  Clicking "N unresolved" or "N new comments" on a list row opens the page on them. Read only. A second GraphQL query (about 1 point
  a page of 50 threads) fetches it when the page opens; Load more follows the cursors. Cached per pull request in `github_pr_comments`.
- **Refresh:** every 5 minutes by default (1 to 60 in Settings) and with the refresh button. A failed fetch keeps the last
  data and shows why: rate limit, offline, or an organisation that needs SAML single sign-on authorised for `gh`.
- **Menu bar:** when there is data, a line such as "GitHub: 3 need your review · 2 failing checks · 2 with new feedback" opens the page.
- **Timeline:** the tooltip of a pull request address in the Activity timeline shows its title from the cache.
- **Cache:** the last fetch, with the raw discussion data, is stored in `github_prs` in the meeting database, so the page opens instantly and works
  offline. Delete all activity leaves it; Settings > Activity > GitHub > Clear GitHub cache removes it.

- **Open in Claude:** a split button on the pull request page (and its row menu). The main button repeats the preset you used last
  (Review, Explain, Address review comments, Investigate failing checks, Draft a summary); the menu lists the others and where
  to open: Terminal, iTerm2, Ghostty, Warp or the Claude app (Settings > Activity > GitHub). Each prompt carries the address,
  `owner/repo #n`, title, branches and ticket, and says to work read-only. In a terminal the app finds the checkout under `~/git`
  by its `origin` remote and runs `claude "<prompt>"` there through a `.command` script that reads the prompt from a 0600 file in
  `~/Library/Application Support/MeetingRecorder/claude-prompts/` (removed when read, and after a day at the latest), so no title
  is ever quoted into a shell and no Automation permission is needed. Without a checkout it starts in your home folder and says
  `gh repo clone owner/repo`. The Claude app opens `claude://code/new?q=...&folder=...`; a prompt too long for a link is copied
  instead. Meetings have the same under Ask > Open in Claude, which points Claude at the MeetingRecorder MCP tools.
- **In this app (embedded terminal):** the first group of the Open in Claude menu is Open in; "In this app" runs the interactive
  `claude "<prompt>"` in a terminal pane on the pull request page instead of another app. Nothing starts on selection, only on the click.
  The pane sits to the right of the page in a window at least 1500 pt wide and below it otherwise, 480 to 720 points wide to the right (the width is remembered), with a draggable edge, and a toolbar
  with Restart, Stop (Ctrl-C, then SIGHUP and SIGKILL for what stays), Copy all output, Hide and Close. There is one session per pull request:
  other sessions keep running while you browse (a green dot on the row, a count in the list header, a Terminal button with a dot on the
  page) and selecting the pull request again shows the same terminal with its scrollback. The session runs through `/bin/zsh -l -c`
  in the checkout (else your home folder), so PATH and sign-in are those of your Terminal; the prompt is read from a 0600 file that
  removes itself, never quoted into the command. `TERM=xterm-256color`, `COLORTERM=truecolor` and a UTF-8 `LANG` from your locale are set.
  Without the CLI the pane shows the install command; without a checkout, the clone command. Interactive Claude can change files, so
  the pane says so once (Don't show again). Light and dark palettes follow the appearance; SF Mono, 12 pt by default.
  Keys: the terminal gets the keyboard when clicked or with Cmd-Opt-T, which also hands it back to the list; while it has the keyboard
  the arrow keys go to the program, not the list. Cmd-C and Cmd-V copy and paste, Cmd-K clears, Cmd-plus, Cmd-minus and Cmd-0 change the
  font size. Closing, restarting and quitting end Claude and everything it started (SIGHUP to the process group, SIGKILL after a moment).
  Quitting with Claude running asks "Claude is still running in N terminals". Settings > Activity > GitHub: Open Claude in (default
  destination), Embedded terminal font size, Confirm before quitting while running. The terminal is
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.99.0 (MIT), linked statically from source: no framework is embedded and the
  signing, entitlements and hardened runtime are unchanged. 1.99.0 because the older releases compile a Metal shader and so need the
  Metal toolchain plus a resource bundle. The `swiftc` fallback build has no terminal; "In this app" is then not offered. Meetings'
  Open in Claude uses Terminal when the choice is In this app.
- **Ask Claude:** off until Settings > Activity > GitHub > Allow Claude reviews is on (a one-time confirmation). It runs your
  `claude -p` here, one pull request at a time, in the checkout (else your home folder), streaming into a Claude review panel on
  the page. It is read-only: `--permission-mode dontAsk` with only Read, Grep, Glob, `gh pr view|diff|checks|list`,
  `gh run view|list` and `git log|diff|show|grep|blame` allowed, writes and `gh api` denied, no settings or hooks read, a 10 minute
  and 5 dollar limit, and Cancel stops it and what it started. The last answer per pull request is kept in `github_pr_reviews`
  with the commit it read, marked Outdated when new commits arrive, and rows with a fresh one show "Reviewed by Claude". Copy as
  review comment puts `[AI]` on the first line; Ask Claude cannot post to GitHub. A run costs roughly one dollar of usage.

### Resuming Claude sessions

Each interactive Claude session started from a pull request is remembered per pull request: the session id, its folder and
its title, in the `github_pr_sessions` table of the meetings database. The id is taken from the transcript Claude Code writes
under `~/.claude/projects/<folder>/<id>.jsonl`: after a terminal starts, the app looks for the newest transcript created since
then whose text names the pull request's address, and stores its name. Nothing is read from the terminal's output.

- **Resume previous session** (the default when a session is saved, in Open in Claude and in the Resume session button) runs
  `claude --resume <id>` in the folder the session started in. The preset prompt is not sent again. A line says
  "Resumed previous session" and "Start new session instead" starts over with the usual prompt.
- If the transcript is gone, the saved row is removed and a new session starts with a note saying so. A session that is
  already running for the pull request is shown again, not duplicated.
- The "Resumable" chip on the pull request page shows that a session is saved. Nothing starts by itself when the app opens.
- Settings > Activity > GitHub: "Remember Claude sessions per PR" (on by default; only ids and paths are stored) and
  "Forget all". Open in Claude > Forget session removes one pull request's saved session.
- **Headless reviews are not resumable.** "Ask Claude" runs `claude -p` with `--no-session-persistence`, so Claude writes no
  transcript for them. Their session id is stored, for reference, but Resume only offers interactive sessions.
- The Claude app destination cannot resume a session and always starts a new one.

### Actions

The only way this app writes to GitHub, through the signed-in `gh` (no token is handled). **Off by default**: Settings > Activity > GitHub >
Allow actions on GitHub (approve, merge, close). While off, the row menu shows no actions and the page shows Review, Merge and Close disabled.

- **What:** Approve (optional comment), Request changes and Comment (comment required), Merge, Close (optional comment, optional Also
  delete the branch, off by default) and Reopen. On the page: Review menu, Merge and Close. In the list: the row menu (Approve, Merge
  for an open pull request, Close). Command-click
  or shift-click marks several rows; Close N pull requests runs them one at a time with a pause, shows each result, keeps a failure and
  goes on, and stops at errors that would repeat (signed out, rate limit, offline).
- **Every action asks first.** A sheet shows the pull request, title, author, state, checks and review decision, the comment and the
  exact `gh` command (copyable). The state is fetched again when the sheet opens. Approve needs a click on its button (Return
  cancels); Close may use Return. Your own pull request cannot be approved, closed or merged ones cannot be approved or closed, drafts
  and failing checks warn. The first use shows a one-time explanation.
- **Merge:** `gh pr merge <n> --repo <owner/repo> --squash|--merge|--rebase [--delete-branch] [--body <text>]`. The method defaults to
  the first one the repository allows (squash, merge commit, rebase); methods it does not allow are not offered. The sheet shows the base
  branch, conflicts, checks and the review requirement, and refuses drafts, merged or closed pull requests, conflicts, an unknown
  mergeability and a method the repository does not allow. Failing checks and unsatisfied protection warn and stay allowed. Merge needs
  a click (Return cancels). Guardrails: never `--auto` (no auto-merge), never `--admin` (no bypass of branch protection), no keyboard
  shortcut, no drag-and-drop and no bulk merge. A merge cannot be undone on GitHub; the result says so, and it can only be reverted
  with a new pull request.
- **Undo:** a close can be reopened from the result banner for 30 seconds and from Settings > Recent actions; that reopen is the undo of
  something you just confirmed and does not ask again. An approval cannot be undone here; dismiss it on GitHub.
- **Log:** every action, successful or not, is written to `github_actions` (time, action, repo, number, title, command, result, error),
  shown as Recent actions (last 50) and clearable. Errors from `gh` are classified (signed out, missing scope, SAML, branch protection,
  own pull request, already closed, offline, rate limit) and never retried.
- **Nothing else can write:** not Claude (headless runs deny `gh pr review|close|reopen|merge|comment|edit|create|ready`, `gh api`; the
  embedded terminal and Open in Claude only start Claude), not the chat tools, the MCP server, the phone API, command-line flags or
  deep links (there is no URL scheme). The tests read the sources and fail if any of them can reach the code that runs the commands.

`MeetingRecorder --github-prs` runs the same searches once and prints the counts, the rows that need attention most with their
signals, and the GraphQL points used (read only). `--github-pr-threads owner/repo#n` is a probe that prints what the review
threads of one pull request look like (no UI uses it).
`--github-pr owner/repo#number` fetches one pull request page and prints the parsed summary. `--github-pr-comments owner/repo#n` fetches
all pages of its comments and prints the parsed structure and the cost.
In a debug build `--render-github <folder>` saves previews of the page, its error states and its settings.

## iPhone access

Off by default. Settings > iPhone lets an iPhone app read this Mac's meetings, activity and GitHub pull requests, and ask the
chat questions, **over your local network**. There is no server in between and nothing is uploaded: the phone connects
directly to this Mac, which has to be awake and on the same network. The iPhone app is a viewer; nothing it does changes
your meetings.

- **Turn it on** with Allow iPhone access. The status line says "Listening on `<name>.local:<port>` · N devices paired". The
  port is 47821 unless you change it. The app advertises itself with Bonjour as `_meetingrecorder._tcp`.
- **Pair a device** shows a QR code and the same information as a code to type. It is valid for five minutes and one device;
  the phone swaps it for a key of its own. Paired devices are listed with when they last connected, and **Revoke** removes
  one at once.
- **Security.** The connection is TLS 1.2 with a pre-shared key and ECDHE, so a device that does not hold a key cannot get
  past the handshake and there is no certificate to trust. Each device has its own random 32-byte key, kept in this Mac's
  Keychain (service `com.niklasinde.MeetingRecorder.pairing`); the device records (name, when paired, when last seen) are in
  the `paired_devices` table. Repeated failed attempts from one address are blocked for a while. The log (`os_log`,
  category `phone`) only notes that someone connected or failed to authenticate, never what was asked.
- **What it shares.** Meetings (summaries, notes, transcripts, audio), activity with the same privacy rules as the app
  (blocked and other-app activity stays stripped, Claude prompts only while Store last prompt is on), the cached GitHub
  pull requests (nothing while GitHub is off) and answers from the on-device chat, which are not stored on the Mac.
- **Firewall.** The first time the app listens, macOS may ask whether Meeting Recorder may accept incoming connections;
  allow it, or the phone cannot reach the Mac. The app also declares a local network usage description.

The contract for the phone app, with every endpoint, the pairing flow and the error codes, is in
[docs/phone-api.md](docs/phone-api.md); the data types are in `Sources/Shared/PhoneAPI.swift`, which an iOS target can
compile as it is.

**Testing without a phone.** `MeetingRecorder --serve [--port N] --data-dir <folder>` runs only the server against a data
folder (use a copy; it refuses to run without `--data-dir`) and reads commands from stdin: `pair [seconds]` prints a pairing
url and code, `devices`, `revoke <id>`, `quit`. The keys go to `phone-secrets.json` in the folder, or to a test service in the
Keychain with `--keychain`. In a debug build `--phone-client <host:port> <url> <path> [--method M] [--body JSON|@file]
[--header "K: V"] [--out file]` does the handshake the phone does and prints the response, and `/v1/pair` completes a
pairing and prints the device url to use afterwards. `--render-phone <folder>` saves previews of the settings and the pairing
sheet.

### iPhone app

`ios/` holds "Meeting Recorder" for iPhone (iOS 26, SwiftUI): a read-only viewer for this Mac's meetings (summary, notes,
transcript with tap-to-play, action items, audio with scrubbing and speed, Markdown sharing), activity (day and week),
GitHub pull requests and chat, with the last answers cached so it opens instantly and still shows data when the Mac is
asleep. Open `ios/MeetingRecorderPhone.xcodeproj` in Xcode, pick your Team under Signing, and run it on your phone. Setup,
pairing and troubleshooting are in [ios/README.md](ios/README.md).

## Claude Code plugin

`plugin/` is a Claude Code plugin, published from this repository as the `indemeeting` marketplace. Install it from
Settings > Activity > Claude Code plugin (Install Plugin runs the `claude` CLI; Install from Folder uses a local
checkout while developing), or in Claude Code:

    /plugin marketplace add niklasinde/indemeeting
    /plugin install meetingrecorder@indemeeting

Open MeetingRecorder once first: on launch it links itself as `~/Library/Application Support/MeetingRecorder/bin/meetingrecorder`,
which the plugin's MCP server starts. New Claude Code sessions pick the plugin up. Remove it with Remove Plugin or
`/plugin uninstall meetingrecorder@indemeeting`.

What it adds:

- Hooks on SessionStart, UserPromptSubmit, PostToolUse (at most once per 30 seconds per session), Notification,
  SubagentStop, Stop and SessionEnd run `plugin/hooks/record-event.sh`, a POSIX `sh` + `awk` script (no Node or Python)
  that appends one line to `claude-events.jsonl` in the data folder (`MEETING_RECORDER_DATA_DIR` is respected) and
  always exits 0:

      {"time":1792399066,"event":"UserPromptSubmit","session_id":"…","cwd":"/Users/me/git/repo","transcript_path":"…/….jsonl","prompt_bytes":27}

  PostToolUse lines add `"tool"`, SessionStart `"source"`, SessionEnd `"reason"` and Notification `"notification"`. The
  app reads new lines every 5 seconds and moves the file to `claude-events.jsonl.1` past 256 KB. A prompt makes a session
  working until Stop, SessionEnd, a Notification (waiting for you) or 10 minutes without events; the session you
  prompted last while Claude is frontmost is the one you are in. The context summary shows per session the time it was
  working or in front of you and, of that, the time "with you".
- An MCP server (`meetingrecorder --mcp`, JSON-RPC 2.0 over stdio, protocol 2025-11-25 back to 2024-11-05) with
  read-only tools: `activity_context(hours)` (the `--context` summary), `time_report(week_start?)` (the week export
  per day, project, branch and ticket), `search_meetings(query, limit?)` (full-text, with snippets), `get_meeting(id)`
  (summary, action items, notes and the transcript with speakers) and `recent_meetings(limit?)`. It opens the database
  read-only, so it never conflicts with the running app.
  The GitHub tools read the pull request cache the GitHub view keeps and never call `gh`: `github_prs(kind?, state?,
  limit?)` (created, review_requested, assigned or mentioned; open, merged, closed or all), `github_pr(pr)` (a URL or
  `owner/repo#number`: branches, mergeable state, reviewers, checks, ticket keys and the description, from the cached
  detail) and `github_needs_attention(limit?)` (what waits on you or has new comments from people). They answer with a
  message when the cache is empty or GitHub is off in Settings.
- `/meeting-context [hours]` and `/time-report [week]`, and a skill telling Claude when to use the tools ("what did
  we decide in the standup", "what was I working on").

Privacy: everything stays on the Mac. Prompt text, tool input and tool output are never written; only the prompt's
length is. `MEETING_RECORDER_HOOK_PROMPTS=1` in Claude Code's environment keeps the first 500 characters of each
prompt (otherwise the app reads your last prompt from the transcript, as without the plugin). Either way the app
stores a prompt in the activity database only while "Store last prompt" is on.

## Permissions

- Microphone (required): records you.
- System Audio Recording Only (needed to record the meeting): records what the Mac plays, i.e. the other participants.
  macOS asks the first time recording starts or when you press Allow System Audio in Setup. It is listed in System
  Settings > Privacy & Security > Screen & System Audio Recording, under "System Audio Recording Only". Screen Recording is
  not needed and no relaunch is required.
- Accessibility (only for activity tracking): reads window titles and, when turned on, the text around the cursor.
  Turning tracking on shows the system prompt; grant it under Privacy & Security > Accessibility.
- Automation (only for browser addresses in activity tracking): macOS asks the first time each browser is in front.
  The app has the `com.apple.security.automation.apple-events` entitlement for this.

If system audio is denied the app still records the microphone and the menu shows "Microphone only — system audio
off". If the microphone is denied the menu shows a message and an "Open Privacy Settings" button. Build with the stable
signing identity (above) so the grants survive rebuilds.

There is no public API for the system audio permission status; Setup reads it through the TCC framework at runtime and
shows it as not yet known when that is unavailable. Without the grant macOS delivers silence rather than an error.
