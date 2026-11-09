import CryptoKit
import Foundation

/// A group of Whisper models from one publisher; Settings lists each in its own section.
struct WhisperFamily: Hashable {
    let name: String
    let about: String

    static let openAI = WhisperFamily(name: "Whisper", about: "OpenAI\u{2019}s multilingual speech models, downloaded from Hugging "
                                      + "Face and run on this Mac with whisper.cpp. The language is detected for each stretch of "
                                      + "speech, so a meeting can switch between the languages you listen for.")
    static let silero = WhisperFamily(name: "Silero VAD", about: "Finds the speech in the audio, so Whisper never hears silence.")
}

/// A whisper.cpp model that can be downloaded from Hugging Face. Add one to `all` to offer it in Settings; the list is
/// ranked best quality first.
struct WhisperModel: Hashable, Identifiable {
    let id: String
    let name: String
    let family: WhisperFamily
    let repo: String
    let file: String
    let bytes: Int64
    let sha256: String
    let languages: Set<MeetingLanguage>
    var hint: String? = nil
    var recommended = false

    static let all: [WhisperModel] = [
        .openAI("ggml-large-v3.bin", name: "Large v3", hint: "Best quality, slowest", recommended: true, bytes: 3_095_033_483,
                sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"),
        .openAI("ggml-large-v3-turbo.bin", name: "Large v3 Turbo", hint: "Near-best quality, faster", bytes: 1_624_555_275,
                sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        .openAI("ggml-large-v3-turbo-q8_0.bin", name: "Large v3 Turbo (8-bit)", hint: "Best quality for its size",
                bytes: 874_188_075, sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"),
        .openAI("ggml-large-v3-q5_0.bin", name: "Large v3 (5-bit)", hint: "Smaller, slightly less accurate", bytes: 1_081_140_203,
                sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1"),
        .openAI("ggml-large-v3-turbo-q5_0.bin", name: "Large v3 Turbo (5-bit)", hint: "Fastest", bytes: 574_041_195,
                sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
    ]

    /// The voice activity model whisper.cpp runs before Whisper, fetched along with the Whisper models. Not an engine.
    static let vad = WhisperModel(id: "ggml-silero-v6.2.0", name: "Silero VAD v6.2.0", family: .silero, repo: "ggml-org/whisper-vad",
                                  file: "ggml-silero-v6.2.0.bin", bytes: 885_098,
                                  sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987", languages: [])

    /// A model from whisper.cpp's own repository, named after its file: `ggml-large-v3-turbo-q8_0`.
    static func openAI(_ file: String, name: String, hint: String, recommended: Bool = false, bytes: Int64,
                       sha256: String) -> WhisperModel {
        WhisperModel(id: String(file.dropLast(".bin".count)), name: name, family: .openAI, repo: "ggerganov/whisper.cpp", file: file,
                     bytes: bytes, sha256: sha256, languages: Set(MeetingLanguage.allCases), hint: hint, recommended: recommended)
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

    /// Model files in the folder that no model in the catalogue uses, such as KB-Whisper's.
    static func leftovers(in folder: URL = AppPaths.models) -> [URL] {
        let names = Set((all + [vad]).map(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "bin" && !names.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The voice activity model's file once it is downloaded; without it Whisper hears all the audio, as before.
    static func vadFile(in folder: URL = AppPaths.models) -> URL? { vad.isInstalled(in: folder) ? vad.url(in: folder) : nil }

    /// Whether to fetch the voice activity model: a Whisper model is downloaded and it is not.
    static func needsVAD(in folder: URL = AppPaths.models) -> Bool { !installed(in: folder).isEmpty && vadFile(in: folder) == nil }

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
        case .unavailable: return "This build of WorkTime does not include Whisper."
        }
    }
}

/// What transcribes meetings: Apple's on-device speech models, or a downloaded Whisper model.
enum TranscriptionEngine: Hashable {
    case apple
    case whisper(WhisperModel)

    static let appleValue = "apple"
    /// Stored with the transcript Apple's speech model wrote live while recording.
    static let liveValue = "apple-live"
    /// Stored, followed by the model's id, with a live transcript Whisper wrote at least part of.
    static let liveWhisperPrefix = "whisper-live:"
    static let storageKey = "transcriptionEngine"
    static let beamSearchKey = "whisperBeamSearch"
    static let quietKey = "whisperQuiet"

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

    /// The name of the engine stored with a transcript: a Whisper model's id, or Apple's speech module.
    static func displayName(stored engine: String) -> String {
        if let model = WhisperModel.with(id: engine) { return model.displayName }
        if engine == liveValue { return "Live \u{00B7} Apple Speech" }
        if let model = liveModel(engine) { return "Live \u{00B7} " + displayName(stored: model) }
        return ["SpeechTranscriber", "DictationTranscriber"].contains(engine) ? "Apple Speech" : engine
    }

    /// What a live transcript is stored as: `whisper-live:<model>` once Whisper wrote any of it, else `apple-live`.
    static func liveValue(model: String?) -> String { model.map { liveWhisperPrefix + $0 } ?? liveValue }

    /// The Whisper model of a live transcript's stored engine.
    static func liveModel(_ engine: String?) -> String? {
        guard let engine, engine.hasPrefix(liveWhisperPrefix) else { return nil }
        return String(engine.dropFirst(liveWhisperPrefix.count))
    }

    static func isLive(_ engine: String?) -> Bool { engine == liveValue || liveModel(engine) != nil }

    /// The engines Settings offers: Apple, then each downloaded model, best first.
    static func choices(installed: [WhisperModel]) -> [TranscriptionEngine] { [.apple] + installed.map(Self.whisper) }

    /// The stored choice. Nothing stored is Apple; a model that is gone, or one no longer offered, falls back to the best
    /// downloaded model, or Apple when there is none.
    static func selected(stored: String?, installed: [WhisperModel]) -> TranscriptionEngine {
        guard let stored, stored != appleValue else { return .apple }
        if let model = installed.first(where: { $0.id == stored }) { return .whisper(model) }
        return installed.first.map(Self.whisper) ?? .apple
    }

    /// The stored choice, or the one stored per language before there was a single setting.
    static func stored(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: storageKey)
            ?? MeetingLanguage.allCases.lazy.compactMap { defaults.string(forKey: "\(storageKey).\($0.rawValue)") }.first
    }

    static func current(defaults: UserDefaults = .standard) -> TranscriptionEngine {
        selected(stored: stored(in: defaults), installed: WhisperModel.installed())
    }

    static func beamSearch(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: beamSearchKey) as? Bool ?? true }

    static func quiet(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: quietKey) as? Bool ?? true }
}

/// Where to cut audio into stretches Whisper detects the language of one by one: at the middle of a pause once a stretch
/// is long enough, or at its quietest frame when it reaches the maximum.
enum SpeechChunks {
    static let frameLength: TimeInterval = 0.1
    static let minimumPause: TimeInterval = 0.5
    static let minimumChunk: TimeInterval = 8
    static let maximumChunk: TimeInterval = 28
    /// A chunk with less sound than this is silence, which Whisper fills with phrases such as "Thank you."
    static let minimumSpeech: TimeInterval = 1

    /// Frame ranges; `levels` is the RMS of each frame.
    static func chunks(levels: [Double], threshold: Double = LevelMeter.soundThreshold) -> [Range<Int>] {
        let minimum = Int(minimumChunk / frameLength), maximum = Int(maximumChunk / frameLength)
        let pause = Int(minimumPause / frameLength)
        var ranges: [Range<Int>] = []
        var start = 0
        var quiet = 0
        var index = 0
        while index < levels.count {
            quiet = levels[index] < threshold ? quiet + 1 : 0
            let length = index + 1 - start
            if length >= minimum, quiet >= pause {
                let cut = index + 1 - quiet / 2
                ranges.append(start..<cut)
                start = cut
                quiet = 0
            } else if length >= maximum {
                let window = (start + minimum)...index
                let cut = window.min { levels[$0] < levels[$1] }.map { $0 + 1 } ?? index + 1
                ranges.append(start..<cut)
                start = cut
                quiet = 0
                index = cut - 1
            }
            index += 1
        }
        if start < levels.count { ranges.append(start..<levels.count) }
        return ranges
    }

    /// Sample ranges of `samples` at `sampleRate`.
    static func ranges(of samples: [Float], sampleRate: Double) -> [Range<Int>] {
        let frame = Int(frameLength * sampleRate)
        let levels = stride(from: 0, to: samples.count, by: frame).map { start in
            var meter = LevelMeter()
            meter.add(Array(samples[start..<min(samples.count, start + frame)]))
            return meter.rms
        }
        return spoken(chunks(levels: levels), levels: levels).map { $0.lowerBound * frame..<min(samples.count, $0.upperBound * frame) }
    }

    /// The chunks with at least `minimumSpeech` of sound in them.
    static func spoken(_ chunks: [Range<Int>], levels: [Double], threshold: Double = LevelMeter.soundThreshold) -> [Range<Int>] {
        let minimum = Int(minimumSpeech / frameLength)
        return chunks.filter { chunk in levels[chunk].lazy.filter { $0 >= threshold }.count >= minimum }
    }
}

/// How Silero VAD cuts speech from silence before Whisper, tuned for meetings: a short "Ja." still counts as speech,
/// a pause must last half a second to end it, and each stretch keeps a quarter second either side.
struct WhisperVAD: Equatable {
    var threshold: Float = 0.5
    var minSpeechMs: Int32 = 150
    var minSilenceMs: Int32 = 500
    var speechPadMs: Int32 = 250

    static let meetings = WhisperVAD()
}

enum WhisperLogic {
    /// whisper.cpp takes 16 kHz mono floats.
    static let sampleRate: Double = 16_000
    static let domainTerms = ["Quiddly", "finq", "QDLY", "Jira", "PR"]
    /// Whisper reads at most 224 prompt tokens; this many characters stays under that in Swedish and English.
    static let promptLimit = 550

    /// CPU threads and priority for Whisper. Quiet mode keeps to four threads at a low priority, a little higher on AC power
    /// without Low Power Mode; the GPU does most of the work either way.
    static func pace(quiet: Bool, onAC: Bool, lowPower: Bool, cores: Int) -> (threads: Int32, qos: DispatchQoS) {
        let threads = Int32(min(8, max(1, cores - 2)))
        guard quiet else { return (threads, .userInitiated) }
        return (min(4, threads), onAC && !lowPower ? .utility : .background)
    }

    /// A prompt that spells the words meetings are likely to use: the domain terms, people's names, Jira project keys,
    /// then the names and acronyms most used in ticket titles. Whatever does not fit in `limit` characters is dropped.
    static func vocabularyPrompt(names: [String], ticketKeys: [String], ticketTitles: [String], limit: Int = promptLimit) -> String {
        let projects = ticketKeys.compactMap { $0.split(separator: "-").first.map(String.init) }
        var counts: [String: Int] = [:]
        for title in ticketTitles {
            for (index, word) in words(title).enumerated() where isDistinctive(word, first: index == 0) { counts[word, default: 0] += 1 }
        }
        let titleTerms = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        var seen: Set<String> = []
        var prompt = ""
        for term in domainTerms + names + byFrequency(projects) + titleTerms {
            let term = term.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let next = prompt.isEmpty ? term : prompt + ", " + term
            guard next.count + 1 <= limit else { break }
            prompt = next
        }
        return prompt.isEmpty ? "" : prompt + "."
    }

    /// The most likely of `allowed` (Whisper codes) in `probabilities`; any language when none is allowed, and `fallback`
    /// when there is nothing to go on.
    static func language(_ probabilities: [String: Double], allowed: [String], fallback: String) -> String {
        let candidates = allowed.isEmpty ? probabilities : probabilities.filter { allowed.contains($0.key) }
        return candidates.max { $0.value < $1.value }?.key ?? fallback
    }

    private static func words(_ text: String) -> [String] {
        text.split { $0.isWhitespace || ",.:;()[]\"'/".contains($0) }.map(String.init)
    }

    /// A name, product or acronym: capitalised mid-title, or with capitals, digits or dots inside, as `GraphQL` or `SIE4`.
    private static func isDistinctive(_ word: String, first: Bool) -> Bool {
        guard word.count >= 3, word.first?.isLetter == true, !word.contains("-") else { return false }
        let inner = word.dropFirst()
        if inner.contains(where: \.isUppercase) || inner.contains(where: \.isNumber) { return true }
        return !first && word.first?.isUppercase == true
    }

    private static func byFrequency(_ values: [String]) -> [String] {
        Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }
}

extension ProcessingLogic {
    /// Above this no-speech probability a Whisper segment is taken for silence.
    static let noSpeechLimit = 0.6

    /// Whisper's hallucinations on silence and its bracketed sound labels, such as `[MUSIK]` or `(skratt)`.
    static func isWhisperNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last else { return true }
        return "[(*♪".contains(first) && "])*♪".contains(last) || isHallucination(trimmed)
    }

    /// A whole line Whisper writes over silence, such as "Tack för att ni tittade!", never real speech that quotes one.
    static func isHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        return WhisperHallucinations.line.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil
    }

    /// The text with any run of a word or phrase of up to four words repeated four or more times kept once, as Whisper
    /// loops on "the the the the" or "vi ses vi ses vi ses vi ses".
    static func collapseRepeats(_ text: String, minimum: Int = 4) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let keys = words.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        var kept: [String] = []
        var index = 0
        while index < words.count {
            var skipped = false
            for length in 1...4 where index + length * minimum <= words.count {
                let phrase = keys[index..<index + length]
                guard phrase.contains(where: { !$0.isEmpty }) else { continue }
                var repeats = 1
                while index + (repeats + 1) * length <= words.count,
                      keys[index + repeats * length..<index + (repeats + 1) * length].elementsEqual(phrase) { repeats += 1 }
                if repeats >= minimum {
                    kept += words[index..<index + length]
                    index += repeats * length
                    skipped = true
                    break
                }
            }
            if !skipped {
                kept.append(words[index])
                index += 1
            }
        }
        return kept.joined(separator: " ")
    }

    /// Sentences from whisper.cpp segments, whose times are in hundredths of a second.
    static func whisperSentences(_ segments: [(text: String, start: Int64)]) -> [TranscriptSegment] {
        sentences(withoutNoise(segments).map { ($0.text, TimeInterval($0.start) / 100) }, from: 0)
            .compactMap { segment in
                let text = collapseRepeats(segment.text)
                guard text.contains(where: { $0.isLetter || $0.isNumber }), !isWhisperNoise(text) else { return nil }
                return TranscriptSegment(start: segment.start, text: text)
            }
    }

    /// Whisper often splits an outro, as "Thank you for watching," and "and see you in the next video.", so a piece
    /// that only makes sense as the rest of a dropped outro goes with it.
    private static func withoutNoise(_ segments: [(text: String, start: Int64)]) -> [(text: String, start: Int64)] {
        var outro = ""
        return segments.filter { segment in
            if isWhisperNoise(segment.text) {
                outro = isHallucination(segment.text) ? segment.text : ""
                return false
            }
            guard !outro.isEmpty, isHallucination(outro + segment.text) else { outro = ""; return true }
            outro += segment.text
            return false
        }
    }
}

/// Stock lines Whisper invents over silence, learnt from YouTube subtitles. The patterns run on lowercased words
/// without punctuation. A closer or filler only counts after an outro, so "Vi ses nästa gång." and "Tack." stay.
enum WhisperHallucinations {
    static let outros = [
        "tack (så mycket )?för att (du|ni) (har )?(tittat|tittade|kollat|kollade|lyssnat|lyssnade)( på (den här|denna) (video|videon|klipp|klippet))?",
        "(glöm inte att )?prenumerera på (min |vår )?kanal(en)?",
        "(svensk )?(textning|undertexter|undertext)( gjord)?( (av|från))? [^ ]+( [^ ]+){0,2}",
        "svensktextning( nu)?",
        "thank you (so much |very much )?for watching( this video| the video)?",
        "thanks (so much )?for watching( this video| the video)?",
        "(please|don t forget to) (like and )?subscribe( to (my|the|our) channel)?",
        "(like and )?subscribe to (my|the|our) channel",
        "(subtitles|captions) by (the )?amara org community",
        "takk for at (du|dere) (så|har sett)( på( videoen| denne videoen)?)?",
        "tak (fordi|for at) (du|i) (så|har set)( med)?( (på )?(videoen|denne video))?",
        "abonner på (kanalen|min kanal)",
        "(teksting|tekstet|undertekster|undertekstet) (av|af) [^ ]+( [^ ]+){0,2}",
        "(vielen )?danke? (fürs|für das|für ihr|für eure) zuschauen",
        "untertitel (von|der|im auftrag des) [^ ]+( [^ ]+){0,4}",
    ]
    static let closers = [
        "see you (in the |on the )?next (video|time|one)",
        "vi ses (i nästa (video|klipp)|nästa gång)",
        "vi ses (i neste video|neste gang)",
        "bis zum nächsten (mal|video)",
    ]
    static let fillers = ["alla", "allihop", "allihopa", "everyone", "everybody", "guys", "bye", "hej", "då", "igen", "again", "alle"]

    static let line: NSRegularExpression = {
        func any(_ patterns: [String]) -> String { "(?:" + patterns.joined(separator: "|") + ")" }
        let next = "(?: (?:och|and|og|und|så))? " + any(outros + closers)
        return try! NSRegularExpression(pattern: "^" + any(outros) + "(?:" + next + ")*(?: " + any(fillers) + "){0,3}$")
    }()
}
