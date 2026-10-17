import AppKit
import SwiftUI

/// The projects and their rules, as edited in Settings.
@MainActor
final class ActivityProjectsModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var rules: [ProjectRule] = []
    var store: MeetingStore?

    func refresh() {
        projects = (try? store?.projects()) ?? projects
        rules = (try? store?.rules()) ?? rules
    }

    func add(_ name: String) { perform { try store?.addProject(name) } }
    func delete(_ project: Project) { perform { try store?.deleteProject(project.id) } }
    func addRule(_ field: RuleField, _ pattern: String, to project: Project) {
        perform { try store?.addRule(project: project.id, field: field, pattern: pattern) }
    }
    func deleteRule(_ rule: ProjectRule) { perform { try store?.deleteRule(rule.id) } }

    func deleteAllActivity(_ tracker: ActivityTracker) {
        tracker.discard { _ in true }
        perform { try store?.deleteAll() }
    }

    /// Applies the app and website rules and the excluded categories to what is already stored. The open block is
    /// written and forgotten first, so the tracker does not write its old details back.
    func applyRules(_ settings: ActivitySettings, tracker: ActivityTracker) -> Int {
        tracker.flush()
        var count = 0
        perform { count = try store?.applyRules(settings) ?? 0 }
        return count
    }

    func setColor(_ color: String, of project: Project) {
        var project = project
        project.color = color
        perform { try store?.updateProject(project) }
    }

    private func perform(_ body: () throws -> Void) {
        do { try body() } catch { NSAlert(error: error).runModal() }
        refresh()
    }
}

