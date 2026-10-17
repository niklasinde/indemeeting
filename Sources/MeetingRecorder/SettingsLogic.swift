import Foundation
import Speech

/// Where a language's on-device speech model stands, as shown in Settings.
enum SpeechModelStatus: Equatable {
    case checking
    case unsupported
    case notDownloaded
    case downloading(Double?)
    case installed
    case failed(String)

    init(_ status: AssetInventory.Status) {
        switch status {
        case .unsupported: self = .unsupported
        case .supported: self = .notDownloaded
        case .downloading: self = .downloading(nil)
        case .installed: self = .installed
        @unknown default: self = .unsupported
        }
    }

    var text: String {
        switch self {
        case .checking: return "Checking\u{2026}"
        case .unsupported: return "Not available on this Mac"
        case .notDownloaded: return "Not downloaded"
        case .downloading(let fraction?): return "Downloading\u{2026} \(ProcessingLogic.percent(fraction))"
        case .downloading(nil): return "Downloading\u{2026}"
        case .installed: return "Installed"
        case .failed(let message): return "Download failed \u{2014} \(message)"
        }
    }

    var canDownload: Bool {
        switch self {
        case .notDownloaded, .failed: return true
        default: return false
        }
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// How ready a step's model is, in a word, for the model overview in Settings.
enum ModelState: Int, Comparable {
    case unavailable
    case notDownloaded
    case downloading
    case checking
    case off
    case ready

    init(_ status: SpeechModelStatus) {
        switch status {
        case .checking: self = .checking
        case .unsupported: self = .unavailable
        case .notDownloaded, .failed: self = .notDownloaded
        case .downloading: self = .downloading
        case .installed: self = .ready
        }
    }

    /// The least ready of several, so a step is ready only when every model it needs is.
    init(all statuses: [SpeechModelStatus]) {
        self = statuses.map(Self.init).min() ?? .unavailable
    }

    init(summary reason: SummaryUnavailable?) {
        switch reason {
        case nil: self = .ready
        case .modelNotReady: self = .downloading
        default: self = .unavailable
        }
    }

    var text: String {
        switch self {
        case .unavailable: return "Not available"
        case .notDownloaded: return "Not downloaded"
        case .downloading: return "Still downloading"
        case .checking: return "Checking\u{2026}"
        case .off: return "Off"
        case .ready: return "Ready"
        }
    }

    static func < (a: ModelState, b: ModelState) -> Bool { a.rawValue < b.rawValue }
}
