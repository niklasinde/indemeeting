import AppKit
import SwiftUI

/// The selected pull request: refresh, actions and the page, with a back button when it replaces the list.
struct GitHubDetailView: View {
    @ObservedObject var page: GitHubDetailModel
    @ObservedObject var model: GitHubModel
    let back: (() -> Void)?
    @ObservedObject private var claude = GitHubClaudeModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let back {
                    Button(action: back) { Label("Pull requests", systemImage: "chevron.left") }.buttonStyle(.borderless)
                }
                Spacer()
                if page.loading { ProgressView().controlSize(.small) } else {
                    Button { page.start() } label: { Image(systemName: "arrow.clockwise") }.help("Fetch this pull request now")
                }
            }
            .padding(.horizontal, RecordingDetail.gutter)
            .padding(.top, 20)
            .padding(.bottom, 10)
            if let error = page.error { DetailErrorBanner(error: error) }
            ScrollView {
                GitHubDetailContent(pr: page.pr, detail: page.detail, directory: model.directory, ask: { model.ask(about: page.pr) })
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, RecordingDetail.gutter)
                    .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: claude.load)
        .alert("Allow Claude reviews?", isPresented: Binding(get: { claude.confirming != nil }, set: { if !$0 { claude.confirming = nil } })) {
            Button("Allow") { claude.confirmAllowing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ClaudeConfirmation.message)
        }
    }
}

private struct DetailErrorBanner: View {
    let error: GitHubError

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error.message).foregroundStyle(.secondary)
            Spacer()
            if let command = error.command { Button("Copy \(command)") { GitHubModel.copy(command) } }
        }
        .font(.callout)
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
    }
}

