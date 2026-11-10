import AppKit
import SwiftUI

@MainActor
final class AgentWindow {
    static let shared = AgentWindow()

    private(set) var model: AgentModel?
    private var window: AppWindow?
    private var activityFolder: () -> String? = { nil }

    func configure(activityFolder: @escaping () -> String?) {
        self.activityFolder = activityFolder
        let model = AgentModel()
        self.model = model
        window = AppWindow(onClose: { model.stopClient() }) { Self.makeWindow(AgentView(model: model)) }
    }

    func show() {
        guard let model else { return }
        if model.items.isEmpty, let folder = activityFolder() { model.choose(folder: folder) }
        model.loadFiles()
        window?.show()
    }

    static func makeWindow(_ view: AgentView) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Agent"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 820, height: 640))
        return window
    }
}

struct AgentView: View {
    @ObservedObject var model: AgentModel
    @State private var height: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            transcript
            composer
        }
        .frame(minWidth: 600, minHeight: 440)
        .environment(\.openURL, OpenURLAction { model.open($0) })
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Agent").font(.system(size: 20, weight: .medium))
            Button { model.chooseFolder() } label: {
                Label((model.folder as NSString).abbreviatingWithTildeInPath, systemImage: "folder").lineLimit(1).truncationMode(.head)
            }
            .buttonStyle(.borderless)
            .help("The folder the agent works in")
            Spacer()
            if model.sessionID != nil {
                Text("Continuing session").font(.caption).foregroundStyle(.secondary)
            }
            Button("New Session") { model.newSession() }.disabled(model.items.isEmpty && model.sessionID == nil)
        }
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.items.isEmpty {
                        Text("Ask the agent to read, search or change code in this folder. Type @ to reference a file. Edits and commands ask first.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.items) { item in
                        AgentItemRow(item: item, folder: model.folder) { model.answer(item, allow: $0) }
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
                .padding(.horizontal, RecordingDetail.gutter)
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
                    ForEach(AgentLogic.quickActions, id: \.title) { action in
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
        .padding(.horizontal, RecordingDetail.gutter - 14)
        .padding(.bottom, 16)
    }
}

private struct AgentItemRow: View {
    let item: AgentItem
    let folder: String
    let answer: (Bool) -> Void

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.15)))
            }
        case .text(let text):
            AnswerText(text: AgentLogic.linkifiedCodeReferences(text, cwd: folder) { FileManager.default.fileExists(atPath: $0) })
        case .tool(let name, let summary, let detail, let result, let isError):
            AgentToolRow(name: name, summary: summary, detail: detail, result: result, isError: isError)
        case .permission(let tool, let summary, let detail, let allowed):
            AgentPermissionRow(tool: tool, summary: summary, detail: detail, allowed: allowed, answer: answer)
        case .status(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        case .signIn:
            VStack(alignment: .leading, spacing: 8) {
                Label(LocalizedStringKey(AgentLogic.signInMessage), systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout)
                    .textSelection(.enabled)
                Button("Open Settings") { SettingsWindow.shared.show(tab: .models) }
            }
        }
    }
}

private struct AgentToolRow: View {
    let name: String
    let summary: String
    let detail: String
    let result: String?
    let isError: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                    Image(systemName: result == nil ? "hourglass" : isError ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(isError ? Color.red : .secondary)
                    Text(name).fontWeight(.medium)
                    Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
    let allowed: Bool?
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allow \(tool)?", systemImage: "hand.raised").font(.callout.weight(.medium))
            if !summary.isEmpty {
                Text(summary).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            if !detail.isEmpty, tool != "Bash" {
                AgentCode(text: detail)
            }
            if let allowed {
                Text(allowed ? "Allowed" : "Denied").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Allow") { answer(true) }
                    Button("Deny") { answer(false) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(allowed == nil ? Color.orange.opacity(0.6) : Color.primary.opacity(0.1)))
    }
}

private struct AgentCode: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

/// The setup token the Agent window signs in to Claude with, on the Settings Models page.
struct ClaudeSignInSettingsSection: View {
    var tokens = TokenStore.claudeOAuth
    @State private var saved = false
    @State private var entry = ""
    @State private var problem: String?

    var body: some View {
        SettingsSection("Claude sign-in", footer: "Run claude setup-token in Terminal and paste the token. Uses your Pro/Max plan limits, "
                        + "not API credits. Without a token the Agent window uses the Claude Code sign-in on this Mac.") {
            SettingsRow("Setup token", detail: saved ? "Saved \u{2014} used by the Agent window" : "No token saved") {
                if saved { Button("Remove", action: remove) }
            }
            HStack(spacing: 8) {
                SecureField("Setup token", text: $entry, prompt: Text("sk-ant-oat\u{2026}"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(save)
                Button("Save", action: save).disabled(typed.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .onAppear { saved = tokens.token() != nil }
    }

    private var typed: String { entry.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard AgentLogic.isSetupToken(typed) else { return problem = "A setup token starts with sk-ant-oat." }
        do {
            try tokens.save(typed)
            entry = ""
            problem = nil
            saved = true
        } catch {
            problem = error.localizedDescription
        }
    }

    private func remove() {
        tokens.remove()
        saved = false
    }
}
