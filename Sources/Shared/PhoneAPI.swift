import Foundation

/// The contract between the Mac app and the iPhone viewer. Pure Foundation so both targets compile this file.
enum PhoneAPI {
    static let version = 1
    static let serviceType = "_meetingrecorder._tcp"
    static let defaultPort = 47821
    static let pairingScheme = "meetingrecorder"
    static let deviceHeader = "X-Device-Id"
    static let pairingLifetime: TimeInterval = 300

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: Errors and status

/// The body of every non-2xx response.
struct PhoneError: Codable, Equatable {
    let error: String
    let message: String
}

struct PhoneFeatures: Codable, Equatable {
    var githubEnabled: Bool
    var activityEnabled: Bool
    var chatAvailable: Bool
}

struct PhoneStatus: Codable, Equatable {
    var appVersion: String
    var apiVersion: Int
    var schemaVersion: Int
    var serverTime: Date
    var serverName: String
    var features: PhoneFeatures
}

// MARK: Meetings

struct PhoneMeetingSummary: Codable, Equatable {
    var id: Int64
    var title: String
    var date: Date
    var duration: Double?
    var language: String?
    var hasSummary: Bool
    var speakers: [String]
    var chatCount: Int
    /// With a search: the text around the match, matches wrapped in `**`.
    var snippet: String?
}

struct PhoneMeetingList: Codable, Equatable {
    var meetings: [PhoneMeetingSummary]
    /// Pass as `before` for the next page; absent on the last page and for searches.
    var nextBefore: Date?
}

struct PhoneSummaryTopic: Codable, Equatable {
    var title: String
    var points: [String]
}

struct PhoneActionItem: Codable, Equatable {
    var id: Int64
    var owner: String?
    var text: String
    var done: Bool
}

struct PhoneSegment: Codable, Equatable {
    var start: Double
    var end: Double
    /// `you`, `others` or `speaker-N`.
    var speaker: String?
    /// The name the user gave the speaker, else the label in the meeting's language.
    var speakerName: String?
    var text: String
}

struct PhoneAudioInfo: Codable, Equatable {
    var available: Bool
    var duration: Double?
    var bytes: Int64?
    var contentType: String?
}

struct PhoneEngines: Codable, Equatable {
    var transcript: String?
    var summary: String?
}

struct PhoneMeetingDetail: Codable, Equatable {
    var id: Int64
    var title: String
    var date: Date
    var duration: Double?
    var languages: [String]
    var languageDetected: Bool
    var engines: PhoneEngines
    var summaryTitle: String?
    var summaryUnavailable: String?
    var topics: [PhoneSummaryTopic]
    var actionItems: [PhoneActionItem]
    var notes: String
    var transcript: [PhoneSegment]
    var audio: PhoneAudioInfo
}

// MARK: Activity

struct PhoneTotal: Codable, Equatable {
    var name: String
    var seconds: Double
}

struct PhoneWorkTotal: Codable, Equatable {
    var name: String
    var repo: String?
    var ticket: String?
    var project: String?
    var projectGuessed: Bool
    var seconds: Double
}

struct PhoneTicketTotal: Codable, Equatable {
    var ticket: String
    var title: String?
    var url: String?
    var branches: [String]
    var project: String?
    var projectGuessed: Bool
    var seconds: Double
}

struct PhoneActivityTotals: Codable, Equatable {
    var activeSeconds: Double
    var projects: [PhoneTotal]
    var categories: [PhoneTotal]
    var apps: [PhoneTotal]
    var branches: [PhoneWorkTotal]
    var tickets: [PhoneTicketTotal]
}

struct PhoneDayTotal: Codable, Equatable {
    /// `YYYY-MM-DD` in the Mac's time zone.
    var date: String
    var activeSeconds: Double
}

/// One stretch of activity. A block the tracking rules redacted carries only what they left: `redaction` is
/// `private` (app, times, category), `other` (times, category) or `other site` (app, times, category).
struct PhoneBlock: Codable, Equatable {
    var id: Int64
    var start: Date
    var end: Date
    var app: String?
    var title: String?
    var url: String?
    var repo: String?
    var branch: String?
    var ticket: String?
    var category: String?
    var project: String?
    var projectGuessed: Bool
    var summary: String?
    /// The last Claude prompt when "Store last prompt" is on, else the text typed around the cursor when that is on.
    var excerpt: String?
    var redaction: String?
}

struct PhoneActivity: Codable, Equatable {
    var from: Date
    var to: Date
    var totals: PhoneActivityTotals
    var days: [PhoneDayTotal]
    var blocks: [PhoneBlock]
}

// MARK: GitHub

struct PhonePR: Codable, Equatable {
    var url: String
    var number: Int
    var title: String
    var repo: String
    var isDraft: Bool
    /// `open`, `merged` or `closed`.
    var state: String
    var updated: Date
    /// `approved`, `changes_requested` or `required`.
    var review: String?
    /// `passed`, `failed`, `running` or `none`.
    var checks: String
    var author: String?
    var additions: Int
    var deletions: Int
    var comments: Int
    var labels: [String]
    var ticket: String?
}

struct PhoneGitHub: Codable, Equatable {
    var enabled: Bool
    var refreshedAt: Date?
    /// `created`, `review_requested`, `assigned`, `mentioned`.
    var prs: [String: [PhonePR]]
    /// Why the last refresh did not fully succeed.
    var error: String?
}

// MARK: Chat

struct PhoneChatScope: Codable, Equatable {
    /// `general`, `meeting`, `notes`, `activity_block`, `day` or `week`.
    var kind: String
    var meetingId: Int64?
    var blockId: Int64?
    /// `day` and `week`: any `YYYY-MM-DD` inside it. `activity_block`: the block's day.
    var date: String?
    var from: Date?
    var to: Date?
}

struct PhoneChatMessage: Codable, Equatable {
    /// `user` or `assistant`.
    var role: String
    var text: String
}

struct PhoneChatRequest: Codable, Equatable {
    var scope: PhoneChatScope
    /// The conversation so far; the last one is the question and must be from the user.
    var messages: [PhoneChatMessage]
}

struct PhoneCitation: Codable, Equatable {
    var meetingId: Int64
    var title: String
    var seconds: Double?
}

/// One line of the `POST /v1/chat` stream.
struct PhoneChatEvent: Codable, Equatable {
    /// `token`, `tool`, `citations`, `done` or `error`.
    var type: String
    /// `token`: the text added since the last token. `done`: the whole answer.
    var text: String?
    /// `tool`: a note of the lookup the answer used.
    var note: String?
    var citations: [PhoneCitation]?
    /// `error`: why there is no answer.
    var message: String?

