import AppKit
import SwiftUI

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var permissionDenied = false

    private let microphone = MicrophoneCapture()
    private let system = SystemAudioCapture()
    private var mixer: AudioMixer?
    private var outputURL: URL?
    private var timer: Timer?

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRecordings", isDirectory: true)
    }

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil
        permissionDenied = false
        do {
            try await Permissions.ensureAll()
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let url = Self.folder.appendingPathComponent(Self.fileName(for: Date()))
            let mixer = try AudioMixer(url: url)
            self.mixer = mixer
            outputURL = url
            try microphone.start(into: mixer)
            try await system.start(into: mixer)
            beginTimer()
            isRecording = true
        } catch {
            await teardown()
            permissionDenied = error is PermissionError
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        let url = outputURL
        await teardown()
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.folder)
    }

    private func teardown() async {
        timer?.invalidate()
        timer = nil
        microphone.stop()
        await system.stop()
        mixer?.finish()
        mixer = nil
    }

    private func beginTimer() {
        elapsed = 0
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(started) }
        }
    }

    private static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "'Meeting-'yyyy-MM-dd-HHmm'.m4a'"
        return formatter.string(from: date)
    }
}
