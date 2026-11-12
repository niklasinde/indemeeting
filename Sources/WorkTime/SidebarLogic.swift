import Foundation

/// The sections of the main window's sidebar, top to bottom; Settings sits at the bottom. Chat opens its own window.
enum SidebarSection: String, CaseIterable, Identifiable {
    case meetings, activity, gitHub, chat, agent, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetings: return "Meetings"
        case .activity: return "Activity"
        case .gitHub: return "GitHub"
        case .chat: return "Chat"
        case .agent: return "Main"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .meetings: return "waveform"
        case .activity: return "clock"
        case .gitHub: return "arrow.triangle.branch"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .agent: return "chevron.left.forwardslash.chevron.right"
        case .settings: return "gearshape"
        }
    }

    var help: String {
        switch self {
        case .meetings: return "Your meetings, by day"
        case .activity: return "What you worked on, by day and week"
        case .gitHub: return "Your pull requests, read through the GitHub CLI"
        case .chat: return "Ask about your meetings and work (\u{2318}\u{21E7}A)"
        case .agent: return "Your overview agent: what needs you across pull requests, their agents, Slack and meetings"
        case .settings: return "Settings (\u{2318},)"
        }
    }

    var opensWindow: Bool { self == .chat }

    var isPinnedToBottom: Bool { self == .settings }
}

enum SidebarLogic {
    static let defaultSection = SidebarSection.meetings
    /// The stored sidebar state: true while the sidebar is hidden.
    static let hiddenKey = "sidebarHidden"

    static let pages = SidebarSection.allCases.filter { !$0.isPinnedToBottom }
    static let pinned = SidebarSection.allCases.filter(\.isPinnedToBottom)

    /// The page Settings goes back to: the one shown before it opened.
    static func returnSection(from current: SidebarSection, to next: SidebarSection, saved: SidebarSection) -> SidebarSection {
        next == .settings && current != .settings ? current : saved
    }

    static func toggleTitle(hidden: Bool) -> String { hidden ? "Show Sidebar" : "Hide Sidebar" }
}
