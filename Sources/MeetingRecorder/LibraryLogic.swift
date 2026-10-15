import Foundation

struct FolderItem: Equatable {
    let name: String
    let created: Date
}

struct RecordingEntry: Identifiable, Hashable {
    let audio: URL
    let date: Date
    let duration: TimeInterval?
    let hasTranscript: Bool
    let hasSummary: Bool

    var id: URL { audio }
    var name: String { audio.deletingPathExtension().lastPathComponent }
    var transcript: URL { ProcessingLogic.transcriptURL(for: audio) }
    var summary: URL { ProcessingLogic.summaryURL(for: audio) }
    var files: [URL] { [audio] + (hasTranscript ? [transcript] : []) + (hasSummary ? [summary] : []) }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(String)
    case task(String)
    case paragraph(String)
}

enum LibraryLogic {
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac"]

    /// Finished audio files; in-progress `.recording.m4a` files are left out.
    static func isListed(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        return audioExtensions.contains(url.pathExtension.lowercased())
            && !url.deletingPathExtension().lastPathComponent.hasSuffix(RecordingLogic.partialSuffix)
    }

    /// Newest first: by the minute in the file name (creation date otherwise), then `-3` before `-2` before the first.
    static func recordings(in folder: URL, files: [FolderItem], durations: [String: TimeInterval],
                           timeZone: TimeZone = .current) -> [RecordingEntry] {
        let names = Set(files.map(\.name))
        return files.filter { isListed($0.name) }
            .map { item in
                let audio = folder.appendingPathComponent(item.name)
                return RecordingEntry(
                    audio: audio,
                    date: RecordingLogic.date(fromFileName: item.name, timeZone: timeZone) ?? item.created,
                    duration: durations[item.name],
                    hasTranscript: names.contains(ProcessingLogic.transcriptURL(for: audio).lastPathComponent),
                    hasSummary: names.contains(ProcessingLogic.summaryURL(for: audio).lastPathComponent))
            }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func markdownBlocks(_ markdown: String) -> [MarkdownBlock] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
            }
            for prefix in ["- [ ] ", "- [x] "] where line.hasPrefix(prefix) { return .task(String(line.dropFirst(prefix.count))) }
            for prefix in ["- ", "* "] where line.hasPrefix(prefix) { return .bullet(String(line.dropFirst(prefix.count))) }
            return .paragraph(line)
        }
    }
}
