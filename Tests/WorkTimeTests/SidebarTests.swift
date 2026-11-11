import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let sidebarTests: [(name: String, run: () throws -> Void)] = [
    ("sidebar lists Meetings above Activity, GitHub, Chat, Claude API and Agent", {
        check(SidebarSection.allCases.map(\.title) == ["Meetings", "Activity", "GitHub", "Chat", "Claude API", "Main"],
              "order \(SidebarSection.allCases.map(\.title))")
        check(SidebarSection.allCases.filter(\.opensWindow) == [.chat, .claudeAPI], "chat and Claude API open their windows, Main is a page")
        check(SidebarLogic.defaultSection == .meetings, "default section")
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