    static func token(_ text: String) -> Self { Self(type: "token", text: text) }
    static func tool(_ note: String) -> Self { Self(type: "tool", note: note) }
    static func citations(_ citations: [PhoneCitation]) -> Self { Self(type: "citations", citations: citations) }
    static func done(_ text: String) -> Self { Self(type: "done", text: text) }
    static func failed(_ message: String) -> Self { Self(type: "error", message: message) }
}

// MARK: Pairing

/// What the QR code and the typed code carry: where the Mac listens and a one-time key. The key is a TLS pre-shared
/// key under the identity `id`; it only works for `POST /v1/pair`, which hands out the device's own key.
struct PhonePairing: Equatable {
    static let keyLength = 16
    static let idLength = 4

    var host: String
    var port: Int
    var id: String
    var key: Data

    var url: URL {
        var components = URLComponents()
        components.scheme = PhoneAPI.pairingScheme
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)),
                                 URLQueryItem(name: "id", value: id), URLQueryItem(name: "key", value: Base64.urlEncode(key))]
        return components.url!
    }

    init(host: String, port: Int, id: String, key: Data) {
        self.host = host
        self.port = port
        self.id = id
        self.key = key
    }

    init?(url: URL) {
        guard url.scheme == PhoneAPI.pairingScheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let host = value("host"), !host.isEmpty, let port = value("port").flatMap(Int.init), (1...65535).contains(port),
              let id = value("id"), Self.isValid(id: id), let key = value("key").flatMap(Base64.decode),
              key.count == Self.keyLength else { return nil }
        self.init(host: host, port: port, id: id.lowercased(), key: key)
    }

    /// The id and key as 32 letters and digits in groups of four, for typing on the phone; the host and port are
    /// shown next to it.
    var manualCode: String {
        let text = Base32.encode(Data(Self.idBytes(id) ?? []) + key)
        return stride(from: 0, to: text.count, by: 4).map { String(text.dropFirst($0).prefix(4)) }.joined(separator: "-")
    }

    init?(manualCode: String, host: String, port: Int) {
        let letters = manualCode.uppercased().filter { $0.isLetter || $0.isNumber }
        guard let bytes = Base32.decode(letters), bytes.count == Self.idLength + Self.keyLength else { return nil }
        self.init(host: host, port: port, id: bytes.prefix(Self.idLength).map { String(format: "%02x", $0) }.joined(),
                  key: Data(bytes.dropFirst(Self.idLength)))
    }

    static func isValid(id: String) -> Bool { idBytes(id) != nil }

    private static func idBytes(_ id: String) -> [UInt8]? {
        guard id.count == idLength * 2, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        return stride(from: 0, to: id.count, by: 2).compactMap { UInt8(id.dropFirst($0).prefix(2), radix: 16) }
    }
}

struct PhonePairRequest: Codable, Equatable {
    var deviceName: String
}

/// The answer to `POST /v1/pair`: the device's own key and where the Mac listens for everything else.
struct PhonePairResult: Codable, Equatable {
    var deviceId: String
    /// Base64 of the 32-byte TLS pre-shared key, the identity being `deviceId`.
    var key: String
    var serverName: String
    var host: String
    var port: Int
    var apiVersion: Int
}

enum Base64 {
    static func urlEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Standard or URL-safe, with or without padding.
    static func decode(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base)
    }
}

enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func encode(_ data: Data) -> String {
        var result = "", buffer = 0, bits = 0
        for byte in data {
            buffer = buffer << 8 | Int(byte)
            bits += 8
            while bits >= 5 {
                result.append(alphabet[buffer >> (bits - 5) & 31])
                bits -= 5
                buffer &= (1 << bits) - 1
            }
        }
        if bits > 0 { result.append(alphabet[buffer << (5 - bits) & 31]) }
        return result
    }

    static func decode(_ text: String) -> Data? {
        var bytes: [UInt8] = [], buffer = 0, bits = 0
        for character in text {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = buffer << 5 | value
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8(buffer >> (bits - 8) & 255))
                bits -= 8
                buffer &= (1 << bits) - 1
            }
        }
        return Data(bytes)
    }
}
