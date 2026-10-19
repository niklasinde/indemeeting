import AppKit
import SwiftUI

struct GitHubView: View {
    @ObservedObject var model: GitHubModel
    @AppStorage("githubListWidth") private var listWidth = Self.defaultListWidth
    @State private var showsDetail = false
    @State private var dragStart: Double?
    @FocusState private var focus: Pane?

    enum Pane { case list, detail }
    static let defaultListWidth = 420.0
    static let listWidths = 320.0...560.0
    static let minimumDetailWidth = 420.0
    /// Below this the list and the page take turns instead of sitting side by side.
    static let compactBelow = 780.0

    var body: some View {
        GeometryReader { proxy in
            if !model.showsList {
                listPane
            } else if proxy.size.width < Self.compactBelow {
                if showsDetail, model.page != nil { detailPane(back: { showsDetail = false }) } else { listPane }
            } else {
                split(width: proxy.size.width)
            }
        }
        .background { openShortcut }
        .onAppear {
            model.loadCache()
            model.reconcile()
            Task { await model.refresh() }
        }
        .onChange(of: model.visible.map(\.url)) { model.reconcile() }
        .onChange(of: model.selectedURL) { if model.selectedURL == nil { showsDetail = false } }
    }

    private func split(width: CGFloat) -> some View {
        let list = Self.listWidth(listWidth, in: width)
        return HStack(spacing: 0) {
            listPane.frame(width: list)
            splitter(current: list, total: width)
            detailPane(back: nil)
        }
    }

    static func listWidth(_ stored: Double, in total: Double) -> Double {
        min(max(stored, listWidths.lowerBound), min(listWidths.upperBound, total - minimumDetailWidth))
    }

    private func splitter(current: Double, total: Double) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle()).pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? current
                            dragStart = start
                            listWidth = Self.listWidth(start + drag.translation.width, in: total)
                        }
                        .onEnded { _ in dragStart = nil })
            }
    }

    private var openShortcut: some View {
        Button("Open in Browser") { model.page.map { NSWorkspace.shared.open(URL(string: $0.pr.url)!) } }
            .keyboardShortcut("o")
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }

    private func detailPane(back: (() -> Void)?) -> some View {
        Group {
            if let page = model.page {
                GitHubDetailView(page: page, model: model, back: back)
                    .id(page.pr.url)
                    .focusable()
                    .focused($focus, equals: .detail)
                    .focusEffectDisabled()
                    .onKeyPress(.escape) {
                        focus = .list
                        return .handled
                    }
            } else {
                GitHubEmptyState(icon: "arrow.triangle.pull", title: "Select a pull request",
                                 text: "Click one in the list, or use the arrow keys. Return moves to the page, \u{2318}O opens it in the browser.") { EmptyView() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func show(_ pr: GitHubPR) {
        model.select(pr)
        showsDetail = true
        focus = .list
    }

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.error, model.enabled, model.hasData { ErrorBanner(error: error) }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                        .font(.system(size: 22, weight: .medium))
                    if model.filter.state != .open { Text(model.filter.state.rawValue.lowercased()).foregroundStyle(.secondary) }
                }
                .padding(.top, 8)
                FlowLayout(spacing: 2) {
                    ForEach(GitHubKind.allCases) { kind in
                        Button(kind.tabTitle) { model.kind = kind }
                            .buttonStyle(PillButtonStyle(selected: model.kind == kind))
                    }
                }
                .padding(.top, 10)
                .padding(.leading, -8)
                filters.padding(.top, 8)
                quickFilters.padding(.top, 8).padding(.leading, -8)
            }
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private static let gutter: CGFloat = 16

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
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 8) {
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
                Menu {
                    Picker("Sort by", selection: $model.filter.sort) {
                        ForEach(GitHubSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(model.filter.sort.rawValue, systemImage: "arrow.up.arrow.down")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort the pull requests")
            }
            SearchField(text: $model.filter.query)
        }
        .controlSize(.small)
    }

    private var quickFilters: some View {
        FlowLayout(spacing: 2) {
            ForEach(GitHubQuickFilter.allCases) { quick in
                Button { toggle(quick) } label: { Label(quick.rawValue, systemImage: quick.icon) }
                    .buttonStyle(PillButtonStyle(selected: model.filter.quick.contains(quick)))
            }
            Button { model.filter.hideBotOnly.toggle() } label: { Label("Hide bot-only activity", systemImage: "cpu") }
                .buttonStyle(PillButtonStyle(selected: model.filter.hideBotOnly))
        }
        .controlSize(.small)
    }

    private func toggle(_ quick: GitHubQuickFilter) {
        if model.filter.quick.contains(quick) { model.filter.quick.remove(quick) } else { model.filter.quick.insert(quick) }
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
                       text: model.filter == GitHubLogic.Filter() ? nil : "Change the state, repository, search or quick filters.") { EmptyView() }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.visible) { pr in
                            PullRequestRow(pr: pr, model: model, selected: pr.url == model.selectedURL, show: show)
                            Divider().padding(.horizontal, Self.gutter)
                        }
                    }
                    .padding(.horizontal, Self.gutter - 8)
                    .padding(.bottom, 20)
                }
                .focusable()
                .focused($focus, equals: .list)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { step(.previous) }
                .onKeyPress(.downArrow) { step(.next) }
                .onKeyPress(.return) {
                    if model.page != nil { enterDetail() }
                    return .handled
                }
                .onChange(of: model.selectedURL) { if let url = model.selectedURL { proxy.scrollTo(url) } }
            }
        }
    }

    private func step(_ direction: GitHubSelection.Direction) -> KeyPress.Result {
        model.step(direction)
        return .handled
    }

    private func enterDetail() {
        showsDetail = true
        focus = .detail
    }
}

