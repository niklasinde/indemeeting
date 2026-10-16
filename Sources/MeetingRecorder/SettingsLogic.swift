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
