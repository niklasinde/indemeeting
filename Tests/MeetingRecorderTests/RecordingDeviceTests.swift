import Foundation

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func source(_ file: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent("Sources/MeetingRecorder/\(file)"), encoding: .utf8)) ?? ""
}

let recordingDeviceTests: [(name: String, run: () throws -> Void)] = [
    ("the watcher only reads device state and never opens an input engine", {
        let text = source("MeetingWatcher.swift")
        check(!text.isEmpty, "MeetingWatcher.swift is readable")
        for word in ["AVAudioEngine", "AVAudioInputNode", "installTap", "AudioDeviceStart", "AudioDeviceCreateIOProcID", "CreateAggregateDevice", "CreateProcessTap"] {
            check(!text.contains(word), "MeetingWatcher.swift mentions \(word)")
        }
    }),

    ("the microphone engine is released when it stops, so the input device is let go", {
        let text = source("AudioCapture.swift")
        check(text.contains("private var engine: AVAudioEngine?"), "engine is optional and owned per session")
        check(text.contains("self.engine = nil"), "stop drops the engine")
        check(text.contains("engine.reset()"), "stop resets the engine before it is dropped")
    }),

    ("every audio release goes through one idempotent entry point used by teardown and quit", {
        let recorder = source("Recorder.swift")
        check(recorder.contains("func releaseAudioDevices()"), "one release entry point")
        check(recorder.contains("releaseAudioDevices()\n        defer"), "teardown releases through it")
        check(source("MeetingRecorderApp.swift").contains("recorder.releaseAudioDevices()"), "quit releases through it")
    }),
]