/// The page itself, without its scroll view, so the previews can render it whole.
struct GitHubDetailContent: View {
    let pr: GitHubPR
    let detail: GitHubPRDetail?
    let directory: TicketDirectory
    let ask: () -> Void
    @ObservedObject private var claude = GitHubClaudeModel.shared
    @ObservedObject private var terminals = EmbeddedTerminalModel.shared
    @State private var bodyExpanded = false
    @State private var allCommits = false
    @State private var fileQuery = ""
    private static let visibleCommits = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            actions
            ClaudeReviewPanel(pr: pr, detail: detail, model: claude)
            if let detail {
                people(detail)
                description(detail)
                checks(detail)
                commits(detail)
                files(detail)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching the pull request\u{2026}").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        let repo = GitHubLogic.repoName(pr.repo)
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(repo.owner) / \(repo.name) #\(String(pr.number))").font(.callout).foregroundStyle(.secondary)
            Text(detail?.title ?? pr.title).font(.system(size: 22, weight: .medium)).textSelection(.enabled)
            FlowChips(headerChips)
            if let detail {
                FlowLayout(spacing: 6) {
                    Text(detail.author ?? "ghost").foregroundStyle(.primary)
                    Text("opened \(detail.created.map { GitHubLogic.updatedText($0, now: Date()) } ?? "")")
                    Text("\u{00B7} updated \(detail.updated.map { GitHubLogic.updatedText($0, now: Date()) } ?? "")")
                    Text("\u{00B7}")
                    Text(GitHubLogic.changesText(additions: detail.additions, deletions: detail.deletions)).monospacedDigit()
                    Text("\u{00B7} \(detail.changedFiles) file\(detail.changedFiles == 1 ? "" : "s")")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    BranchChip(name: detail.base)
                    Image(systemName: "arrow.left").font(.caption).foregroundStyle(.tertiary)
                    BranchChip(name: detail.head)
                }
            }
        }
    }

    private var headerChips: [Chip] {
        var chips = [Self.stateChip(detail, pr)]
        guard let detail else { return chips }
        if let ticket = detail.ticket ?? pr.ticket { chips.append(.ticket(ticket, directory, short: false)) }
        if detail.state == .open, let text = GitHubLogic.mergeText(detail.mergeable) {
            chips.append(detail.mergeable == .conflicting ? Chip(text: text, icon: "exclamationmark.triangle", tint: .red)
                         : Chip(text: text, icon: "checkmark", tint: .green))
        }
        if detail.state == .open, let review = detail.review { chips.append(Self.reviewChip(review)) }
        chips += detail.labels.map { Chip(text: $0, icon: "tag") }
        return chips
    }

    private static func stateChip(_ detail: GitHubPRDetail?, _ pr: GitHubPR) -> Chip {
        let state = detail?.state ?? pr.state
        let draft = detail?.isDraft ?? pr.isDraft
        switch state {
        case .merged: return Chip(text: "Merged", icon: "arrow.triangle.merge", tint: .purple)
        case .closed: return Chip(text: "Closed", icon: "nosign", tint: .red)
        case .open: return draft ? Chip(text: "Draft", icon: "pencil") : Chip(text: "Open", icon: "arrow.triangle.pull", tint: .green)
        }
    }

    private static func reviewChip(_ review: GitHubPR.Review) -> Chip {
        let text = GitHubLogic.reviewText(review)
        switch review {
        case .approved: return Chip(text: text, icon: "checkmark", tint: .green)
        case .changesRequested: return Chip(text: text, icon: "exclamationmark.bubble", tint: .red)
        case .required: return Chip(text: text, icon: "eye", tint: .orange)
        }
    }

    private var actions: some View {
        FlowLayout(spacing: 8) {
            Button("Open in Browser") { open(pr.url) }
            Button("Copy Link") { GitHubModel.copy(pr.url) }
            Button("Copy Title") { GitHubModel.copy(pr.copyText) }
            Button { ask() } label: { Label("Ask about this pull request", systemImage: "bubble.left") }
            OpenInClaudeMenu(pr: pr, detail: detail, model: claude)
            TerminalToggle(key: pr.url, model: terminals)
            AskClaudeMenu(pr: pr, detail: detail, model: claude)
            ClaudeNoteBar(model: claude)
        }
        .controlSize(.small)
    }

    private func people(_ detail: GitHubPRDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !detail.reviewers.isEmpty {
                DetailSection("Reviewers") {
                    FlowLayout(spacing: 14) {
                        ForEach(detail.reviewers, id: \.name) { ReviewerLabel(reviewer: $0) }
                    }
                }
            }
            if !detail.assignees.isEmpty {
                DetailSection("Assignees") {
                    FlowLayout(spacing: 14) {
                        ForEach(detail.assignees, id: \.self) { assignee in
                            HStack(spacing: 6) { Initials(text: assignee, color: .secondary); Text(assignee) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Description

    @ViewBuilder private func description(_ detail: GitHubPRDetail) -> some View {
        let text = GitHubLogic.cleanBody(detail.body)
        DetailSection("Description") {
            if text.isEmpty {
                Text("No description").foregroundStyle(.tertiary)
            } else {
                let long = GitHubLogic.isLong(text)
                AnswerText(text: long && !bodyExpanded ? GitHubLogic.preview(text) : text)
                if long {
                    Button(bodyExpanded ? "Show less" : "Show more") { bodyExpanded.toggle() }.buttonStyle(.link)
                }
            }
        }
    }

    // MARK: Checks

    private func checks(_ detail: GitHubPRDetail) -> some View {
        DetailSection("Checks", trailing: GitHubLogic.checkSummary(detail.checks)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(detail.checks.enumerated()), id: \.offset) { _, check in
                    DetailRow(url: check.url) {
                        CheckSymbol(status: check.status)
                        Text(check.name).lineLimit(1)
                        if let workflow = check.workflow { Text(workflow).foregroundStyle(.tertiary).lineLimit(1) }
                        Spacer(minLength: 8)
                        if let duration = check.duration { Text(GitHubLogic.durationText(duration)).monospacedDigit().foregroundStyle(.tertiary) }
                    }
                    Divider()
                }
                if let note = GitHubLogic.countNote(shown: detail.checks.count, total: detail.checkCount, noun: "checks") { Note(text: note) }
            }
        }
    }

    // MARK: Commits and files

    private func commits(_ detail: GitHubPRDetail) -> some View {
        let shown = allCommits ? detail.commits : Array(detail.commits.prefix(Self.visibleCommits))
        return DetailSection("Commits", trailing: "\(detail.commitCount)") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown, id: \.oid) { commit in
                    DetailRow(url: commit.url) {
                        Text(commit.shortOid).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        Text(commit.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text([commit.author, commit.date.map { GitHubLogic.updatedText($0, now: Date()) }].compactMap { $0 }.joined(separator: " \u{00B7} "))
                            .foregroundStyle(.tertiary).lineLimit(1)
                        if commit.checks != .none { StatusDot(checks: commit.checks) }
                    }
                    Divider()
                }
                if detail.commits.count > shown.count {
                    Button("Show \(detail.commits.count - shown.count) more") { allCommits = true }.buttonStyle(.link).padding(.top, 8)
                }
                if let note = GitHubLogic.countNote(shown: detail.commits.count, total: detail.commitCount, noun: "commits") { Note(text: note) }
            }
        }
    }

    private func files(_ detail: GitHubPRDetail) -> some View {
        let shown = GitHubLogic.files(detail.files, matching: fileQuery)
        return DetailSection("Files changed", trailing: "\(detail.fileCount)") {
            VStack(alignment: .leading, spacing: 0) {
                SearchField(text: $fileQuery).frame(maxWidth: 260).controlSize(.small).padding(.bottom, 8)
                ForEach(shown, id: \.path) { file in
                    DetailRow(url: "\(detail.url)/files") {
                        Image(systemName: Self.symbol(file.change)).foregroundStyle(Self.color(file.change)).frame(width: 18).help(file.change.rawValue.capitalized)
                        (Text(file.directory).foregroundStyle(.tertiary) + Text(file.name)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(GitHubLogic.changesText(additions: file.additions, deletions: file.deletions)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Divider()
                }
                if shown.isEmpty { Text("No file matches").foregroundStyle(.tertiary).padding(.top, 6) }
                if let note = GitHubLogic.countNote(shown: detail.files.count, total: detail.fileCount, noun: "files") {
                    Note(text: note + "; the rest is on GitHub")
                }
            }
        }
    }

    private static func symbol(_ change: GitHubPRDetail.Change) -> String {
        switch change {
        case .added: return "plus.square.fill"
        case .removed: return "minus.square.fill"
        case .renamed, .copied: return "arrow.right.square.fill"
        case .modified, .changed: return "diamond.fill"
        }
    }

    private static func color(_ change: GitHubPRDetail.Change) -> Color {
        switch change {
        case .added: return .green
        case .removed: return .red
        case .renamed, .copied: return .blue
        case .modified, .changed: return .orange
        }
    }
}

private func open(_ url: String) {
    URL(string: url).map { NSWorkspace.shared.open($0) }
}

private struct DetailSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                if let trailing { Text(trailing).font(.callout).foregroundStyle(.secondary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line of a list that opens its address in the browser when clicked.
private struct DetailRow<Content: View>: View {
    let url: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .font(.callout)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { url.map(open) }
            .help(url ?? "")
    }
}

private struct Note: View {
    let text: String

    var body: some View { Text(text).font(.caption).foregroundStyle(.tertiary).padding(.top, 6) }
}

private struct BranchChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
    }
}

private struct Initials: View {
    let text: String
    let color: Color

    var body: some View {
        Text(GitHubLogic.initials(text))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .background(Circle().fill(color.opacity(0.14)))
            .overlay(Circle().strokeBorder(color.opacity(0.5), lineWidth: 1))
    }
}

private struct ReviewerLabel: View {
    let reviewer: GitHubPRDetail.Reviewer

    var body: some View {
        HStack(spacing: 6) {
            Initials(text: reviewer.name, color: color)
            VStack(alignment: .leading, spacing: 0) {
                Text(reviewer.isTeam ? "\(reviewer.name) (team)" : reviewer.name).font(.callout)
                Text(GitHubLogic.reviewText(reviewer.state)).font(.caption).foregroundStyle(color)
            }
        }
    }

    private var color: Color {
        switch reviewer.state {
        case .approved: return .green
        case .changesRequested: return .red
        case .pending: return .orange
        case .commented, .dismissed: return .secondary
        }
    }
}

private struct CheckSymbol: View {
    let status: GitHubPRDetail.CheckStatus

    var body: some View {
        Image(systemName: symbol.name).foregroundStyle(symbol.color).frame(width: 18).help(symbol.help)
    }

    private var symbol: (name: String, color: Color, help: String) {
        switch status {
        case .passed: return ("checkmark.circle.fill", .green, "Passed")
        case .failed: return ("xmark.circle.fill", .red, "Failed")
        case .running: return ("arrow.triangle.2.circlepath.circle.fill", .orange, "Running")
        case .pending: return ("clock.fill", .secondary, "Waiting")
        case .skipped: return ("slash.circle", .secondary, "Skipped")
        case .cancelled: return ("minus.circle.fill", .secondary, "Cancelled")
        }
    }
}

private struct StatusDot: View {
    let checks: GitHubPR.Checks

    var body: some View {
        Image(systemName: checks == .passed ? "checkmark.circle.fill" : checks == .failed ? "xmark.circle.fill" : "circle.fill")
            .font(.caption)
            .foregroundStyle(checks == .passed ? Color.green : checks == .failed ? .red : .orange)
            .help("Checks \(checks.rawValue)")
    }
}
