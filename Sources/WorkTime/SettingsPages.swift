import Foundation

/// The pages of Settings, top to bottom.
enum SettingsTab: String, CaseIterable {
    case general = "General"
    case meetings = "Meetings"
    case activity = "Activity"
    case privacy = "Privacy"
    case projects = "Projects"
    case notchBar = "Notch bar"
    case gitHub = "GitHub"
    case jira = "Jira"
    case slack = "Slack"
    case models = "Models"
    case agent = "Agent"
    case iphone = "iPhone"

    static let storageKey = "settingsTab"

    var title: String { self == .notchBar ? "Top notch bar" : rawValue }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .meetings: return "waveform"
        case .activity: return "chart.bar.fill"
        case .privacy: return "hand.raised.fill"
        case .projects: return "folder.fill"
        case .notchBar: return "rectangle.topthird.inset.filled"
        case .gitHub: return "chevron.left.forwardslash.chevron.right"
        case .jira: return "ticket.fill"
        case .slack: return "number"
        case .models: return "cpu.fill"
        case .agent: return "sparkles"
        case .iphone: return "iphone"
        }
    }

    /// The page Settings opens on: the one asked for, else the anchor's, else the last one open, else General.
    static func opening(tab: SettingsTab? = nil, anchor: SettingsAnchor? = nil, stored: String?) -> SettingsTab {
        tab ?? anchor?.tab ?? stored.flatMap(SettingsTab.init) ?? .general
    }
}

/// A section of Settings that can be scrolled to: a downloadable model in Meetings, or the Jira or Slack page.
enum SettingsAnchor: Hashable {
    case whisper
    case ministral
    case speakers
    case jira
    case slack

    var tab: SettingsTab {
        switch self {
        case .whisper, .ministral, .speakers: return .meetings
        case .jira: return .jira
        case .slack: return .slack
        }
    }
}

/// The look of every window: the system's, or always light or dark.
enum AppAppearance: String, CaseIterable {
    case system, light, dark

    static let storageKey = "appAppearance"

    var title: String { rawValue.capitalized }

    /// Whether the app is forced dark or light; nil follows the system.
    var isDark: Bool? {
        switch self {
        case .system: return nil
        case .light: return false
        case .dark: return true
        }
    }

    static func stored(_ defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: storageKey).flatMap(AppAppearance.init) ?? .system
    }
}
