import AppKit
import SwiftUI

struct GitHubView: View {
    @ObservedObject var model: GitHubModel

    var body: some View {
        if model.enabled, let page = model.page {
            GitHubDetailView(page: page, model: model)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.error, model.enabled, model.hasData { ErrorBanner(error: error) }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            model.loadCache()
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("GitHub").font(.system(size: 20, weight: .medium))
                Spacer()
                if model.enabled { refreshControls }
            }
            if model.showsList {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(GitHubLogic.header(count: model.visible.count, kind: model.kind, capped: model.isCapped))
                        .font(.system(size: 28, weight: .medium))
                    if model.filter.state != .open { Text(model.filter.state.rawValue.lowercased()).foregroundStyle(.secondary) }
                }
                .padding(.top, 10)
                HStack(spacing: 2) {
                    ForEach(GitHubKind.allCases) { kind in
                        Button(kind.tabTitle) { model.kind = kind }
                            .buttonStyle(PillButtonStyle(selected: model.kind == kind))
                    }
                    Spacer()
                }
                .padding(.top, 14)
                .padding(.leading, -8)
                filters.padding(.top, 10)
            }
        }
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var refreshControls: some View {
        HStack(spacing: 8) {
            if let fetched = model.fetched {
                Text("Updated \(GitHubLogic.updatedText(fetched, now: Date()))").font(.callout).foregroundStyle(.tertiary)
            }
            if model.refreshing {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Fetch your pull requests now")
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("State", selection: $model.filter.state) {
                ForEach(GitHubLogic.StateFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Menu {
                Button("All repositories") { model.filter.repo = nil }
                Divider()
                ForEach(model.repos, id: \.self) { repo in
                    Button { model.filter.repo = repo } label: {
                        if model.filter.repo == repo { Label(repo, systemImage: "checkmark") } else { Text(repo) }
                    }
                }
            } label: {
                Label(model.filter.repo.map { GitHubLogic.repoName($0).name } ?? "All repositories", systemImage: "shippingbox")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            SearchField(text: $model.filter.query).frame(maxWidth: 240)
            Spacer()
            Text("Sorted by updated").font(.caption).foregroundStyle(.tertiary)
        }
        .controlSize(.small)
    }

    @ViewBuilder private var content: some View {
        if !model.enabled {
            GitHubEmptyState(icon: "arrow.triangle.branch", title: "Your pull requests, in one place",
                       text: "Reads your pull requests through the GitHub CLI. Nothing is uploaded.") {
                Button("Turn On") { model.setEnabled(true) }.buttonStyle(.borderedProminent)
            }
        } else if let error = model.error, !model.hasData {
            ErrorState(error: error, refresh: { Task { await model.refresh() } })
        } else if model.visible.isEmpty {
            GitHubEmptyState(icon: model.refreshing && !model.hasData ? "arrow.clockwise" : "checkmark.circle",
                       title: model.refreshing && !model.hasData ? "Fetching pull requests\u{2026}"
                       : model.filter == GitHubLogic.Filter() ? "No pull requests" : "Nothing matches",
                       text: model.filter == GitHubLogic.Filter() ? nil : "Change the state, repository or search.") { EmptyView() }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.visible) { pr in
                        PullRequestRow(pr: pr, model: model)
                        Divider()
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RecordingDetail.gutter)
                .padding(.bottom, 28)
            }
        }
    }
}

private struct PullRequestRow: View {
    let pr: GitHubPR
    @ObservedObject var model: GitHubModel

    var body: some View {
        let repo = GitHubLogic.repoName(pr.repo)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(repo.owner) / \(repo.name) #\(String(pr.number))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(pr.title).lineLimit(2).foregroundStyle(.primary)
                details
            }
            Spacer(minLength: 8)
            StatusMark(pr: pr)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.open(pr) }
        .contextMenu {
            Button("Open") { model.open(pr) }
            Button("Open in Browser") { open(pr.url) }
            Button("Copy Link") { GitHubModel.copy(pr.url) }
            Button("Copy Title") { GitHubModel.copy(pr.copyText) }
            Button("Open Repository") { open("https://\(GitHubLogic.host)/\(pr.repo)") }
            Divider()
            Button("Ask About This Pull Request\u{2026}") { model.ask(about: pr) }
        }
        .help(pr.url)
    }

    private var details: some View {
        HStack(spacing: 8) {
            FlowChips(chips)
            Text(GitHubLogic.changesText(additions: pr.additions, deletions: pr.deletions)).monospacedDigit()
            Text(GitHubLogic.updatedText(pr.updated, now: Date()))
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private var chips: [Chip] {
        var chips: [Chip] = []
        if let ticket = pr.ticket { chips.append(.ticket(ticket, model.directory, short: true)) }
        if pr.isDraft { chips.append(Chip(text: "Draft", icon: "pencil")) }
        if pr.state == .open, let review = pr.review { chips.append(Self.chip(review)) }
        if pr.comments > 0 { chips.append(Chip(text: "\(pr.comments)", icon: "bubble.left")) }
        return chips
    }

    private static func chip(_ review: GitHubPR.Review) -> Chip {
        switch review {
        case .approved: return Chip(text: "Approved", icon: "checkmark", tint: .green)
        case .changesRequested: return Chip(text: "Changes requested", icon: "exclamationmark.bubble", tint: .red)
        case .required: return Chip(text: "Review required", icon: "eye", tint: .orange)
        }
    }

    private func open(_ url: String) {
        URL(string: url).map { NSWorkspace.shared.open($0) }
    }
}

struct StatusMark: View {
    let pr: GitHubPR

    var body: some View {
        Image(systemName: symbol.name)
            .font(.system(size: 17))
            .foregroundStyle(symbol.color)
            .frame(width: 24)
            .help(symbol.help)
    }

    private var symbol: (name: String, color: Color, help: String) {
        switch (pr.state, pr.checks) {
        case (.merged, _): return ("arrow.triangle.merge", .purple, "Merged")
        case (.closed, _): return ("nosign", .secondary, "Closed")
        case (_, .passed): return ("checkmark.circle.fill", .green, "Checks passed")
        case (_, .failed): return ("xmark.circle.fill", .red, "Checks failed")
        case (_, .running): return ("circle.fill", .orange, "Checks running")
        case (_, .none): return ("circle", Color.secondary.opacity(0.5), "No checks")
        }
    }
}

private struct GitHubEmptyState<Actions: View>: View {
    let icon: String
    let title: String
    let text: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.body.weight(.medium))
            if let text { Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            actions
        }
        .font(.callout)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The GitHub CLI is missing or not signed in: the command to run in a terminal, with a button that copies it.
struct ErrorState: View {
    let error: GitHubError
    let refresh: () -> Void
    @State private var copied = false

    var body: some View {
        GitHubEmptyState(icon: "exclamationmark.triangle", title: title, text: error.message) {
            if let command = error.command {
                HStack(spacing: 8) {
                    Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy") {
                        GitHubModel.copy(command)
                        copied = true
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            }
            Button("Try Again", action: refresh)
        }
    }

    private var title: String {
        switch error {
        case .cliMissing: return "GitHub CLI not found"
        case .notLoggedIn: return "Not signed in to GitHub"
        default: return "Could not fetch pull requests"
        }
    }
}

private struct ErrorBanner: View {
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

struct GitHubSettingsSection: View {
    @ObservedObject var model: GitHubModel
    @State private var confirming = false

    var body: some View {
        SettingsSection("GitHub", footer: "Reads your pull requests through the GitHub CLI (gh), which keeps the sign-in; the app never "
                        + "sees a token. Nothing is uploaded. The last fetch is cached on this Mac so the view opens instantly.") {
            SettingsRow("Show my pull requests", detail: model.enabled && GitHubLogic.findCLI() == nil ? "GitHub CLI not found (\(GitHubError.installCommand))" : nil) {
                Toggle("Show my pull requests", isOn: Binding(get: { model.enabled }, set: model.setEnabled)).labelsHidden().toggleStyle(.switch)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Refresh every", detail: "The refresh button in the view always fetches now.") {
                Picker("Refresh every", selection: Binding(get: { model.interval }, set: model.setInterval)) {
                    ForEach(GitHubModel.intervals, id: \.self) { Text($0 < 60 ? "\($0) min" : "1 hour").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!model.enabled)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Clear GitHub cache", detail: model.cachedCount == 0 ? "Nothing cached"
                        : "\(model.cachedCount) pull request\(model.cachedCount == 1 ? "" : "s") cached") {
                Button("Clear\u{2026}") { confirming = true }.disabled(model.cachedCount == 0)
            }
        }
        .onAppear(perform: model.loadCache)
        .alert("Clear the GitHub cache?", isPresented: $confirming) {
            Button("Clear", role: .destructive) { model.clearCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The cached pull requests are removed. They are fetched again at the next refresh.")
        }
    }
}
