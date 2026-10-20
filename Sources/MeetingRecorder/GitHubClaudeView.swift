import AppKit
import SwiftUI

/// "Open in Claude": the main button repeats the last preset, the menu offers the others and where to open them.
struct OpenInClaudeMenu: View {
    let pr: GitHubPR
    let detail: GitHubPRDetail?
    @ObservedObject var model: GitHubClaudeModel

    var body: some View {
        let saved = model.resumable(pr.url)
        Menu {
            Picker("Open in", selection: Binding(get: { model.destination }, set: { model.destination = $0 })) {
                ForEach(model.installedDestinations()) { Text($0.title).tag($0) }
            }
            Divider()
            if saved != nil {
                Button("Resume previous session") { model.resumeInClaude(pr, detail) }
                Menu("Start new session") { presets }
                Divider()
                Button("Forget session") { model.forgetSession(pr.url) }
            } else {
                presets
            }
        } label: {
            Label("Open in Claude", systemImage: "terminal")
        } primaryAction: {
            if saved != nil { model.resumeInClaude(pr, detail) } else { model.openInClaude(pr, detail, model.primaryPreset) }
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(saved != nil ? "Resume the Claude session of this pull request in \(model.destination.title)"
              : "Start a Claude session about this pull request in \(model.destination.title)")
    }

    @ViewBuilder private var presets: some View {
        ForEach(GitHubClaude.Preset.allCases) { preset in
            Button(preset.title) { model.openInClaude(pr, detail, preset) }
        }
    }
}

/// "Ask Claude": a headless, read-only run here whose answer shows on the page.
struct AskClaudeMenu: View {
    let pr: GitHubPR
    let detail: GitHubPRDetail?
    @ObservedObject var model: GitHubClaudeModel

    var body: some View {
        Menu {
            ForEach(GitHubClaude.Preset.headless) { preset in
                Button(preset.title) { model.ask(pr, detail, preset) }
            }
        } label: {
            Label("Ask Claude", systemImage: "sparkles")
        } primaryAction: {
            model.ask(pr, detail, .review)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("Let Claude review this pull request here. It reads only; nothing is posted to GitHub.")
    }
}

struct ClaudeNoteBar: View {
    @ObservedObject var model: GitHubClaudeModel

    var body: some View {
        if let note = model.note {
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(note.text).foregroundStyle(.secondary)
                if let copy = note.copy { Button("Copy \(copy)") { GitHubModel.copy(copy) }.buttonStyle(.link) }
                Spacer(minLength: 0)
                Button { model.dismissNote() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .font(.callout)
        }
    }
}

/// The saved or running Claude review of the pull request, under its header.
struct ClaudeReviewPanel: View {
    let pr: GitHubPR
    let detail: GitHubPRDetail?
    @ObservedObject var model: GitHubClaudeModel
    @AppStorage("githubClaudePanelOpen") private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).frame(width: 10)
                    Text("Claude review").font(.headline)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if open { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        switch model.live[pr.url] {
        case .queued: return "Waiting"
        case .running: return "Running"
        case .failed: return "Failed"
        case nil: return model.review(for: pr.url).map { "\($0.preset.shortTitle) \u{00B7} \(GitHubLogic.updatedText($0.created, now: Date()))" } ?? "Not run"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.live[pr.url] {
        case .queued(let preset):
            HStack {
                Text("\(preset.shortTitle) waits for \(model.runningLabel ?? "the running review") to finish.").foregroundStyle(.secondary)
                Button("Cancel") { model.cancel(pr.url) }
            }
        case .running(let running):
            runningView(running)
        case .failed(let failure, let preset):
            failedView(failure, preset)
        case nil:
            if let review = model.review(for: pr.url) { reviewView(review) } else { idleView }
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude has not looked at this pull request yet. It runs your local claude CLI, read-only: nothing is posted to GitHub.")
                .foregroundStyle(.secondary)
            AskClaudeMenu(pr: pr, detail: detail, model: model)
        }
    }

    private func runningView(_ running: GitHubClaudeModel.Running) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: running.started, by: 1)) { context in
                    Text("\(running.preset.shortTitle) \u{00B7} \(GitHubLogic.durationText(context.date.timeIntervalSince(running.started)))")
                        .monospacedDigit()
                }
                if let status = running.status { Text(status).lineLimit(1).foregroundStyle(.tertiary) }
                Spacer()
                Button("Cancel") { model.cancel(pr.url) }
            }
            .foregroundStyle(.secondary)
            if !running.text.isEmpty { AnswerText(text: running.text) }
        }
    }

    private func failedView(_ failure: GitHubClaude.Failure, _ preset: GitHubClaude.Preset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            HStack {
                Button("Try again") { model.dismissFailure(pr.url); model.ask(pr, detail, preset) }
                Button("Dismiss") { model.dismissFailure(pr.url) }
            }
            .controlSize(.small)
        }
    }

    private func reviewView(_ review: GitHubReview) -> some View {
        let stale = model.isOutdated(pr.url, head: detail?.headOid)
        return VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                Text(review.preset.shortTitle)
                Text("\u{00B7} \(review.created.formatted(date: .abbreviated, time: .shortened))")
                if let sha = review.headSHA { Text("\u{00B7} commit \(sha.prefix(7))").monospacedDigit() }
                Text("\u{00B7} \(GitHubLogic.durationText(review.duration))").monospacedDigit()
                if let cost = review.cost { Text("\u{00B7} $\(cost, specifier: "%.2f")").monospacedDigit() }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if stale {
                Label("Outdated \u{2014} new commits since this review", systemImage: "clock.badge.exclamationmark").font(.callout).foregroundStyle(.orange)
            }
            AnswerText(text: review.text)
            FlowLayout(spacing: 8) {
                Button("Re-run") { model.ask(pr, detail, review.preset) }
                Button("Copy") { GitHubModel.copy(review.text) }
                Button("Copy as review comment") { GitHubModel.copy(GitHubClaude.reviewComment(review.text)) }
                Button("Open in Claude\u{2026}") { model.openInClaude(pr, detail, review.preset) }
            }
            .controlSize(.small)
        }
    }
}