private struct PullRequestRow: View {
    let pr: GitHubPR
    @ObservedObject var model: GitHubModel
    let selected: Bool
    let show: (GitHubPR) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text("\(GitHubLogic.repoName(pr.repo).name) #\(String(pr.number))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatusMark(pr: pr)
            }
            Text(pr.title).lineLimit(2).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
            details
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.08) : .clear))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { show(pr) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(pr.url) })
        .contextMenu {
            Button("Show Details") { show(pr) }
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            FlowChips(chips)
            Spacer(minLength: 0)
            Text("\(GitHubLogic.changesText(additions: pr.additions, deletions: pr.deletions)) \u{00B7} \(GitHubLogic.updatedText(pr.updated, now: Date()))")
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private var chips: [Chip] {
        var chips: [Chip] = []
        let signals = GitHubLogic.signals(pr)
        if let ticket = pr.ticket { chips.append(.ticket(ticket, model.directory, short: true)) }
        if pr.isDraft { chips.append(Chip(text: "Draft", icon: "pencil")) }
        if signals.waitingOnMe { chips.append(Chip(text: "Waiting on you", icon: "person.crop.circle.badge.clock", tint: .orange)) }
        if pr.state == .open, let review = pr.review { chips.append(Self.chip(review)) }
        if signals.unresolved > 0 {
            let capped = (pr.activity?.threads ?? 0) > GitHubLogic.threadPageSize
            chips.append(Chip(text: "\(signals.unresolved)\(capped ? "+" : "") unresolved", icon: "bubble.left.and.exclamationmark.bubble.right", tint: .orange))
        }
        if signals.newFeedback > 0 { chips.append(Chip(text: GitHubLogic.newCommentsText(signals.newFeedback), icon: "bell.fill", tint: .accentColor)) }
        else if signals.newBotFeedback > 0 { chips.append(Chip(text: "\(signals.newBotFeedback) from bots", icon: "cpu")) }
        if pr.comments > 0 { chips.append(Chip(text: "\(pr.comments)", icon: "bubble.left")) }
        if let last = signals.lastActor {
            chips.append(Chip(text: last.actor.isBot ? "bot" : GitHubLogic.initials(last.actor.login), icon: last.actor.isBot ? "cpu" : "person.crop.circle",
                              help: "Last comment by \(last.actor.login) \(GitHubLogic.updatedText(last.date, now: Date()))"))
        }
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
            .font(.system(size: 15))
            .foregroundStyle(symbol.color)
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
