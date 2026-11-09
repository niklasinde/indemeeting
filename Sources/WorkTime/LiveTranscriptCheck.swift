#if DEBUG
import AVFoundation
import AppKit
import Combine

/// `--live-transcribe <audio> [--language sv-SE] [--snapshot <folder>]`: plays a file in real time into a mixer as
/// system audio, pausing halfway, and prints the live transcript; `--snapshot` saves PNGs of the window while it plays
/// and at the end. Nothing is captured and the mixer writes to a temporary folder.
@MainActor
enum LiveTranscriptCheck {
    static func value(_ arguments: [String]) -> URL? {
        PhoneCommandLine.value("--live-transcribe", in: arguments).map { URL(fileURLWithPath: $0) }
    }

    static func run(_ audio: URL, arguments: [String]) -> Never {
        let language = PhoneCommandLine.value("--language", in: arguments).flatMap(MeetingLanguage.init) ?? .current
        let snapshots = PhoneCommandLine.value("--snapshot", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
        NSApplication.shared.setActivationPolicy(.accessory)
        Task {
            do {
                try await play(audio, language: language, snapshots: snapshots)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        NSApplication.shared.run()
        exit(0)
    }

    private static func play(_ audio: URL, language: MeetingLanguage, snapshots: URL?) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("check.m4a")
        let mixer = try AudioMixer(url: url, stems: true)
        let live = LiveTranscription()
        live.languages = { _ in [language] }
        var updates = 0
        let counting = live.$transcript.sink { _ in updates += 1 }
        defer { counting.cancel() }
        let window = snapshots.map { _ in LiveTranscriptWindow.makeWindow(LiveTranscriptView(recorder: Recorder(), live: live)) }
        window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window?.orderBack(nil)
        func snapshot(_ name: String) {
            guard let window, let snapshots else { return }
            try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            PreviewRenderer.save(window, to: snapshots.appendingPathComponent("\(name).png"))
        }

        let file = try AVAudioFile(forReading: audio)
        let normalizer = PCMNormalizer()
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        let chunks = Int(file.length / AVAudioFramePosition(chunk)) + 1
        live.start(meeting: url, mixer: mixer)
        for index in 0..<chunks {
            if index == chunks * 3 / 4 { snapshot("playing") }
            if index == chunks / 2 {
                mixer.pause()
                live.pause()
                print("-- paused at \(index / 10)s, lines so far: \(live.transcript.lines.count)")
                try await Task.sleep(nanoseconds: 1_000_000_000)
                mixer.resume()
                live.resume()
                print("-- resumed")
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            mixer.append(normalizer.samples(from: buffer), from: .system)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        live.stop()
        mixer.finish()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        snapshot("finished")
        if let note = live.note { print("Note: \(note)") }
        print("\(language.displayName), \(updates) updates")
        for line in live.transcript.lines {
            print("\(ProcessingLogic.timestamp(line.start)) \(line.speaker.name(in: language))\(line.isFinal ? "" : " (partial)"): \(line.text)")
        }
    }
}
#endif
