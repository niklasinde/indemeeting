import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

let sidebarTests: [(name: String, run: () throws -> Void)] = [
    ("sidebar lists Meetings above Activity, GitHub, Chat and Claude API", {
        check(SidebarSection.allCases.map(\.title) == ["Meetings", "Activity", "GitHub", "Chat", "Claude API"],
              "order \(SidebarSection.allCases.map(\.title))")
        check(SidebarSection.allCases.filter(\.opensWindow) == [.chat, .claudeAPI], "chat and Claude API open their windows")
    }),

    ("the sidebar opens on Meetings, and Activity or GitHub replace it", {
        check(SidebarLogic.defaultSection == .meetings, "default section")
        check(SidebarLogic.section(activity: false, gitHub: false) == .meetings, "nothing shown")
        check(SidebarLogic.section(activity: true, gitHub: false) == .activity, "activity")
        check(SidebarLogic.section(activity: false, gitHub: true) == .gitHub, "github")
    }),

    ("sidebar visibility is stored under its own key and defaults to shown", {
        let suite = "sidebar-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(defaults.bool(forKey: SidebarLogic.hiddenKey) == false, "shown when nothing is stored")
        defaults.set(true, forKey: SidebarLogic.hiddenKey)
        check(UserDefaults(suiteName: suite)!.bool(forKey: SidebarLogic.hiddenKey), "hidden state survives a reopen")
        check(SidebarLogic.toggleTitle(hidden: true) == "Show Sidebar", "title while hidden")
        check(SidebarLogic.toggleTitle(hidden: false) == "Hide Sidebar", "title while shown")
    }),
]
