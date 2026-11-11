import AppKit
import SwiftUI

/// The Main page of the main window: every agent in a list beside the one picked. Main lives for the whole run of the app,
/// so its transcript stays when the page or the window goes away.
@MainActor
final class AgentHub: ObservableObject {
    static let shared = AgentHub()

    let main = AgentModel(main: true)
    @Published var selected = AgentOverview.mainKey

    /// Set by the main window: brings it forward on the Main page.
    var showPage: (() -> Void)?

    var isMainSelected: Bool { selected == AgentOverview.mainKey }

    func show(_ key: String = AgentOverview.mainKey) {
        selected = key
        showPage?()
    }
}

struct AgentsPage: View {
    @ObservedObject var hub: AgentHub
    @ObservedObject private var writer = AgentStateWriter.shared
    @ObservedObject private var topics = TopicAgentStore.shared
    @AppStorage("agentListHidden") private var listHidden = false

    var body: some View {
        HStack(spacing: 0) {
            if !listHidden {
                AgentList(hub: hub, rows: AgentSessions.sidebar(writer.states(), lastUsed: AgentSessions.lastUsed(AgentSessionStore.all())))
                    .frame(width: 250)
                Divider()
            }
            Group {
                if hub.isMainSelected {
                    AgentView(model: hub.main, listHidden: $listHidden)
                } else if TopicAgents.isKey(hub.selected) {
                    AgentTopicPage(key: hub.selected, listHidden: $listHidden)
                } else {
                    AgentPRPage(key: hub.selected, listHidden: $listHidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { hub.main.loadFiles() }
    }
}

/// The agents: Main first, then the pull requests' and topics' agents, the ones that need you first.
struct AgentList: View {
    @ObservedObject var hub: AgentHub
    let rows: [AgentState]
    @ObservedObject var topics = TopicAgentStore.shared
    @State var creating = false
    @State private var deleting: TopicAgent?

    var body: some View {
        let now = Date()
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.key) { state in
                        Button { hub.selected = state.key } label: { row(state, now: now) }
                            .buttonStyle(.plain)
                            .contextMenu { if let topic = topics.topic(state.key) { menu(topic) } }
                    }
                }
                .padding(8)
            }
            Divider()
            footer
        }
        .background(Color.primary.opacity(0.025))
        .sheet(isPresented: $creating) {
            NewTopicAgentSheet { topic in
                creating = false
                if let topic { hub.selected = topic.key }
            }
        }
        .confirmationDialog("Delete \u{201C}\(deleting?.name ?? "")\u{201D}?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
            Button("Delete Agent and Folder", role: .destructive) {
                if let deleting { topics.delete(deleting.key) }
            }
        } message: {
            Text("Removes the agent from the list and deletes its folder \((deleting?.folder ?? "") as NSString).abbreviatingWithTildeInPath). "
                 + "Claude Code keeps its session transcripts.")
        }
    }

