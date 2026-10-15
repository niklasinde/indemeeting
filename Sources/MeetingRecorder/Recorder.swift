import AppKit
import SwiftUI

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var permissionDenied = false
    @Published private(set) var notice: String?

    private let microphone = MicrophoneCapture()
    private let system = SystemAudioCapture()
    private var mixer: AudioMixer?
    private var timer: Timer?
    private var lastLevels: [LevelMeter]?

    var elapsedText: String {
        RecordingLogic.elapsedText(elapsed)
    }

    static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRecordings", isDirectory: true)
    }

    func start(to output: URL? = nil) async {
        guard !isRecording else { return }
        errorMessage = nil
        notice = nil
        permissionDenied = false
        do {
            try await Permissions.ensureMicrophone()
            let url = output ?? RecordingLogic.availableURL(in: Self.folder, for: Date())
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let mixer = try AudioMixer(url: url)
            self.mixer = mixer
            try microphone.start(into: mixer)
            startSystemAudio(into: mixer)
            beginTimer()
            isRecording = true
        } catch {
            _ = teardown()
            permissionDenied = error is PermissionError
            errorMessage = error.localizedDescription
        }
    }

    private func startSystemAudio(into mixer: AudioMixer) {
        let active = RecordingLogic.attemptsSystemAudio(Permissions.systemAudio) && (try? system.start(into: mixer)) != nil
        notice = RecordingLogic.notice(systemAudioActive: active)
    }

    @discardableResult
    func stop(reveal: Bool = true) async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        let url = teardown()
        if reveal, let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return url
    }

    func record(seconds: Double, to output: URL? = nil) async -> URL? {
        await start(to: output)
        guard isRecording else { return nil }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return await stop(reveal: false)
    }

    /// Levels of the last finished recording, per source.
    func level(of source: AudioSource) -> LevelMeter? {
        lastLevels?[source.rawValue]
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.folder)
    }

    private func teardown() -> URL? {
        timer?.invalidate()
        timer = nil
        microphone.stop()
        system.stop()
        defer { mixer = nil }
        guard let mixer else { return nil }
        let url = mixer.finish()
        lastLevels = AudioSource.allCases.map(mixer.level)
        return url
    }

    private func beginTimer() {
        elapsed = 0
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(started) }
        }
    }
}
