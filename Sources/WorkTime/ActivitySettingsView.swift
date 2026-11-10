import AppKit
import SwiftUI

/// The projects and their rules, as edited in Settings.
@MainActor
final class ActivityProjectsModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var rules: [ProjectRule] = []
    @Published var storedPrompts = 0
    var store: MeetingStore?

    func refresh() {
        projects = (try? store?.projects()) ?? projects
        rules = (try? store?.rules()) ?? rules
        storedPrompts = (try? store?.storedPromptCount()) ?? storedPrompts
    }

    /// The number of blocks that had a prompt, nil when clearing failed.
    func clearPrompts(_ tracker: ActivityTracker) -> Int? {
        var removed: Int?
        perform { removed = try tracker.clearStoredPrompts() }
        return removed
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
        return count + tracker.backfillLinks() + tracker.reevaluateGuesses()
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
    @AppStorage(ActivitySettings.promptsKey) private var storePrompts = false
    @AppStorage(ActivitySettings.typingKey) private var typing = false
    @AppStorage(ActivitySettings.classifyKey) private var classify = true
    @AppStorage(ActivitySettings.idleKey) private var idleSeconds = 120.0
    @AppStorage(ActivitySettings.retentionKey) private var retentionDays = 90
    @State private var confirmingDeleteAll = false
    @State private var offeringPromptDeletion = false
    @State private var confirmingClearPrompts = false
    @State private var clearedPrompts: Int?
    @StateObject private var plugin = ClaudePluginModel()

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
                SettingsRow("Store last prompt", detail: "Keeps the first 120 characters of the prompt you last sent, on your Mac only") {
                    Toggle("Store last prompt", isOn: promptSwitch).labelsHidden().toggleStyle(.switch).disabled(!claude)
                }
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
            }
            SettingsSection("Stored activity", footer: nil) {
                if !storePrompts, projects.storedPrompts > 0 || clearedPrompts != nil {
                    SettingsRow("Stored prompts", detail: clearedPrompts.map { "Removed from \($0) block\($0 == 1 ? "" : "s")." }
                                ?? "\(projects.storedPrompts) block\(projects.storedPrompts == 1 ? " still contains a prompt" : "s still contain prompts")") {
                        Button("Clear stored prompts\u{2026}") { confirmingClearPrompts = true }.disabled(projects.storedPrompts == 0)
                    }
                    Divider().padding(.leading, 14)
                }
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
            .onAppear { projects.refresh() }
            .alert("Also delete prompts already stored?", isPresented: $offeringPromptDeletion) {
                Button("Delete", role: .destructive) { clearPrompts() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("\(projects.storedPrompts) block\(projects.storedPrompts == 1 ? " still contains a prompt" : "s still contain prompts").")
            }
            .alert("Clear stored prompts?", isPresented: $confirmingClearPrompts) {
                Button("Clear", role: .destructive) { clearPrompts() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The prompt is removed from \(projects.storedPrompts) block\(projects.storedPrompts == 1 ? "" : "s"). Sessions, repositories and branches stay.")
            }
            .alert("Delete all activity?", isPresented: $confirmingDeleteAll) {
                Button("Delete", role: .destructive) { projects.deleteAllActivity(tracker) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every tracked block is removed from the database. Projects and rules stay.")
            }
            SettingsSection("Claude Code plugin", footer: "The plugin reports exactly when each Claude Code session is working and which one "
                            + "you are typing in, and lets Claude read your activity, time report and meetings. It installs from the GitHub "
                            + "repository \(ClaudePlugin.githubSource), so it gets what is pushed to main. Everything stays on this Mac; "
                            + "prompt text is not kept. New Claude Code sessions pick it up.") {
                pluginRows
            }
            .onAppear { plugin.refresh() }
        }
    }

    private var accessibilityDetail: String {
        if !enabled { return "Off. Turn on to start; macOS then asks for Accessibility access." }
        return tracker.accessibilityGranted ? "On \u{2014} window titles are read through Accessibility."
            : "Allow WorkTime under Privacy & Security \u{203A} Accessibility to read window titles."
    }

    private var classifyDetail: String {
        let what = "Labels finished blocks on this Mac with a category, a few words and a project guess; rules and your own choices win."
        return ActivityClassifier.isAvailable ? what : what + " Apple Intelligence is not available right now."
    }

    @ViewBuilder private var pluginRows: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let status = ClaudePlugin.status(cli: plugin.cli, installed: plugin.installed, lastEvent: ClaudeInbox.lastWrite(at: AppPaths.claudeInbox))
            SettingsRow(ClaudePlugin.statusText(status, now: context.date), detail: pluginDetail(status)) {
                if plugin.running { ProgressView().controlSize(.small) }
                if plugin.installed {
                    Button("Remove Plugin") { plugin.remove() }.disabled(plugin.running || plugin.cli == nil)
                } else {
                    Button("Install Plugin") { plugin.install(fromLocal: false) }.disabled(plugin.running || plugin.cli == nil)
                }
            }
        }
        if !plugin.installed, let checkout = plugin.localCheckout {
            Divider().padding(.leading, 14)
            SettingsRow("Install from local folder", detail: "For development: \(checkout.path)") {
                Button("Install from Folder") { plugin.install(fromLocal: true) }.disabled(plugin.running || plugin.cli == nil)
            }
        }
        Divider().padding(.leading, 14)
        SettingsRow("Install by hand", detail: "Type these in Claude Code.") {
            Button("Copy Install Commands") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ClaudePlugin.slashCommands, forType: .string)
            }
        }
        if let output = plugin.output {
            Divider().padding(.leading, 14)
            ScrollView {
                Text(output).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func pluginDetail(_ status: ClaudePlugin.Status) -> String {
        switch status {
        case .cliMissing: return "Install Claude Code, or copy the commands below into it."
        case .notInstalled: return "Install it for exact Claude session tracking; without it sessions are guessed from their transcripts."
        case .installed:
            guard let source = plugin.source else { return "Sessions are tracked from the plugin\u{2019}s events." }
            return source.hasPrefix("/") ? "From the local folder \(source)" : "From GitHub (\(source))"
        }
    }

    /// Turning it off takes effect at once and offers to delete what is stored.
    private var promptSwitch: Binding<Bool> {
        Binding(get: { storePrompts }, set: {
            storePrompts = $0
            clearedPrompts = nil
            projects.refresh()
            if !$0, projects.storedPrompts > 0 { offeringPromptDeletion = true }
        })
    }

    private func clearPrompts() {
        clearedPrompts = projects.clearPrompts(tracker)
    }

    private func toggleRow(_ title: String, _ value: Binding<Bool>) -> some View {
        SettingsRow(title) { Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch) }
    }
}