    private var footer: some View {
        HStack {
            Button { creating = true } label: { Label("New Agent", systemImage: "plus") }
                .help("An agent for a support case or other topic, linked to a Jira ticket or Slack thread")
            Spacer()
            if !topics.archived.isEmpty {
                Menu {
                    ForEach(topics.archived) { topic in
                        Button("Unarchive \(topic.name)") { topics.setArchived(topic.key, false) }
                    }
                } label: { Image(systemName: "archivebox") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("\(topics.archived.count) archived topic agent\(topics.archived.count == 1 ? "" : "s")")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func menu(_ topic: TopicAgent) -> some View {
        Button("Archive") { topics.setArchived(topic.key, true) }
        Button("Delete\u{2026}", role: .destructive) { deleting = topic }
    }

    private func row(_ state: AgentState, now: Date) -> some View {
        let need = AgentOverview.need(state)
        let isMain = state.key == AgentOverview.mainKey
        return HStack(alignment: .top, spacing: 8) {
            Circle().fill(Self.color(need)).frame(width: 8, height: 8).padding(.top, 5).help(need.label)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let topic = topics.topic(state.key) { AgentTopicIcon(kind: topic.kind) }
                    Text(isMain ? "Main" : Self.reference(state)).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let updated = state.updatedAt {
                        Text(GitHubLogic.updatedText(updated, now: now)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(isMain ? "Overview of everything" : Self.title(state)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if need != .idle {
                    Text(state.status == .signedOut ? "Signed out of Claude" : need.label).font(.caption2).foregroundStyle(Self.color(need))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(hub.selected == state.key ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
    }

    static func color(_ need: AgentOverview.Need) -> Color {
        switch need {
        case .waiting: return .orange
        case .unseen: return .accentColor
        case .error: return .red
        case .working: return .green
        case .idle: return .secondary.opacity(0.4)
        }
    }

    private static func reference(_ state: AgentState) -> String {
        state.prURL.map(AgentSessions.shortReference) ?? state.title
    }

    private static func title(_ state: AgentState) -> String {
        if state.isTopic {
            let links = [state.jiraKey, state.slackURL.map { _ in "Slack thread" }].compactMap { $0 }
            return links.isEmpty ? "Topic agent" : links.joined(separator: " \u{00B7} ")
        }
        let reference = state.prURL.map { AgentOverview.prTitle($0) } ?? state.title
        let rest = state.title.hasPrefix(reference) ? state.title.dropFirst(reference.count).trimmingCharacters(in: .whitespaces) : state.title
        return rest.isEmpty ? (state.loaded ? "Pull request agent" : "Saved session") : rest
    }
}

/// A pull request's agent on the Main page: the same model as beside the pull request, loaded when it is not yet.
struct AgentPRPage: View {
    let key: String
    @Binding var listHidden: Bool
    @ObservedObject private var agents = PRAgents.shared

    var body: some View {
        if let model = agents.model(for: key) {
            AgentView(model: model, listHidden: $listHidden)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: key) {
                    if let target = GitHubLink.pullRequest(at: key) { _ = await agents.load(target) }
                }
        }
    }
}

struct AgentView: View {
    @ObservedObject var model: AgentModel
    var listHidden: Binding<Bool>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            AgentPanel(model: model)
        }
        .frame(minWidth: 420, minHeight: 440)
    }

    private var isMain: Bool { model.isMain && model.prURL == nil }

    private var header: some View {
        HStack(spacing: 10) {
            if let listHidden {
                Button { listHidden.wrappedValue.toggle() } label: { Image(systemName: "sidebar.squares.left") }
                    .buttonStyle(.borderless)
                    .help(listHidden.wrappedValue ? "Show the agents" : "Hide the agents")
            }
            if let url = model.prURL, let pr = GitHubLink.pullRequest(at: url) {
                Label(AgentSessions.shortReference(url), systemImage: "arrow.triangle.pull").font(.system(size: 15, weight: .medium)).lineLimit(1)
                    .help(url)
                Button { AgentModel.openAgentLink?(pr) } label: { Label("Open PR", systemImage: "arrow.up.forward.square") }
                    .help("Open the pull request page with this agent beside it")
            } else if let topic = model.topic {
                AgentTopicHeader(topic: topic)
            } else {
                Text(isMain ? "Main" : "Agent").font(.system(size: 20, weight: .medium))
                Button { model.chooseFolder() } label: {
                    Label((model.folder as NSString).abbreviatingWithTildeInPath, systemImage: "folder").lineLimit(1).truncationMode(.head)
                }
                .buttonStyle(.borderless)
                .help("The folder the agent works in")
            }
            Spacer()
            if isMain {
                Button { model.catchUp() } label: { Label("Catch up", systemImage: "sparkles") }
                    .disabled(model.busy)
                    .help(AgentLogic.catchUpPrompt)
            }
            AgentSessionsButton(model: model)
            AgentPermissionPicker(model: model)
            AgentModelPicker(model: model)
            AgentNewSessionButton(model: model)
        }
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.vertical, 12)
    }
}

/// The sessions of one agent: the current one, the earlier ones newest first, and those in its folder it has not had.
struct AgentSessionsButton: View {
    @ObservedObject var model: AgentModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { Label("Sessions", systemImage: "clock.arrow.circlepath") }
            .disabled(model.busy)
            .help(model.busy ? "Switch sessions when the agent has finished" : "Pick an earlier session")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AgentSessionList(model: model) { showing = false }
            }
    }
}

struct AgentSessionList: View {
    @ObservedObject var model: AgentModel
    var done: () -> Void = {}
    @State var others: [AgentSessionEntry]?
    @State var showsOthers = false

    var body: some View {
        let now = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if model.sessionID == nil {
                    row(title: "New session", detail: "Not started yet", current: true) {}
                }
                ForEach(model.history) { entry in
                    row(title: entry.title, detail: detail(entry, now: now), current: entry.id == model.sessionID) { pick(entry) }
                        .contextMenu {
                            Button("Remove from List") { model.forget(entry.id) }.disabled(entry.id == model.sessionID)
                        }
                }
                Divider().padding(.vertical, 4)
                if showsOthers {
                    Text("Other sessions in this folder").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 8)
                    if let others {
                        if others.isEmpty {
                            Text("None").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 8)
                        }
                        ForEach(others) { entry in
                            row(title: entry.title, detail: GitHubLogic.updatedText(entry.lastUsed, now: now), current: false) { pick(entry) }
                        }
                    } else {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    }
                } else {
                    Button("Show All Sessions in This Folder") {
                        showsOthers = true
                        Task { others = await model.otherSessions() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(8)
        }
        .frame(width: 340)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pick(_ entry: AgentSessionEntry) {
        model.switchTo(entry)
        done()
    }

    private func detail(_ entry: AgentSessionEntry, now: Date) -> String {
        ([GitHubLogic.updatedText(entry.lastUsed, now: now)] + [entry.model.map(AgentLogic.modelName)].compactMap { $0 })
            .joined(separator: " \u{00B7} ")
    }

    private func row(title: String, detail: String, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).opacity(current ? 1 : 0).padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).truncationMode(.tail)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(current ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AgentModelPicker: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        Picker("Model", selection: $model.model) {
            ForEach(AgentLogic.models, id: \.id) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .fixedSize()
        .help("The Claude model for the next prompt. Auto asks the local Ministral model to pick one.")
    }
}

struct AgentPermissionPicker: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        Picker("Permissions", selection: $model.permissionMode) {
            ForEach(AgentPermissionMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .help("Permissions: \(model.permissionMode.help)")
    }
}

struct AgentNewSessionButton: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        Button("New Session") { model.newSession() }.disabled(model.items.isEmpty && model.sessionID == nil)
    }
}

/// The transcript, the permission prompts and the composer, in the Agent window and beside a pull request.
struct AgentPanel: View {
    @ObservedObject var model: AgentModel
    var gutter = RecordingDetail.gutter
    @State private var height: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            transcript
            composer
        }
        .environment(\.openURL, OpenURLAction { model.open($0) })
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
    }

    private var isMain: Bool { model.isMain && model.prURL == nil }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.items.isEmpty {
                        Text(isMain ? "Main keeps an eye on everything: pull requests, the agents beside them, Slack and meeting action items. "
                                + "Ask what needs you, or have it hand a prompt to a pull request\u{2019}s agent. It only reads unless you ask for more."
                             : model.topic != nil ? "This agent works on one topic in its own folder. It reads the linked Jira ticket and Slack "
                                + "thread and searches both, and drafts replies for you to copy; it cannot post anywhere."
                             : "Ask the agent to read, search or change code in this folder. Type @ to reference a file. Edits and commands ask first.")
                            .foregroundStyle(.secondary)
                        if isMain {
                            Button { model.catchUp() } label: { Label("Catch up", systemImage: "sparkles") }
                                .buttonStyle(.borderedProminent)
                                .help(AgentLogic.catchUpPrompt)
                        }
                    }
                    ForEach(model.items) { item in
                        AgentItemRow(item: item, folder: model.folder) { model.answer(item, allow: $0, always: $1) }
                    }
                    if model.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working\u{2026}").foregroundStyle(.secondary)
                        }
                    }
                    if let problem = model.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, gutter)
                .padding(.vertical, 14)
            }
            .onChange(of: model.items) { proxy.scrollTo("end") }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.mentionMatches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.mentionMatches, id: \.self) { path in
                        Button { model.draft = AgentLogic.insertMention(path, into: model.draft) } label: {
                            Label(path, systemImage: "doc.text")
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(path == model.mentionMatches.first ? Color.primary.opacity(0.07) : .clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10).fill(.background).shadow(radius: 2))
            } else if model.draft.isEmpty && model.items.isEmpty {
                HStack {
                    ForEach(isMain || model.topic != nil ? [] : AgentLogic.quickActions, id: \.title) { action in
                        Button(action.title) { model.draft = action.prompt }.buttonStyle(SuggestionStyle())
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                ChatComposer(text: $model.draft, height: $height, placeholder: "Ask the agent \u{2014} @ to reference a file") { model.submit() }
                    .frame(height: height)
                Button {
                    if model.busy { model.stop() } else { model.send() }
                } label: {
                    Image(systemName: model.busy ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(model.busy || !model.draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.accentColor : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(model.busy ? "Stop" : "Send (Return)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, max(gutter - 14, 6))
        .padding(.bottom, 16)
    }
}

private struct AgentItemRow: View {
    let item: AgentItem
    let folder: String
    let answer: (_ allow: Bool, _ always: Bool) -> Void

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 80)
                if let message = AgentInbox.fromMain(text) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("From Main", systemImage: "sparkles").font(.caption.weight(.medium)).foregroundStyle(.purple)
                        Text(message).textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.12)))
                    .help("Sent by the Main agent, approved by you there")
                } else {
                    Text(text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.15)))
                }
            }
        case .text(let text):
            AnswerText(text: AgentLogic.linkifiedCodeReferences(text, cwd: folder) { FileManager.default.fileExists(atPath: $0) })
        case .tool(let name, let summary, let detail, let result, let isError, let auto, let rule):
            AgentToolRow(name: name, summary: summary, detail: detail, result: result, isError: isError, auto: auto, rule: rule)
        case .permission(let tool, let summary, let detail, let offer, let allowed):
            AgentPermissionRow(tool: tool, summary: summary, detail: detail, offer: offer, allowed: allowed, answer: answer)
        case .status(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        case .signIn:
            Label(LocalizedStringKey(AgentLogic.signInMessage), systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

private struct AgentToolRow: View {
    let name: String
    let summary: String
    let detail: String
    let result: String?
    let isError: Bool
    let auto: Bool
    let rule: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                    Image(systemName: result == nil ? "hourglass" : isError ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(isError ? Color.red : .secondary)
                    Text(AgentLogic.displayName(name)).fontWeight(.medium)
                    Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if auto {
                        Text(rule == nil ? "auto" : "auto \u{00B7} rule")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .help(rule.map { "Allowed without asking by your rule: \($0)" } ?? "Allowed without asking: a read-only command")
                    }
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                AgentCode(text: [detail, result].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }
        }
    }
}

private struct AgentPermissionRow: View {
    let tool: String
    let summary: String
    let detail: String
    let offer: [AgentRule]
    let allowed: Bool?
    let answer: (_ allow: Bool, _ always: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allow \(AgentLogic.displayName(tool))?", systemImage: "hand.raised").font(.callout.weight(.medium))
            if tool == "Bash" {
                AgentCode(text: detail, font: .callout, maxHeight: AgentCode.lines(10, font: .callout))
            } else {
                if !summary.isEmpty {
                    Text(summary).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                if !detail.isEmpty { AgentCode(text: detail) }
            }
            if let allowed {
                Text(allowed ? "Allowed" : "Denied").font(.caption).foregroundStyle(.secondary)
            } else {
                if let always = AgentRules.offer(offer) {
                    Text(always).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let warning = AgentRules.warning(offer) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Allow once") { answer(true, false) }
                    if !offer.isEmpty {
                        Button("Always allow") { answer(true, true) }
                            .help("Saved in Settings \u{203A} Agent, for every agent")
                    }
                    Button("Deny") { answer(false, false) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(allowed == nil ? Color.orange.opacity(0.6) : Color.primary.opacity(0.1)))
    }
}

/// The calls the user chose to always allow, with Remove for each and Remove all.
struct AgentSettingsSection: View {
    @ObservedObject var store: AgentRuleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) { sections }
    }

    @ViewBuilder private var sections: some View {
        SettingsSection("Always allowed", footer: "Saved with Always allow on a permission prompt and used by every agent. A command is "
                        + "allowed when each part that is not read-only starts with one of these; send to agent is always asked.") {
            if store.rules.isEmpty {
                SettingsRow("Nothing yet", detail: "Choose Always allow when an agent asks to run something") {}
            }
            ForEach(Array(store.rules.enumerated()), id: \.element) { index, rule in
                if index > 0 { Divider().padding(.leading, 14) }
                SettingsRow(AgentRules.label(rule), detail: AgentRules.warning([rule]).map { _ in "Runs with any arguments, also destructive ones" }) {
                    if AgentRules.warning([rule]) != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button("Remove") { store.remove(rule) }
                }
            }
            if store.rules.count > 1 {
                Divider().padding(.leading, 14)
                SettingsRow("\(store.rules.count) rules") {
                    Button("Remove all", role: .destructive) { store.removeAll() }
                }
            }
            Divider().padding(.leading, 14)
            AgentAddRuleRow(store: store, builtIn: builtIn)
        }
        SettingsSection("Always allowed (built in)", footer: "What every agent runs without asking. Commands only when every part of the "
                        + "line is one of these; anything the check is unsure about is asked.") {
            if let builtIn {
                DisclosureGroup("\(builtIn.tools.count + 1) tools, \(builtIn.commands.count) commands") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tools: " + (builtIn.tools + ["WorkTime\u{2019}s MCP tools except " + builtIn.alwaysAsk.map(AgentLogic.displayName)
                            .joined(separator: ", ")]).joined(separator: ", "))
                        ForEach(builtIn.lines, id: \.self) { Text($0) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else {
                SettingsRow("Not found", detail: "Build the agent sidecar (npm run build in agent) to see the list") {}
            }
        }
    }

    var builtIn: AgentBuiltIn? = AgentBuiltIn.load(sidecars: AgentLogic.sidecarCandidates(
        environment: ProcessInfo.processInfo.environment, resources: Bundle.main.resourceURL, sourceFile: #filePath))
}

/// Adds a rule by hand: a command prefix typed in, edits in a folder, or one of WorkTime's tools.
private struct AgentAddRuleRow: View {
    @ObservedObject var store: AgentRuleStore
    let builtIn: AgentBuiltIn?
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Add rule", text: $text, prompt: Text("Command, like gh pr view *"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addCommand)
                Button("Add", action: addCommand).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("More") {
                    Button("Edits in a Folder\u{2026}", action: addFolder)
                    if let builtIn {
                        Menu("WorkTime Tool") {
                            ForEach(AgentRules.toolChoices(MCPServer.toolNames, builtIn: builtIn), id: \.self) { tool in
                                Button(AgentLogic.displayName(tool)) { store.add([AgentRule(kind: .tool, value: tool)]) }
                            }
                        }
                    }
                }
                .fixedSize()
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if case .success(let rule) = AgentRules.bashRule(text), let warning = AgentRules.warning([rule]) {
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onChange(of: text) { problem = nil }
    }

    private func addCommand() {
        switch AgentRules.bashRule(text) {
        case .success(let rule):
            store.add([rule])
            text = ""
        case .failure(let error): problem = error.message
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Allow Edits"
        if panel.runModal() == .OK, let url = panel.url { store.add([AgentRule(kind: .edits, value: url.path)]) }
    }
}

private struct AgentCode: View {
    let text: String
    var font: Font.TextStyle = .caption
    var maxHeight: CGFloat = 220

    /// The height of `count` lines of monospaced text in `font`, with the box's padding.
    static func lines(_ count: Int, font: NSFont.TextStyle) -> CGFloat {
        let face = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: font).pointSize, weight: .regular)
        return ceil(face.ascender - face.descender + face.leading) * CGFloat(count) + 16
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(font, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}