struct ActivitySettingsView: View {
    @ObservedObject var tracker: ActivityTracker
    @ObservedObject var projects: ActivityProjectsModel
    @AppStorage(ActivitySettings.enabledKey) private var enabled = false
    @AppStorage(ActivitySettings.pausedKey) private var paused = false
    @AppStorage(ActivitySettings.titlesKey) private var titles = true
    @AppStorage(ActivitySettings.urlsKey) private var urls = true
    @AppStorage(ActivitySettings.gitKey) private var git = true
    @AppStorage(ActivitySettings.claudeKey) private var claude = true
    @AppStorage(ActivitySettings.typingKey) private var typing = false
    @AppStorage(ActivitySettings.classifyKey) private var classify = true
    @AppStorage(ActivitySettings.idleKey) private var idleSeconds = 120.0
    @AppStorage(ActivitySettings.retentionKey) private var retentionDays = 90
    @AppStorage(ActivitySettings.removeBlockedKey) private var removeBlocked = false
    @AppStorage(ActivitySettings.appModeKey) private var appMode = ActivitySettings.ListMode.allExceptBlocked
    @AppStorage(ActivitySettings.siteModeKey) private var siteMode = ActivitySettings.ListMode.allExceptBlocked
    @AppStorage(ActivitySettings.nonWorkKey) private var nonWork = ActivitySettings.NonWork.keep
    @State private var newProject = ""
    @State private var rulesChanged = false
    @State private var applied: Int?
    @State private var confirmingDeleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Activity tracking", footer: "Records which app, window, website, repository and Claude session you are in, every "
                            + "5 seconds while you are active. Everything stays in the local database; nothing is uploaded.") {
                SettingsRow("Track activity", detail: accessibilityDetail) {
                    if enabled, !tracker.accessibilityGranted {
                        Button("Open Settings") { Permissions.openAccessibilitySettings() }
                    }
                    Toggle("Track activity", isOn: Binding(get: { enabled }, set: { tracker.setEnabled($0) })).labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                SettingsRow("Paused", detail: "Nothing is recorded while paused; also in the menu bar menu.") {
                    Toggle("Paused", isOn: $paused).labelsHidden().toggleStyle(.switch).disabled(!enabled)
                }
            }
            SettingsSection("Capture", footer: "Browser addresses are read through Automation (macOS asks once per browser; "
                            + "query strings are never stored). Repositories are the folders under ~/git matched against window titles.") {
                toggleRow("Window titles", $titles)
                Divider().padding(.leading, 14)
                toggleRow("Browser addresses", $urls)
                Divider().padding(.leading, 14)
                toggleRow("Git repository and branch", $git)
                Divider().padding(.leading, 14)
                toggleRow("Claude Code sessions", $claude)
                Divider().padding(.leading, 14)
                SettingsRow("Text you\u{2019}re writing", detail: "Up to 300 characters around the cursor, kept once you pause for 5 seconds. "
                            + "Password fields and blocked apps are never read.") {
                    Toggle("Text you\u{2019}re writing", isOn: $typing).labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                SettingsRow("Categorise with Apple Intelligence", detail: classifyDetail) {
                    Toggle("Categorise with Apple Intelligence", isOn: $classify).labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                SettingsRow("Away after") {
                    Picker("Away after", selection: $idleSeconds) {
                        ForEach(ActivitySettings.idleChoices, id: \.self) { Text(ActivityLogic.hoursText($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider().padding(.leading, 14)
                SettingsRow("Keep activity for") {
                    Picker("Keep activity for", selection: $retentionDays) {
                        ForEach(ActivitySettings.retentionChoices, id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider().padding(.leading, 14)
                SettingsRow("Delete all activity", detail: "Removes every block and the Apple Intelligence cache.") {
                    Button("Delete All Activity\u{2026}") { confirmingDeleteAll = true }
                }
            }
            .alert("Delete all activity?", isPresented: $confirmingDeleteAll) {
                Button("Delete", role: .destructive) { projects.deleteAllActivity(tracker) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every tracked block is removed from the database. Projects and rules stay.")
            }
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
            SettingsSection("Projects", footer: "A block takes the project of the first rule that matches its repository, website, app or "
                            + "ticket prefix. Click a block in the Activity view to choose a project by hand or add a rule.") {
                ForEach(projects.projects) { project in
                    ProjectSettingsRow(project: project, rules: projects.rules.filter { $0.projectID == project.id }, model: projects)
                    Divider().padding(.leading, 14)
                }
                HStack {
                    TextField("New project", text: $newProject).textFieldStyle(.roundedBorder).onSubmit(addProject)
                    Button("Add", action: addProject).disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var accessibilityDetail: String {
        if !enabled { return "Off. Turn on to start; macOS then asks for Accessibility access." }
        return tracker.accessibilityGranted ? "On \u{2014} window titles are read through Accessibility."
            : "Allow Meeting Recorder under Privacy & Security \u{203A} Accessibility to read window titles."
    }

    private var classifyDetail: String {
        let what = "Labels finished blocks on this Mac with a category, a few words and a project guess; rules and your own choices win."
        return ActivityClassifier.isAvailable ? what : what + " Apple Intelligence is not available right now."
    }

    private func toggleRow(_ title: String, _ value: Binding<Bool>) -> some View {
        SettingsRow(title) { Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch) }
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

    private func addProject() {
        projects.add(newProject)
        newProject = ""
    }
}

private struct ProjectSettingsRow: View {
    let project: Project
    let rules: [ProjectRule]
    @ObservedObject var model: ActivityProjectsModel
    @State private var field = RuleField.repo
    @State private var pattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(Project.colors, id: \.self) { color in
                        Button { model.setColor(color, of: project) } label: {
                            Label { Text(color) } icon: { Image(nsImage: swatch(color)) }
                        }
                    }
                } label: {
                    Circle().fill(Color(hex: project.color)).frame(width: 12, height: 12)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Colour")
                Text(project.name)
                Spacer()
                Button { model.delete(project) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Delete the project and its rules")
            }
            ForEach(rules) { rule in
                HStack(spacing: 6) {
                    Text("\(rule.field.label): \(rule.pattern)")
                    Spacer()
                    Button { model.deleteRule(rule) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.tertiary)
                        .help("Remove this rule")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
            }
            HStack(spacing: 6) {
                Picker("Field", selection: $field) {
                    ForEach(RuleField.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                TextField(placeholder, text: $pattern).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add rule", action: add).disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .padding(.leading, 20)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var placeholder: String {
        switch field {
        case .repo: return "finq.api"
        case .host: return "github.com"
        case .app: return "Xcode"
        case .ticket: return "QDLY"
        }
    }

    private func add() {
        model.addRule(field, pattern, to: project)
        pattern = ""
    }

    private func swatch(_ hex: String) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(Color(hex: hex)).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
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
