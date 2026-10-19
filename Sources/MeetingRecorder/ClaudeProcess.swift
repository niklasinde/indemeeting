import Foundation

/// Runs the `claude` CLI once, hands its output over line by line and can stop it with everything it started.
final class ClaudeProcess: @unchecked Sendable {
    struct Outcome: Equatable {
        var status: Int32
        var stderr: String
        var cancelled: Bool
        var timedOut: Bool
    }

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func run(cli: URL, arguments: [String], directory: URL, environment: [String: String], timeout: TimeInterval,
             onLine: @escaping @Sendable (String) -> Void) async -> Outcome {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors

            let finished = DispatchGroup()
            let lines = Buffer(), errorText = Buffer()
            finished.enter()
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    output.fileHandleForReading.readabilityHandler = nil
                    lines.rest().map(onLine)
                    return finished.leave()
                }
                lines.append(data).forEach(onLine)
            }
            finished.enter()
            errors.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    errors.fileHandleForReading.readabilityHandler = nil
                    return finished.leave()
                }
                errorText.collect(data)
            }
            process.terminationHandler = { [self] ended in
                finished.notify(queue: .global()) {
                    self.lock.lock()
                    let outcome = Outcome(status: ended.terminationStatus, stderr: errorText.all(),
                                          cancelled: self.cancelled, timedOut: self.timedOut)
                    self.lock.unlock()
                    continuation.resume(returning: outcome)
                }
            }
            lock.lock()
            let alreadyCancelled = cancelled
            self.process = process
            lock.unlock()
            do {
                if alreadyCancelled { throw CocoaError(.userCancelled) }
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: Outcome(status: -1, stderr: error.localizedDescription, cancelled: alreadyCancelled, timedOut: false))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop(timedOut: true) }
        }
    }

    func cancel() { stop(timedOut: false) }

    private func stop(timedOut: Bool) {
        lock.lock()
        guard let process, process.isRunning else {
            if !timedOut { cancelled = true }
            lock.unlock()
            return
        }
        if timedOut { self.timedOut = true } else { cancelled = true }
        lock.unlock()
        Self.terminateTree(process.processIdentifier)
    }

    /// Stops the process and every process it started, children first, so a `gh` or `git` it is waiting on does not outlive it.
    static func terminateTree(_ pid: pid_t) {
        let children = descendants(of: pid)
        for child in children.reversed() + [pid] { kill(child, SIGTERM) }
    }

    private static func descendants(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        let direct = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
        return direct.flatMap { [$0] + descendants(of: $0) }
    }
}

/// Bytes read from a pipe, handed out as complete lines.
private final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            lines.append(String(decoding: data[data.startIndex..<newline], as: UTF8.self))
            data = Data(data[data.index(after: newline)...])
        }
        return lines
    }

    func collect(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func rest() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }

    func all() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
