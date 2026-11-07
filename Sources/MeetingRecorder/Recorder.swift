import AppKit
import os
import SwiftUI

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var permissionDenied = false
    @Published private var systemAudioNotice: String?
    @Published private(set) var microphoneWarning: String?
    /// The meeting being recorded or continued, until it is saved.
    @Published private(set) var meeting: URL?
    let live = LiveTranscription()

    private let microphone = MicrophoneCapture()
    private let system = SystemAudioCapture()
    private var mixer: AudioMixer?
    private var ticker: Task<Void, Never>?
    private var clock: ElapsedClock?
    private var lastLevels: [LevelMeter]?
    private var continuing = false
    private var triedVoiceProcessing = false

    private static let log = Logger(subsystem: "MeetingRecorder", category: "recording")

    var notice: String? {
        let notices = [microphoneWarning, systemAudioNotice].compactMap { $0 }
        return notices.isEmpty ? nil : notices.joined(separator: "\n")
    }

    var elapsedText: String {
        RecordingLogic.elapsedText(elapsed)
    }

    var statusText: String {
        RecordingLogic.statusText(paused: isPaused, elapsed: elapsed)
    }

    var isBusy: Bool { isRecording || meeting != nil }

    /// When the recording last had more than silence in it.
    var lastSound: Date? { mixer?.lastSound }

    nonisolated static var folder: URL { AppPaths.recordings }

    /// Records a new part of an existing meeting; Stop appends it to the meeting's file.
    func start(continuing meeting: URL) async {
        guard FileManager.default.fileExists(atPath: meeting.path) else {
            errorMessage = "\(meeting.lastPathComponent) no longer exists."
            return
        }
        await start(meeting: meeting, recordingTo: RecordingLogic.partURL(for: meeting, at: Date()))
    }

    func start(to output: URL? = nil) async {
        let url = output ?? RecordingLogic.availableURL(in: Self.folder, for: Date())
        await start(meeting: url, recordingTo: url)
    }

    private func start(meeting: URL, recordingTo url: URL) async {
        guard !isBusy else { return }
        errorMessage = nil
        systemAudioNotice = nil
        microphoneWarning = nil
        triedVoiceProcessing = false
        permissionDenied = false
        do {
            try await Permissions.ensureMicrophone()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let mixer = try AudioMixer(url: url, stems: true)
            self.mixer = mixer
            try microphone.start(into: mixer)
            startSystemAudio(into: mixer)
            live.start(meeting: meeting, mixer: mixer)
            beginTimer()
            continuing = url != meeting
            self.meeting = meeting
            isRecording = true
        } catch {
            _ = teardown()
            permissionDenied = error is PermissionError
            errorMessage = error.localizedDescription
        }
    }

    func togglePause() {
        guard isRecording, let mixer else { return }
        if isPaused {
            mixer.resume()
            live.resume()
            clock?.resume(at: Date())
        } else {
            mixer.pause()
            live.pause()
            clock?.pause(at: Date())
        }
        isPaused.toggle()
        tick()
    }

    private func startSystemAudio(into mixer: AudioMixer) {
        let active = RecordingLogic.attemptsSystemAudio(Permissions.systemAudio) && (try? system.start(into: mixer)) != nil
        systemAudioNotice = RecordingLogic.notice(systemAudioActive: active)
    }

    /// Finalizes the recording; a continued meeting gets the new part appended. Returns the meeting's file.
    @discardableResult
    func stop(reveal: Bool = true) async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        isPaused = false
        defer { meeting = nil }
        guard var url = teardown() else { return nil }
        if continuing, let meeting {
            do {
                try await AudioAppender.append(url, to: meeting)
                await AudioAppender.appendStems(of: url, to: meeting)
                url = meeting
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return url
    }

    func record(seconds: Double, to output: URL? = nil) async -> URL? {
        await record(RecordJob(seconds: seconds, output: output))
    }

    func record(_ job: RecordJob) async -> URL? {
        if let meeting = job.continuing { await start(continuing: meeting) } else { await start(to: job.output) }
        guard isRecording else { return nil }
        if let pause = job.pause, pause.after < job.seconds {
            await sleep(pause.after)
            togglePause()
            await sleep(pause.duration)
            togglePause()
            await sleep(job.seconds - pause.after)
        } else {
            await sleep(job.seconds)
        }
        return await stop(reveal: false)
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Levels of the last finished recording, per source.
    func level(of source: AudioSource) -> LevelMeter? {
        lastLevels?[source.rawValue]
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.folder)
    }

    /// Releases the mic engine and the system audio tap and aggregate device. Safe to call at any time, any number of times.
    func releaseAudioDevices() {
        microphone.stop()
        system.stop()
    }

    private func teardown() -> URL? {
        ticker?.cancel()
        ticker = nil
        microphoneWarning = nil
        clock = nil
        live.stop()
        releaseAudioDevices()
        defer { mixer = nil }
        guard let mixer else { return nil }
        let url = mixer.finish()
        lastLevels = AudioSource.allCases.map(mixer.level)
        return url
    }

    private func beginTimer() {
        elapsed = 0
        clock = ElapsedClock(started: Date())
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                tick()
            }
        }
    }

    private func tick() {
        if let clock { elapsed = clock.elapsed(at: Date()) }
        watchMicrophone()
    }

    private func watchMicrophone() {
        guard isRecording, !isPaused, let mixer else { return }
        let silent = mixer.silence(of: .microphone)
        switch MicrophoneSilence.action(silentFor: silent, triedVoiceProcessing: triedVoiceProcessing,
                                        warned: microphoneWarning != nil) {
        case .none:
            break
        case .useVoiceProcessing:
            triedVoiceProcessing = true
            Self.log.error("Microphone gave digital silence for \(Int(silent)) s; capturing it with voice processing")
            do {
                try microphone.start(into: mixer, voiceProcessing: true)
            } catch {
                Self.log.error("Voice processing failed: \(error.localizedDescription, privacy: .public)")
                try? microphone.start(into: mixer)
            }
        case .warn:
            Self.log.error("Microphone is digital silence for \(Int(silent)) s, input \(self.microphone.isRunning ? "running" : "stopped", privacy: .public)")
            microphoneWarning = MicrophoneSilence.warning
        case .clear:
            Self.log.notice("Microphone has sound again")
            microphoneWarning = nil
        }
    }
}
