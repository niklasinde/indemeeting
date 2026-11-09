import Foundation
import os

/// Moves the recordings once from `~/Movies/MeetingRecordings` to `AppPaths.recordings`. Each file is renamed on its
/// own, so an interrupted run carries on where it stopped on the next launch.
enum RecordingsMigration {
    struct Plan: Equatable {
        var moves: [String] = []
        var clashes: [String] = []
    }

    struct Outcome: Equatable {
        var moved: [String] = []
        var clashes: [String] = []
        var failed: [String] = []
        var rewritten = 0
        var removedOldFolder = false
    }

    static let ignored: Set<String> = [".DS_Store"]
    static let jobFlags: Set<String> = ["--process", "--resummarise", "--recognise-speakers", "--record"]

    static var legacyFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRecordings", isDirectory: true)
    }

    static func plan(old: [String], new: Set<String>) -> Plan {
        var plan = Plan()
        for name in old.sorted() where !ignored.contains(name) {
            if new.contains(name) { plan.clashes.append(name) } else { plan.moves.append(name) }
        }
        return plan
    }

    /// The bare file name for a stored audio path inside the old folder, unless that file stayed behind there.
    static func rewrittenAudioFile(_ stored: String, oldFolder: String, leftBehind: Set<String>) -> String? {
        let prefix = oldFolder.hasSuffix("/") ? oldFolder : oldFolder + "/"
        let path = (stored as NSString).expandingTildeInPath
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        guard !name.isEmpty, !name.contains("/"), !leftBehind.contains(name) else { return nil }
        return name
    }

    static func isRecordingJob(_ command: String) -> Bool {
        let lowered = command.lowercased()
        return ["worktime", "meetingrecorder"].contains { lowered.contains($0) } && command.split(separator: " ").contains { jobFlags.contains(String($0)) }
    }

    static func canRemove(remaining: [String]) -> Bool { remaining.allSatisfy(ignored.contains) }

    @discardableResult
    static func run(from old: URL, to new: URL, store: MeetingStore?, fileManager: FileManager = .default) throws -> Outcome {
        try fileManager.createDirectory(at: new, withIntermediateDirectories: true)
        let plan = plan(old: try fileManager.contentsOfDirectory(atPath: old.path),
                        new: Set(try fileManager.contentsOfDirectory(atPath: new.path)))
        var outcome = Outcome(clashes: plan.clashes)
        for name in plan.moves {
            do {
                try fileManager.moveItem(at: old.appendingPathComponent(name), to: new.appendingPathComponent(name))
                outcome.moved.append(name)
            } catch {
                outcome.failed.append(name)
                log("Could not move \(name): \(error.localizedDescription)")
            }
        }
        for name in plan.clashes { log("Left \(name) in \(old.path): \(new.path) already has a file of that name") }
        let leftBehind = Set(outcome.clashes + outcome.failed)
        outcome.rewritten = try store?.rewriteAudioFiles {
            rewrittenAudioFile($0, oldFolder: old.path, leftBehind: leftBehind)
        } ?? 0
        let remaining = (try? fileManager.contentsOfDirectory(atPath: old.path)) ?? []
        if canRemove(remaining: remaining) {
            remaining.forEach { try? fileManager.removeItem(at: old.appendingPathComponent($0)) }
            outcome.removedOldFolder = rmdir(old.path) == 0
        }
        return outcome
    }

    /// Runs at launch, outside `--data-dir`, and waits for a later launch while anything is recording or processing.
    static func runAtLaunch(store: MeetingStore, busy: Bool) {
        let old = legacyFolder
        let new = AppPaths.recordings
        guard AppPaths.dataDirectory == nil, FileManager.default.fileExists(atPath: old.path) else { return }
        guard !busy, !otherJobRunning() else {
            return log("Recordings stay in \(old.path) until the next launch: a recording or processing job is running")
        }
        do {
            try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
            guard try sameVolume(old, new) else {
                return log("Recordings stay in \(old.path): \(new.path) is on another volume")
            }
            let outcome = try run(from: old, to: new, store: store)
            log("Moved \(outcome.moved.count) recordings to \(new.path), rewrote \(outcome.rewritten) stored paths"
                + (outcome.removedOldFolder ? ", removed \(old.path)" : ", \(old.path) is not empty"))
        } catch {
            log("Moving the recordings failed: \(error.localizedDescription)")
        }
    }

    private static func sameVolume(_ first: URL, _ second: URL) throws -> Bool {
        let volume = { (url: URL) in try url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }
        guard let a = try volume(first), let b = try volume(second) else { return false }
        return a.isEqual(b)
    }

    private static func otherJobRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return true }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let me = String(ProcessInfo.processInfo.processIdentifier)
        return text.split(separator: "\n").contains { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            return parts.count == 2 && String(parts[0]) != me && isRecordingJob(String(parts[1]))
        }
    }

    private static func log(_ message: String) {
        Logger(subsystem: "MeetingRecorder", category: "migration").notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
