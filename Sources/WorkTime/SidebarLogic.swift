import Foundation

/// The sections of the main window's sidebar, top to bottom. Chat, Claude API and Agent open their own windows.
enum SidebarSection: String, CaseIterable, Identifiable {
    case meetings, activity, gitHub, chat, claudeAPI, agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetings: return "Meetings"
        case .activity: return "Activity"
        case .gitHub: return "GitHub"
        case .chat: return "Chat"
        case .claudeAPI: return "Claude API"
        case .agent: return "Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .meetings: return "waveform"
        case .activity: return "clock"
        case .gitHub: return "arrow.triangle.branch"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .claudeAPI: return "sparkles"
        case .agent: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var help: String {
        switch self {
        case .meetings: return "Your meetings, by day"
        case .activity: return "What you worked on, by day and week"
        case .gitHub: return "Your pull requests, read through the GitHub CLI"
        case .chat: return "Ask about your meetings and work (\u{2318}\u{21E7}A)"
        case .claudeAPI: return "Chat with Claude through the Anthropic API, with your own key"
        case .agent: return "An agent that reads, searches and edits code in a folder, with your API key"
        }
    }

    var opensWindow: Bool { [.chat, .claudeAPI, .agent].contains(self) }
}

enum SidebarLogic {
    static let defaultSection = SidebarSection.meetings
    /// The stored sidebar state: true while the sidebar is hidden.
    static let hiddenKey = "sidebarHidden"

    static func section(activity: Bool, gitHub: Bool) -> SidebarSection {
        if activity { return .activity }
        if gitHub { return .gitHub }
        return defaultSection
    }

    static func toggleTitle(hidden: Bool) -> String { hidden ? "Show Sidebar" : "Hide Sidebar" }
}
