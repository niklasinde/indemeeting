import Foundation

/// The mean of per-word confidences, weighted by how much text each covers. Dictation leaves the confidence out of
/// some results, so the mean is only given when it covers at least half the text.
struct ConfidenceMean {
    private var sum = 0.0
    private var covered = 0
    private var total = 0

    mutating func add(_ confidence: Double?, weight: Int) {
        total += weight
        guard let confidence else { return }
        sum += confidence * Double(weight)
        covered += weight
    }

    var value: Double? { covered == 0 || covered * 2 < total ? nil : sum / Double(covered) }
}

/// How one candidate language did on the speech sample.
struct LanguageScore: Equatable {
    let language: MeetingLanguage
    /// Words in the sample's transcript in this language.
    let words: Int
    /// The recogniser's mean confidence in those words.
    let confidence: Double?
    /// How likely the transcript is to be written in this language, among the candidates.
    let reads: Double

    /// How well the sample was understood in this language: a transcript that reads as some other language scores
    /// nothing, and one without a confidence counts as half sure.
    var value: Double { words == 0 ? 0 : reads * (confidence ?? 0.5) }
}

struct LanguageDecision: Equatable {
    let language: MeetingLanguage
    let confidence: Double
    let scores: [LanguageScore]
    /// Whether the scores were too close or too thin to go by, so the Mac's preferred language was used.
    var isFallback = false

    var summary: String {
        let scores = scores.map { String(format: "%@ %.2f", $0.language.code, $0.value) }.joined(separator: ", ")
        return "\(language.displayName) (\(isFallback ? "preferred language" : String(format: "confidence %.2f", confidence)); \(scores))"
    }

    init(only language: MeetingLanguage) {
        self.language = language
        confidence = 1
        scores = []
    }

    init(scores: [LanguageScore], among candidates: [MeetingLanguage], preferred: [String] = Locale.preferredLanguages) {
        self.scores = scores
        let ranked = scores.sorted { $0.value > $1.value }
        let total = scores.reduce(0) { $0 + $1.value }
        if let best = ranked.first, total > 0, best.value / total >= LanguageLogic.minimumShare {
            language = best.language
            confidence = best.value / total
        } else {
            language = LanguageLogic.preferred(among: candidates, preferred: preferred)
            confidence = 0
            isFallback = true
        }
    }
}

enum LanguageLogic {
    static let sampleLength: TimeInterval = 45
    static let windowLength: TimeInterval = 25
    /// The share of the combined score the winner needs before it is trusted over the Mac's preferred language.
    static let minimumShare = 0.55

    /// Where to take the speech sample from: one window from the start of a short recording, or two of a long one,
    /// at the start and halfway, each up to the next window.
    static func sampleWindows(duration: TimeInterval) -> [(start: TimeInterval, end: TimeInterval, length: TimeInterval)] {
        guard duration > 4 * sampleLength else { return [(0, duration, sampleLength)] }
        return [(0, duration / 2, windowLength), (duration / 2, duration, windowLength)]
    }

    /// The first candidate in the Mac's preferred languages, else Swedish when it is a candidate, else the first one.
    static func preferred(among candidates: [MeetingLanguage], preferred: [String]) -> MeetingLanguage {
        preferred.lazy.compactMap { code in candidates.first { $0.code == Locale(identifier: code).language.languageCode?.identifier } }
            .first ?? (candidates.contains(.swedish) ? .swedish : candidates.first ?? .swedish)
    }
}

extension MeetingLanguage {
    static let listenedKey = "meetingLanguages"
    /// The single default language of earlier versions, which becomes the only listened-for one.
    static let legacyKey = "meetingLanguage"

    /// The languages new recordings may be in, in `allCases` order: every language unless the user chose otherwise.
    static func listened(stored: [String]?, legacy: String?) -> [MeetingLanguage] {
        let chosen = Set((stored ?? legacy.map { [$0] } ?? []).compactMap(Self.init))
        let listened = allCases.filter(chosen.contains)
        return listened.isEmpty ? allCases : listened
    }

    static func listened(in defaults: UserDefaults = .standard) -> [MeetingLanguage] {
        listened(stored: defaults.stringArray(forKey: listenedKey), legacy: defaults.string(forKey: legacyKey))
    }

    static func setListened(_ languages: [MeetingLanguage], in defaults: UserDefaults = .standard) {
        defaults.set(allCases.filter(languages.contains).map(\.rawValue), forKey: listenedKey)
    }

    /// The language to use when nothing is detected: the only listened-for one, or the Mac's preferred among them.
    static func current(in defaults: UserDefaults = .standard, preferred: [String] = Locale.preferredLanguages) -> MeetingLanguage {
        LanguageLogic.preferred(among: listened(in: defaults), preferred: preferred)
    }

    static var current: MeetingLanguage { current() }
}

extension LanguageLogic {
    /// `--detect-language <file> [--languages sv-SE,en-US]`.
    static func detectArguments(_ arguments: [String]) -> (audio: URL, candidates: [MeetingLanguage]?)? {
        guard let index = arguments.firstIndex(of: "--detect-language"), index + 1 < arguments.count else { return nil }
        let candidates = arguments.firstIndex(of: "--languages").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            .map { MeetingLanguage.listened(stored: $0.split(separator: ",").map(String.init), legacy: nil) }
        return (URL(fileURLWithPath: arguments[index + 1]), candidates)
    }
}
