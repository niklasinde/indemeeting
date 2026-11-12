import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let sidebarTests: [(name: String, run: () throws -> Void)] = [
    ("sidebar lists Meetings above Activity, GitHub, Chat and Agent, with no Claude API row", {
        check(SidebarLogic.pages(showChat: true).map(\.title) == ["Meetings", "Activity", "GitHub", "Chat", "Main"],
              "order \(SidebarLogic.pages(showChat: true).map(\.title))")
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

    ("hiding Chat drops its row, falls back to Meetings and leaves it out of the sidebar detail", {
        check(SidebarLogic.pages(showChat: false).map(\.title) == ["Meetings", "Activity", "GitHub", "Main"],
              "order \(SidebarLogic.pages(showChat: false).map(\.title))")
        check(SidebarLogic.visibleSection(.chat, showChat: false) == .meetings, "Chat falls back to Meetings")
        check(SidebarLogic.visibleSection(.chat, showChat: true) == .chat, "shown Chat stays")
        check(SidebarLogic.visibleSection(.gitHub, showChat: false) == .gitHub, "other pages stay")
        check(SidebarLogic.sidebarDetail(showChat: true) == "Meetings, Activity, GitHub, Chat and Main (\u{2303}\u{2318}S)",
              SidebarLogic.sidebarDetail(showChat: true))
        check(SidebarLogic.sidebarDetail(showChat: false) == "Meetings, Activity, GitHub and Main (\u{2303}\u{2318}S)",
              SidebarLogic.sidebarDetail(showChat: false))
    }),

    ("Show Chat is stored under its own key and defaults to on", {
        let suite = "sidebar-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(SidebarLogic.showChatKey == "showChat", "key")
        check(SidebarLogic.chatShown(in: defaults), "shown when nothing is stored")
        defaults.set(false, forKey: SidebarLogic.showChatKey)
        check(!SidebarLogic.chatShown(in: UserDefaults(suiteName: suite)!), "off survives a reopen")
        defaults.set(true, forKey: SidebarLogic.showChatKey)
        check(SidebarLogic.chatShown(in: defaults), "on again")
    }),
]