/// Shown in the list header while a review runs.
struct ClaudeRunningIndicator: View {
    @ObservedObject var model: GitHubClaudeModel

    var body: some View {
        if let label = model.runningLabel, model.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Claude is reviewing \(label)\u{2026}").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct ClaudeSettingsRows: View {
    @ObservedObject var model: GitHubClaudeModel
    @State private var confirming = false

    var body: some View {
        Group {
            Divider().padding(.leading, 14)
            SettingsRow("Allow Claude reviews",
                        detail: "Runs your local claude CLI on the pull request; the PR diff is sent to Claude through your own Claude login. "
                            + "Nothing is posted to GitHub.") {
                Toggle("Allow Claude reviews", isOn: Binding(get: { model.enabled }, set: { $0 ? (confirming = true) : model.setEnabled(false) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Open Claude in", detail: "Where Open in Claude starts a session. Terminal apps run the claude CLI in the local checkout.") {
                Picker("Open Claude in", selection: Binding(get: { model.destination }, set: { model.destination = $0 })) {
                    ForEach(model.installedDestinations()) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Divider().padding(.leading, 14)
            Divider().padding(.leading, 14)
            EmbeddedTerminalSettingsRows()
            Divider().padding(.leading, 14)
            SettingsRow("Remember my choice", detail: "The main Open in Claude button repeats the preset you used last.") {
                Toggle("Remember my choice", isOn: Binding(get: { model.remember }, set: { model.remember = $0 })).labelsHidden().toggleStyle(.switch)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Remember Claude sessions per PR",
                        detail: "Keeps the id and folder of each pull request's Claude session, so Resume picks it up. Only ids and paths are stored.") {
                Toggle("Remember Claude sessions per PR", isOn: Binding(get: { model.remembersSessions }, set: { model.remembersSessions = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Saved Claude sessions", detail: model.sessions.isEmpty ? "None to resume." : "\(model.sessions.count) can be resumed.") {
                Button("Forget all") { model.forgetAllSessions() }.disabled(model.sessions.isEmpty)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Claude model", detail: "Optional, for reviews run here. Empty uses the CLI's default.") {
                TextField("default", text: Binding(get: { model.modelName }, set: { model.modelName = $0 })).frame(width: 140)
            }
        }
        .onAppear(perform: model.load)
        .alert("Allow Claude reviews?", isPresented: $confirming) {
            Button("Allow") { model.setEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ClaudeConfirmation.message)
        }
    }
}

/// Font size and the quit confirmation of the terminal in this app.
struct EmbeddedTerminalSettingsRows: View {
    @AppStorage(EmbeddedTerminal.fontSizeKey) private var fontSize = EmbeddedTerminal.defaultFontSize
    @AppStorage(EmbeddedTerminal.confirmQuitKey) private var confirmQuit = true

    var body: some View {
        if EmbeddedTerminalModel.available {
            SettingsRow("Embedded terminal font size", detail: "For \u{201C}In this app\u{201D}. \u{2318}+ and \u{2318}\u{2212} change it while the terminal has the keyboard.") {
                Stepper("\(Int(EmbeddedTerminal.fontSize(fontSize))) pt", value: $fontSize, in: EmbeddedTerminal.fontSizes, step: 1)
                    .monospacedDigit()
            }
            Divider().padding(.leading, 14)
            SettingsRow("Confirm before quitting while running", detail: "Asks first when Claude is still running in an embedded terminal.") {
                Toggle("Confirm before quitting while running", isOn: $confirmQuit).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

enum ClaudeConfirmation {
    static let message = "Ask Claude runs the claude CLI on this Mac, read-only, in the repository's checkout. The diff and comments of "
        + "the pull request are sent to Claude through your own Claude login. Nothing is posted to GitHub or Jira, and nothing runs "
        + "until you click."
}
