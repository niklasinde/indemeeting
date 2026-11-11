import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let sidebarTests: [(name: String, run: () throws -> Void)] = [
    ("sidebar lists Meetings above Activity, GitHub, Chat and Agent, with no Claude API row", {
        check(SidebarSection.allCases.map(\.title) == ["Meetings", "Activity", "GitHub", "Chat", "Main"],
              "order \(SidebarSection.allCases.map(\.title))")
        check(SidebarSection.allCases.filter(\.opensWindow) == [.chat], "chat opens its window, Main is a page")
        check(SidebarSection(rawValue: "claudeAPI") == nil, "the removed Claude API row no longer exists")
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
