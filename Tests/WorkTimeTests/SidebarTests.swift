import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let sidebarTests: [(name: String, run: () throws -> Void)] = [
    ("sidebar lists Meetings above Activity, GitHub, Chat and Agent, with no Claude API row", {
        check(SidebarLogic.pages.map(\.title) == ["Meetings", "Activity", "GitHub", "Chat", "Main"],
              "order \(SidebarLogic.pages.map(\.title))")
        check(SidebarLogic.pinned == [.settings], "Settings sits at the bottom")
        check(SidebarSection.allCases.filter(\.opensWindow) == [.chat], "chat opens its window, Main and Settings are pages")
        check(SidebarSection(rawValue: "claudeAPI") == nil, "the removed Claude API row no longer exists")
        check(SidebarLogic.defaultSection == .meetings, "default section")
    }),

    ("Settings goes back to the page it was opened from", {
        check(SidebarLogic.returnSection(from: .gitHub, to: .settings, saved: .meetings) == .gitHub, "remembers the page left")
        check(SidebarLogic.returnSection(from: .settings, to: .settings, saved: .gitHub) == .gitHub, "reopening Settings keeps it")
        check(SidebarLogic.returnSection(from: .settings, to: .activity, saved: .gitHub) == .gitHub, "leaving keeps it")
        check(SidebarLogic.returnSection(from: .meetings, to: .activity, saved: .gitHub) == .gitHub, "other moves keep it")
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
