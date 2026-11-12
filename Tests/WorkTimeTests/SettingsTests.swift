import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let settingsTests: [(name: String, run: () throws -> Void)] = [
    ("Settings lists General first, then the feature pages", {
        let titles = SettingsTab.allCases.map(\.title)
        check(titles == ["General", "Meetings", "Activity", "Privacy", "Projects", "Top notch bar", "GitHub", "Jira", "Slack",
                         "Models", "Agent", "iPhone"], "order \(titles)")
        check(Set(SettingsTab.allCases.map(\.symbol)).count == SettingsTab.allCases.count, "every page has its own symbol")
    }),

    ("Settings opens on the page asked for, else the anchor's, else the last one, else General", {
        check(SettingsTab.opening(stored: nil) == .general, "first time")
        check(SettingsTab.opening(stored: "Privacy") == .privacy, "last page open")
        check(SettingsTab.opening(stored: "Gone") == .general, "a page that no longer exists")
        check(SettingsTab.opening(tab: .models, stored: "Privacy") == .models, "deep link to a page")
        check(SettingsTab.opening(anchor: .slack, stored: "Privacy") == .slack, "deep link to an anchor")
        check(SettingsTab.opening(tab: .models, anchor: .jira, stored: nil) == .models, "the page wins over the anchor")
    }),

    ("every anchor belongs to a page", {
        check(SettingsAnchor.whisper.tab == .meetings && SettingsAnchor.ministral.tab == .meetings
              && SettingsAnchor.speakers.tab == .meetings, "models are downloaded in Meetings")
        check(SettingsAnchor.jira.tab == .jira && SettingsAnchor.slack.tab == .slack, "Jira and Slack have their own page")
    }),

    ("appearance defaults to System and maps to light, dark or the system's", {
        let suite = "settings-tests-appearance"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        check(AppAppearance.stored(defaults) == .system, "default")
        defaults.set("dark", forKey: AppAppearance.storageKey)
        check(AppAppearance.stored(defaults) == .dark, "stored")
        defaults.set("sepia", forKey: AppAppearance.storageKey)
        check(AppAppearance.stored(defaults) == .system, "unknown value")
        defaults.removePersistentDomain(forName: suite)
        check(AppAppearance.allCases.map(\.title) == ["System", "Light", "Dark"], "titles \(AppAppearance.allCases.map(\.title))")
        check(AppAppearance.system.isDark == nil && AppAppearance.light.isDark == false && AppAppearance.dark.isDark == true, "mapping")
    }),
]
