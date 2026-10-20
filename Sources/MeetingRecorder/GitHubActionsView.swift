import AppKit
import SwiftUI

/// Hosts whichever sheet the model has open.
struct GitHubActionSheet: View {
    let sheet: GitHubActionsModel.Sheet
    @ObservedObject var model: GitHubActionsModel

    var body: some View {
        switch sheet {
        case .explain: ActionExplainSheet(continueAction: model.continueAfterExplanation, cancel: model.dismissSheet)
        case .single(let draft): ActionConfirmSheet(draft: draft, confirm: { model.confirm(draft) }, cancel: model.dismissSheet)
        case .bulk(let draft): BulkActionSheet(draft: draft, confirm: { model.confirm(draft) }, cancel: model.dismissSheet)
        }
    }
}

struct ActionExplainSheet: View {
    let continueAction: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Actions on GitHub", systemImage: "checkmark.shield").font(.title3.weight(.semibold))
            Text(GitHubActions.explanation).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.defaultAction)
                Button("I understand", action: continueAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Command").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy command") {
                    GitHubModel.copy(command)
                    copied = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
    }
}

private struct CommentField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 76)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
        }
    }
}

private extension GitHubActionConfirmation.Tone {
    var color: Color {
        switch self {
        case .normal: return .primary
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        }
    }
}

struct ActionConfirmSheet: View {
    @ObservedObject var draft: GitHubActionDraft
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        let confirmation = draft.confirmation
        let blocker = draft.checking ? nil : confirmation.blocker
        VStack(alignment: .leading, spacing: 14) {
            Text(confirmation.title).font(.title3.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(confirmation.facts, id: \.label) { fact in
                    GridRow {
                        Text(fact.label).foregroundStyle(.secondary)
                        Text(fact.value).foregroundStyle(fact.tone.color).textSelection(.enabled).lineLimit(3)
                    }
                }
            }
            .font(.callout)
            if let blocker {
                Label(blocker, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(confirmation.warnings, id: \.text) { warning in
                Label(warning.text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(warning.tone.color).fixedSize(horizontal: false, vertical: true)
            }
            if blocker == nil {
                if confirmation.mergeMethods.count > 1 {
                    Picker("Merge method", selection: $draft.request.method) {
                        ForEach(confirmation.mergeMethods) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                CommentField(label: confirmation.commentLabel, text: $draft.request.comment)
                if confirmation.offersBranchDelete {
                    Toggle("Also delete the branch", isOn: $draft.request.deleteBranch)
                }
            }
            CommandBox(command: confirmation.command)
            if let note = draft.note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if draft.checking {
                    ProgressView().controlSize(.small)
                    Text("Checking the current state\u{2026}").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(confirmation.confirmIsDefault ? .cancelAction : .defaultAction)
                    .disabled(draft.running)
                confirmButton(confirmation)
            }
        }
        .font(.body)
        .padding(20)
        .frame(width: 540)
    }

    @ViewBuilder private func confirmButton(_ confirmation: GitHubActionConfirmation) -> some View {
        let enabled = confirmation.canConfirm && !draft.checking && !draft.running
        if confirmation.confirmIsDefault {
            Button(confirmation.confirmTitle, action: confirm).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!enabled)
        } else {
            Button(confirmation.confirmTitle, action: confirm).buttonStyle(.bordered).tint(.green).disabled(!enabled)
        }
    }
}

struct BulkActionSheet: View {
    @ObservedObject var draft: GitHubBulkDraft
    let confirm: () -> Void
    let cancel: () -> Void

    private var title: String {
        let count = draft.items.count
        return "\(draft.action.title) \(count) pull request\(count == 1 ? "" : "s")"
    }

    var body: some View {
        let current = draft.items.first { $0.outcome == nil }?.id
        return VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            Text("One gh command per pull request, in this order, one at a time. A failure is shown and the next one still runs, unless it would fail the same way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(draft.items) { item in
                        BulkRow(item: item, request: GitHubActionRequest(draft.action, pr: item.pr).with(comment: draft.comment, deleteBranch: draft.deleteBranch && draft.action == .close),
                                active: draft.running && item.id == current)
                        Divider()
                    }
                }
            }
            .frame(height: min(CGFloat(draft.items.count) * 50, 260))
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            if !draft.running && !draft.finished {
                CommentField(label: "Comment on each (optional)", text: $draft.comment)
                if draft.offersBranchDelete { Toggle("Also delete the branches", isOn: $draft.deleteBranch) }
            }
            footer
        }
        .padding(20)
        .frame(width: 600)
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if draft.running {
                ProgressView(value: Double(draft.done), total: Double(max(draft.items.count, 1))).frame(width: 140)
                Text("\(draft.action.title == "Close" ? "Closing" : "Reopening") \(min(draft.done + 1, draft.items.count)) of \(draft.items.count)\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let summary = draft.summary {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if draft.running {
                Button("Stop after this one") { draft.stop.set() }
            } else if draft.finished {
                Button("Done", action: cancel).keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(title, action: confirm).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(draft.requests.isEmpty)
            }
        }
    }
}

private struct BulkRow: View {
    let item: GitHubBulkDraft.Item
    let request: GitHubActionRequest
    let active: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            mark.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(request.shortReference)  \(request.title)").lineLimit(1)
                Text(detail).font(.system(.caption, design: .monospaced)).foregroundStyle(detailColor).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 49, alignment: .leading)
    }

    @ViewBuilder private var mark: some View {
        switch item.outcome {
        case .done?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped?: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case nil: if active { ProgressView().controlSize(.mini) } else { Image(systemName: "circle").foregroundStyle(.tertiary) }
        }
    }

    private var detail: String {
        switch item.outcome {
        case .failed(let error)?: return error.message
        case .skipped(let reason)?: return reason
        default: return GitHubActions.commandLine(request)
        }
    }

    private var detailColor: Color {
        if case .failed? = item.outcome { return .red }
        return .secondary
    }
}

