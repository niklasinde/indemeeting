import Foundation

/// The sections of the main window's sidebar, top to bottom. Chat and Claude API open their own windows.
enum SidebarSection: String, CaseIterable, Identifiable {
    case meetings, activity, gitHub, sessions, chat, claudeAPI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetings: return "Meetings"
        case .activity: return "Activity"
        case .gitHub: return "GitHub"
        case .sessions: return "Sessions"
        case .chat: return "Chat"
        case .claudeAPI: return "Claude API"
        }
    }

    var systemImage: String {
        switch self {
        case .meetings: return "waveform"
        case .activity: return "clock"
        case .gitHub: return "arrow.triangle.branch"
        case .sessions: return "terminal"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .claudeAPI: return "sparkles"
        }
    }

    var help: String {
        switch self {
        case .meetings: return "Your meetings, by day"
        case .activity: return "What you worked on, by day and week"
        case .gitHub: return "Your pull requests, read through the GitHub CLI"
        case .sessions: return "Every Claude session the app runs, with its chat and the pull request it is on"
        case .chat: return "Ask about your meetings and work (\u{2318}\u{21E7}A)"
        case .claudeAPI: return "Chat with Claude through the Anthropic API, with your own key"
        }
    }

    var opensWindow: Bool { self == .chat || self == .claudeAPI }
}

enum SidebarLogic {
    static let defaultSection = SidebarSection.meetings
    /// The stored sidebar state: true while the sidebar is hidden.
    static let hiddenKey = "sidebarHidden"

    static func section(activity: Bool, gitHub: Bool, sessions: Bool = false) -> SidebarSection {
        if activity { return .activity }
        if gitHub { return .gitHub }
        if sessions { return .sessions }
        return defaultSection
    }

    static func toggleTitle(hidden: Bool) -> String { hidden ? "Show Sidebar" : "Hide Sidebar" }
}
