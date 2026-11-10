import AppKit
import SwiftUI

/// Which apps, websites and categories are kept, made private or removed.
struct PrivacySettingsView: View {
    @ObservedObject var tracker: ActivityTracker
    @ObservedObject var projects: ActivityProjectsModel
    @AppStorage(ActivitySettings.removeBlockedKey) private var removeBlocked = false
    @AppStorage(ActivitySettings.appModeKey) private var appMode = ActivitySettings.ListMode.allExceptBlocked
    @AppStorage(ActivitySettings.siteModeKey) private var siteMode = ActivitySettings.ListMode.allExceptBlocked
    @AppStorage(ActivitySettings.nonWorkKey) private var nonWork = ActivitySettings.NonWork.keep
    @State private var rulesChanged = false
    @State private var applied: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Apps and websites", footer: "The blocklist wins over the allowlist. Blocked apps and websites keep only the "
                            + "app and the times and show as Private; apps outside the allowlist show as Other with only the times, so "
                            + "day totals still add up. Excluded categories apply once Apple Intelligence has categorised a block.") {
                SettingsRow("Apps") {
                    Picker("Apps", selection: changing($appMode)) {
                        Text("All apps except blocked").tag(ActivitySettings.ListMode.allExceptBlocked)
                        Text("Only allowed apps").tag(ActivitySettings.ListMode.onlyAllowed)
                    }
                    .labelsHidden().fixedSize()
                }
                Divider().padding(.leading, 14)
                SettingsRow("Websites", detail: "Browsers on a website outside the allowlist keep only the app and the times.") {
                    Picker("Websites", selection: changing($siteMode)) {
                        Text("All websites except blocked").tag(ActivitySettings.ListMode.allExceptBlocked)
                        Text("Only allowed websites").tag(ActivitySettings.ListMode.onlyAllowed)
                    }
                    .labelsHidden().fixedSize()
                }
                Divider().padding(.leading, 14)
                SettingsRow("Remove blocked activity completely", detail: "Deletes blocked apps and websites, websites outside the "
                            + "allowlist and excluded categories instead of keeping them as private.") {
                    Toggle("Remove blocked activity completely", isOn: changing($removeBlocked)).labelsHidden().toggleStyle(.switch)
                }
                if rulesChanged || applied != nil {
                    Divider().padding(.leading, 14)
                    SettingsRow("Existing activity", detail: applied.map { "\($0) block\($0 == 1 ? "" : "s") updated." }
                                ?? "Blocks already recorded are unchanged until you apply.") {
                        Button("Apply to Existing Activity") {
                            applied = projects.applyRules(ActivitySettings(.standard), tracker: tracker)
                            rulesChanged = false
                        }
                        .disabled(!rulesChanged)
                    }
                }
            }
            SettingsSection("Allowed", footer: "Used for apps or websites set to Only allowed. A browser that is not an allowed app still "
                            + "counts on an allowed website.") {
                AccessListEditor(tracker: tracker, appsKey: ActivitySettings.allowedAppsKey, apps: tracker.settings.allowedApps,
                                 sitesKey: ActivitySettings.allowedSitesKey, sites: tracker.settings.allowedSites, presets: true) { rulesChanged = true; applied = nil }
            }
            SettingsSection("Blocked", footer: "Titles, addresses, repositories and typed text are never stored for these. A website "
                            + "covers its subdomains; *.example.com covers only the subdomains.") {
                AccessListEditor(tracker: tracker, appsKey: ActivitySettings.excludedKey, apps: tracker.settings.blockedApps,
                                 sitesKey: ActivitySettings.blockedSitesKey, sites: tracker.settings.blockedSites, presets: false) { rulesChanged = true; applied = nil }
            }
            SettingsSection("Excluded categories", footer: "Blocks Apple Intelligence puts in these categories keep only the app, "
                            + "the times and the category, and show as Private in the timeline.") {
                FlowLayout(spacing: 4) {
                    ForEach(ActivityCategory.allCases, id: \.self) { category in
                        let excluded = tracker.settings.excludedCategories.contains(category)
                        Button { toggle(category) } label: {
                            Label(category.label, systemImage: excluded ? "eye.slash" : "eye").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(PillButtonStyle(selected: excluded))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            SettingsSection("Non-work activity", footer: "Apple Intelligence decides from the app, title, address, your projects, "
                            + "repositories and tickets; entertainment is never work. Right-click a block in Activity and choose This Is "
                            + "Work or This Isn\u{2019}t Work to decide for its website or app; your choice beats allowed apps and "
                            + "websites, which beat Apple Intelligence.") {
                SettingsRow("Non-work activity", detail: "Fold into Other keeps only the times, so day totals still add up.") {
                    Picker("Non-work activity", selection: changing($nonWork)) {
                        ForEach(ActivitySettings.NonWork.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                ForEach(workRules, id: \.entry) { rule in
                    Divider().padding(.leading, 14)
                    SettingsRow(rule.entry, detail: rule.label) {
                        Button {
                            tracker.remove(rule.entry, fromListAt: rule.key)
                            rulesChanged = true
                            applied = nil
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var workRules: [(entry: String, label: String, key: String)] {
        let settings = tracker.settings
        return settings.workSites.map { ($0, "Work website", ActivitySettings.workSitesKey) }
            + settings.workApps.map { ($0, "Work app", ActivitySettings.workAppsKey) }
            + settings.nonWorkSites.map { ($0, "Not a work website", ActivitySettings.nonWorkSitesKey) }
            + settings.nonWorkApps.map { ($0, "Not a work app", ActivitySettings.nonWorkAppsKey) }
    }

    /// A binding that also marks the rules as changed, so existing activity can be updated.
    private func changing<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: {
            binding.wrappedValue = $0
            rulesChanged = true
            applied = nil
        })
    }

    private func toggle(_ category: ActivityCategory) {
        let excluded = tracker.settings.excludedCategories
        tracker.setExcludedCategories(excluded.contains(category) ? excluded.filter { $0 != category }
                                      : ActivityCategory.allCases.filter { excluded.contains($0) || $0 == category })
        rulesChanged = true
        applied = nil
    }
}

/// The apps and websites of one list, with an app picker, a validated website field and, for the allowlist, presets.
private struct AccessListEditor: View {
    @ObservedObject var tracker: ActivityTracker
    let appsKey: String
    let apps: [String]
    let sitesKey: String
    let sites: [String]
    let presets: Bool
    let changed: () -> Void
    @State private var newApp = ""
    @State private var newSite = ""

    var body: some View {
        header("Apps")
        ForEach(apps, id: \.self) { app in
            entry(app, icon: InstalledApps.icon(for: app), symbol: "app.dashed") { set(apps.filter { $0 != app }, appsKey) }
        }
        HStack(spacing: 6) {
            Menu("Add App") {
                ForEach(InstalledApps.all.filter { app in !apps.contains { $0.caseInsensitiveCompare(app.name) == .orderedSame } }) { app in
                    Button { add(app.name, appsKey) } label: { Label { Text(app.name) } icon: { Image(nsImage: app.icon) } }
                }
            }
            .fixedSize()
            TextField("Name or bundle ID", text: $newApp).textFieldStyle(.roundedBorder).onSubmit(addApp)
            Button("Add", action: addApp).disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        Divider().padding(.leading, 14)
        header("Websites")
        ForEach(sites, id: \.self) { site in
            entry(site, icon: nil, symbol: "globe") { set(sites.filter { $0 != site }, sitesKey) }
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("github.com or *.atlassian.net", text: $newSite).textFieldStyle(.roundedBorder).onSubmit(addSite)
                Button("Add", action: addSite).disabled(normalizedSite == nil)
            }
            if !newSite.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(normalizedSite.map { "Adds \($0)" } ?? "Not a website address").font(.caption).foregroundStyle(.secondary)
            }
            if presets {
                HStack(spacing: 4) {
                    ForEach(HostPattern.presets, id: \.name) { preset in
                        Button { add(preset.pattern, sitesKey) } label: { Label(preset.name, systemImage: "plus") }
                            .buttonStyle(PillButtonStyle(selected: false))
                            .disabled(sites.contains(preset.pattern))
                            .help(preset.pattern)
                    }
                }
                .padding(.leading, -10)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var normalizedSite: String? { HostPattern.normalized(newSite) }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
    }

    private func entry(_ title: String, icon: NSImage?, symbol: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
            }
            Text(title)
            Spacer()
            Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private func addApp() {
        let name = newApp.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        add(name, appsKey)
        newApp = ""
    }

    private func addSite() {
        guard let site = normalizedSite else { return }
        add(site, sitesKey)
        newSite = ""
    }

    private func add(_ entry: String, _ key: String) {
        tracker.add(entry, toListAt: key)
        changed()
    }

    private func set(_ list: [String], _ key: String) {
        tracker.setList(list, forKey: key)
        changed()
    }
}

/// The apps that can be picked: the running ones and those in the Applications folders.
@MainActor
enum InstalledApps {
    struct App: Identifiable {
        let name: String
        let bundle: String?
        let icon: NSImage
        var id: String { name }
    }

    static var all: [App] {
        if let cached { return cached }
        let workspace = NSWorkspace.shared
        var apps: [String: App] = [:]
        for app in workspace.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName, let url = app.bundleURL else { continue }
            apps[name] = App(name: name, bundle: app.bundleIdentifier, icon: app.icon ?? workspace.icon(forFile: url.path))
        }
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for folder in folders {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where file.hasSuffix(".app") {
                let name = String(file.dropLast(4))
                guard apps[name] == nil else { continue }
                let path = folder + "/" + file
                apps[name] = App(name: name, bundle: Bundle(path: path)?.bundleIdentifier, icon: workspace.icon(forFile: path))
            }
        }
        let sorted = apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cached = sorted
        return sorted
    }

    private static var cached: [App]?

    static func icon(for entry: String) -> NSImage? {
        all.first { [$0.name, $0.bundle].contains { $0?.caseInsensitiveCompare(entry) == .orderedSame } }?.icon
    }
}