struct ActionBannerView: View {
    @ObservedObject var model: GitHubActionsModel

    var body: some View {
        if let banner = model.banner {
            HStack(spacing: 10) {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(banner.isError ? .orange : .green)
                Text(banner.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !banner.reopen.isEmpty { Button("Reopen") { model.reopen(banner.reopen) } }
                if let details = banner.details { Button("Copy command") { GitHubModel.copy(details) } }
                Button { model.dismissBanner() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Review and Close on the pull request page. Disabled, with the reason, while the master switch is off.
struct GitHubActionButtons: View {
    let pr: GitHubPR
    let detail: GitHubPRDetail?
    @ObservedObject var model: GitHubActionsModel

    var body: some View {
        let state = detail?.state ?? pr.state
        Menu {
            Button("Approve\u{2026}") { model.begin(.approve, pr, detail: detail) }.disabled(state != .open)
            Button("Request Changes\u{2026}") { model.begin(.requestChanges, pr, detail: detail) }.disabled(state != .open)
            Button("Comment\u{2026}") { model.begin(.comment, pr, detail: detail) }
        } label: {
            Label("Review", systemImage: "checkmark.bubble")
        }
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(!model.enabled)
        .help(model.enabled ? "Approve, request changes or comment. You confirm first." : GitHubActions.disabledHelp)
        Button("Merge\u{2026}") { model.begin(.merge, pr, detail: detail) }
            .disabled(!model.enabled || state != .open)
            .help(model.enabled ? "Merge this pull request. You confirm first; GitHub cannot undo a merge." : GitHubActions.disabledHelp)
        if state == .closed {
            Button("Reopen\u{2026}") { model.begin(.reopen, pr, detail: detail) }
                .disabled(!model.enabled)
                .help(model.enabled ? "Reopen this pull request. You confirm first." : GitHubActions.disabledHelp)
        } else {
            Button("Close\u{2026}") { model.begin(.close, pr, detail: detail) }
                .disabled(!model.enabled || state != .open)
                .help(model.enabled ? "Close this pull request. You confirm first." : GitHubActions.disabledHelp)
        }
    }
}

/// The actions in a row's context menu; nothing at all while the master switch is off.
struct GitHubRowActions: View {
    let pr: GitHubPR
    let targets: [GitHubPR]
    @ObservedObject var model: GitHubActionsModel

    var body: some View {
        if GitHubActions.listShowsActions(enabled: model.enabled) {
            Divider()
            Button("Approve\u{2026}") { model.begin(.approve, pr) }.disabled(pr.state != .open)
            if targets.count == 1, pr.state == .open { Button("Merge\u{2026}") { model.begin(.merge, pr) } }
            if targets.count > 1 {
                Button("Close \(targets.count) Pull Requests\u{2026}") { model.beginBulk(.close, targets) }
            } else if pr.state == .closed {
                Button("Reopen\u{2026}") { model.begin(.reopen, pr) }
            } else {
                Button("Close\u{2026}") { model.begin(.close, pr) }.disabled(pr.state != .open)
            }
        }
    }
}

/// Shown above the list while several rows are marked.
struct MarkedBar: View {
    let count: Int
    @ObservedObject var model: GitHubActionsModel
    let close: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(count) selected").font(.callout.weight(.medium))
            Spacer()
            Button("Close \(count) pull requests\u{2026}", action: close)
                .disabled(!model.enabled)
                .help(model.enabled ? "Close the selected pull requests. You confirm first." : GitHubActions.disabledHelp)
            Button("Clear", action: clear)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
    }
}

struct ActionSettingsRows: View {
    @ObservedObject var model: GitHubActionsModel
    @State private var confirming = false

    var body: some View {
        Group {
            SettingsRow("Allow actions on GitHub (approve, merge, close)", detail: GitHubActions.settingNote) {
                Toggle("Allow actions on GitHub", isOn: Binding(get: { model.enabled }, set: model.setEnabled)).labelsHidden().toggleStyle(.switch)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Recent actions", detail: model.records.isEmpty ? "Nothing done from here yet. Kept on this Mac." : "The last \(model.records.count), kept on this Mac.") {
                Button("Clear\u{2026}") { confirming = true }.disabled(model.records.isEmpty)
            }
            if !model.records.isEmpty {
                RecentActions(model: model)
            }
        }
        .onAppear(perform: model.loadRecords)
        .alert("Clear the log of actions?", isPresented: $confirming) {
            Button("Clear", role: .destructive) { model.clearRecords() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the log on this Mac is removed. What was done on GitHub stays.")
        }
    }
}

private struct RecentActions: View {
    @ObservedObject var model: GitHubActionsModel

    var body: some View {
        let reopenable = model.reopenable
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.records) { record in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: record.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(record.succeeded ? .green : .red)
                            .help(record.error ?? "Done")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(record.action.title) \(record.reference)").lineLimit(1)
                            Text(record.error ?? record.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if reopenable.contains(record.id) {
                            Button("Reopen") { model.reopen([model.reopening(record)]) }.controlSize(.small).disabled(!model.enabled)
                        }
                        Text(GitHubLogic.updatedText(record.at, now: Date())).font(.caption).foregroundStyle(.tertiary).fixedSize()
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .help(record.command)
                    Divider().padding(.leading, 14)
                }
            }
        }
        .frame(maxHeight: 220)
    }
}
