import CryptoKit
import Foundation

/// A group of Whisper models from one publisher; Settings lists each in its own section.
struct WhisperFamily: Hashable {
    let name: String
    let about: String

    static let kb = WhisperFamily(name: "KB-Whisper", about: "Swedish speech models from the National Library of Sweden, downloaded "
                                  + "from Hugging Face and run on this Mac with whisper.cpp. Larger models are more accurate and slower.")
}

/// A whisper.cpp model that can be downloaded from Hugging Face. Add one to `all` to offer it in Settings.
struct WhisperModel: Hashable, Identifiable {
    let id: String
    let name: String
    let family: WhisperFamily
    let repo: String
    let file: String
    let bytes: Int64
    let sha256: String
    let languages: Set<MeetingLanguage>

    static let all: [WhisperModel] = [
        .kb("tiny", bytes: 77_691_730,
            sha256: "054187c95948ee0455d428db0c0d6c84d6c6157dab72e86857ced13233118b03"),
        .kb("base", bytes: 147_951_482,
            sha256: "f5e3cdb33e537eedfa2a749b5cae28c4c511873a1b13362f87dffbe07891d3fe"),
        .kb("small", bytes: 487_601_984,
            sha256: "de6911330cbdc131362f7a955682b65c8a5a2394caba73e7ea821a9822efb8c6"),
        .kb("medium", quantization: "q5_0", bytes: 539_212_484,
            sha256: "7f8762e0ade9e0073674c0d5acae942a0b1ea98add9baa008ee89c94eaba43d0"),
        .kb("large", quantization: "q5_0", bytes: 1_081_140_203,
            sha256: "6d2863812d7410322bb7d8647a5c7260761300fa946714c9ed66d22bb30bcb19"),
    ]

    /// A KBLab model, named after its size and quantization: `kb-whisper-medium-q5_0`.
    static func kb(_ size: String, quantization: String? = nil, bytes: Int64, sha256: String) -> WhisperModel {
        let suffix = quantization.map { "-" + $0 } ?? ""
        return WhisperModel(id: "kb-whisper-\(size)\(suffix)", name: size.capitalized, family: .kb, repo: "KBLab/kb-whisper-\(size)",
                            file: "ggml-model\(suffix).bin", bytes: bytes, sha256: sha256, languages: [.swedish])
    }

    static func with(id: String) -> WhisperModel? { all.first { $0.id == id } }

    static var families: [WhisperFamily] { all.map(\.family).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    var displayName: String { "\(family.name) \(name)" }
    var fileName: String { id + ".bin" }
    var remoteURL: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    func url(in folder: URL = AppPaths.models) -> URL { folder.appendingPathComponent(fileName) }

    func isInstalled(in folder: URL = AppPaths.models) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url(in: folder).path)[.size] as? Int64) == bytes
    }

    static func installed(in folder: URL = AppPaths.models) -> [WhisperModel] { all.filter { $0.isInstalled(in: folder) } }

    /// Checks a downloaded file is this model, byte for byte.
    func verify(_ file: URL) throws {
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64
        guard size == bytes else { throw WhisperModelError.wrongSize(expected: bytes, got: size ?? 0) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw WhisperModelError.wrongChecksum }
    }
}

enum WhisperModelError: LocalizedError, Equatable {
    case wrongSize(expected: Int64, got: Int64)
    case wrongChecksum
    case http(Int)
    case notInstalled(WhisperModel)
    case couldNotLoad(WhisperModel)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .wrongSize(let expected, let got):
            return "the file is \(ByteCountFormatter.string(fromByteCount: got, countStyle: .file)), expected "
                + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        case .wrongChecksum: return "the file is damaged"
        case .http(let status): return "the server answered \(status)"
        case .notInstalled(let model): return "\(model.displayName) is not downloaded. Download it in Settings."
        case .couldNotLoad(let model):
            return "\(model.displayName) could not be loaded. Remove it and download it again in Settings."
        case .unavailable: return "This build of Meeting Recorder does not include KB-Whisper."
        }
    }
}

/// What transcribes a language: Apple's on-device speech models, or a downloaded Whisper model that supports it.
enum TranscriptionEngine: Hashable {
    case apple
    case whisper(WhisperModel)

    static let appleValue = "apple"

    init(storedValue: String?) {
        self = storedValue.flatMap(WhisperModel.with(id:)).map(Self.whisper) ?? .apple
    }

    var storedValue: String {
        if case .whisper(let model) = self { return model.id }
        return Self.appleValue
    }

    var displayName: String {
        if case .whisper(let model) = self { return model.displayName }
        return "Apple"
    }

    static func storageKey(for language: MeetingLanguage) -> String { "transcriptionEngine.\(language.rawValue)" }

    /// The languages some Whisper model in the catalogue can transcribe, so Settings offers a choice for them.
    static var whisperLanguages: [MeetingLanguage] {
        MeetingLanguage.allCases.filter { language in WhisperModel.all.contains { $0.languages.contains(language) } }
    }

    /// The engines Settings offers for a language: Apple, then each downloaded model that supports it.
    static func choices(for language: MeetingLanguage, installed: [WhisperModel]) -> [TranscriptionEngine] {
        [.apple] + installed.filter { $0.languages.contains(language) }.map(Self.whisper)
    }

    /// The stored choice for a language, or Apple when that model is no longer downloaded.
    static func selected(for language: MeetingLanguage, stored: String?, installed: [WhisperModel]) -> TranscriptionEngine {
        let engine = TranscriptionEngine(storedValue: stored)
        return choices(for: language, installed: installed).contains(engine) ? engine : .apple
    }

    static func current(for language: MeetingLanguage, defaults: UserDefaults = .standard) -> TranscriptionEngine {
        selected(for: language, stored: defaults.string(forKey: storageKey(for: language)), installed: WhisperModel.installed())
    }
}

extension ProcessingLogic {
    /// Whisper's hallucinations on silence and its bracketed sound labels, such as `[MUSIK]` or `(skratt)`.
    static func isWhisperNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last else { return true }
        return "[(*♪".contains(first) && "])*♪".contains(last)
    }

    /// Sentences from whisper.cpp segments, whose times are in hundredths of a second.
    static func whisperSentences(_ segments: [(text: String, start: Int64)]) -> [TranscriptSegment] {
        sentences(segments.filter { !isWhisperNoise($0.text) }.map { ($0.text, TimeInterval($0.start) / 100) }, from: 0)
    }
}
