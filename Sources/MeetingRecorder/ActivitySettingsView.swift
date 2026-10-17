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

    func applyExcludedCategories(_ settings: ActivitySettings) -> Int {
        var count = 0
        perform { count = try store?.applyExcluded(categories: settings.excludedCategories, remove: settings.removeExcluded) ?? 0 }
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
    @AppStorage(ActivitySettings.removeExcludedKey) private var removeExcluded = false
    @State private var newExcluded = ""
    @State private var newProject = ""
    @State private var categoriesChanged = false
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
                            + "Password fields and excluded apps are never read.") {
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
            SettingsSection("Excluded apps", footer: "Only the app name and time are kept for these; titles, addresses and repositories are not.") {
                ForEach(tracker.settings.excludedApps, id: \.self) { app in
                    SettingsRow(app) {
                        Button { setExcluded(tracker.settings.excludedApps.filter { $0 != app }) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    Divider().padding(.leading, 14)
                }
                HStack {
                    TextField("App name", text: $newExcluded).textFieldStyle(.roundedBorder).onSubmit(addExcluded)
                    Button("Add", action: addExcluded).disabled(newExcluded.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
                Divider().padding(.leading, 14)
                SettingsRow("Remove these blocks completely", detail: "Deletes them instead of keeping them as private.") {
                    Toggle("Remove these blocks completely", isOn: Binding(get: { removeExcluded }, set: {
                        removeExcluded = $0
                        categoriesChanged = true
                        applied = nil
                    }))
                    .labelsHidden().toggleStyle(.switch)
                }
                if categoriesChanged || applied != nil {
                    Divider().padding(.leading, 14)
                    SettingsRow("Existing activity", detail: applied.map { "\($0) block\($0 == 1 ? "" : "s") updated." }
                                ?? "Blocks already categorised are unchanged until you apply.") {
                        Button("Apply to Existing Activity") {
                            applied = projects.applyExcludedCategories(ActivitySettings(.standard))
                            categoriesChanged = false
                        }
                        .disabled(!categoriesChanged || tracker.settings.excludedCategories.isEmpty)
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

    private func setExcluded(_ apps: [String]) {
        tracker.setExcludedApps(apps)
    }

    private func toggle(_ category: ActivityCategory) {
        let excluded = tracker.settings.excludedCategories
        tracker.setExcludedCategories(excluded.contains(category) ? excluded.filter { $0 != category }
                                      : ActivityCategory.allCases.filter { excluded.contains($0) || $0 == category })
        categoriesChanged = true
        applied = nil
    }

    private func addExcluded() {
        let name = newExcluded.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        setExcluded(tracker.settings.excludedApps + [name])
        newExcluded = ""
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
