import CryptoKit
import Foundation

/// The National Library of Sweden's Swedish Whisper models, in the whisper.cpp format they publish on Hugging Face.
enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny, base, small, medium, large

    var id: String { rawValue }
    var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var quantized: Bool { self == .medium || self == .large }
    var remoteFile: String { quantized ? "ggml-model-q5_0.bin" : "ggml-model.bin" }
    var engineName: String { "kb-whisper-\(rawValue)" + (quantized ? "-q5_0" : "") }
    var fileName: String { engineName + ".bin" }
    var remoteURL: URL { URL(string: "https://huggingface.co/KBLab/kb-whisper-\(rawValue)/resolve/main/\(remoteFile)")! }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var bytes: Int64 {
        switch self {
        case .tiny: return 77_691_730
        case .base: return 147_951_482
        case .small: return 487_601_984
        case .medium: return 539_212_484
        case .large: return 1_081_140_203
        }
    }

    var sha256: String {
        switch self {
        case .tiny: return "054187c95948ee0455d428db0c0d6c84d6c6157dab72e86857ced13233118b03"
        case .base: return "f5e3cdb33e537eedfa2a749b5cae28c4c511873a1b13362f87dffbe07891d3fe"
        case .small: return "de6911330cbdc131362f7a955682b65c8a5a2394caba73e7ea821a9822efb8c6"
        case .medium: return "7f8762e0ade9e0073674c0d5acae942a0b1ea98add9baa008ee89c94eaba43d0"
        case .large: return "6d2863812d7410322bb7d8647a5c7260761300fa946714c9ed66d22bb30bcb19"
        }
    }

    func url(in folder: URL = AppPaths.models) -> URL { folder.appendingPathComponent(fileName) }

    func isInstalled(in folder: URL = AppPaths.models) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url(in: folder).path)[.size] as? Int64) == bytes
    }

    static func installed(in folder: URL = AppPaths.models) -> [WhisperModel] { allCases.filter { $0.isInstalled(in: folder) } }

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
        case .notInstalled(let model): return "KB-Whisper \(model.displayName) is not downloaded. Download it in Settings."
        case .couldNotLoad(let model):
            return "KB-Whisper \(model.displayName) could not be loaded. Remove it and download it again in Settings."
        case .unavailable: return "This build of Meeting Recorder does not include KB-Whisper."
        }
    }
}

/// What transcribes a language: Apple's on-device speech models, or a downloaded KB-Whisper model for Swedish.
enum TranscriptionEngine: Hashable {
    case apple
    case whisper(WhisperModel)

    static let appleValue = "apple"

    init(storedValue: String?) {
        self = storedValue.flatMap { value in WhisperModel.allCases.first { $0.engineName == value } }.map(Self.whisper) ?? .apple
    }

    var storedValue: String {
        if case .whisper(let model) = self { return model.engineName }
        return Self.appleValue
    }

    var displayName: String {
        if case .whisper(let model) = self { return "KB-Whisper \(model.displayName)" }
        return "Apple"
    }

    static func storageKey(for language: MeetingLanguage) -> String { "transcriptionEngine.\(language.rawValue)" }

    static func supports(_ language: MeetingLanguage) -> Bool { language == .swedish }

    /// The engines Settings offers for a language: Apple, then each downloaded KB-Whisper model for Swedish.
    static func choices(for language: MeetingLanguage, installed: [WhisperModel]) -> [TranscriptionEngine] {
        [.apple] + (supports(language) ? installed.map(Self.whisper) : [])
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
