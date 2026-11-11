import AppKit
import SwiftUI

struct GitHubView: View {
    @ObservedObject var model: GitHubModel
    @AppStorage("githubListWidth") private var listWidth = GitHubLayout.defaultListWidth
    @AppStorage(GitHubModel.mergeableKey) private var mergeable = false
    @AppStorage(DockPlacement.choiceKey) private var dockChoice = DockPlacement.Choice.automatic
    @State private var showsDetail = false
    @State private var dragStart: Double?
    @FocusState private var focus: Pane?
    @ObservedObject private var terminals = EmbeddedTerminalModel.shared
    @ObservedObject private var actions = GitHubActionsModel.shared

    enum Pane { case list, detail }

    var body: some View {
        GeometryReader { proxy in
            if !model.showsList {
                listPane(width: proxy.size.width, list: proxy.size.width)
            } else if proxy.size.width < GitHubLayout.compactBelow {
                if showsDetail, model.page != nil {
                    let placement = DockPlacement.placement(dockChoice, detailWidth: proxy.size.width, windowHeight: proxy.size.height, canSpan: false)
                    detailPane(back: { showsDetail = false }, placement: placement, column: proxy.size.width)
                } else {
                    listPane(width: proxy.size.width, list: proxy.size.width)
                }
            } else {
                let list = GitHubLayout.listWidth(listWidth, in: proxy.size.width)
                let detail = proxy.size.width - list - GitHubLayout.splitterWidth
                let placement = DockPlacement.placement(dockChoice, detailWidth: detail, windowHeight: proxy.size.height, canSpan: true)
                if placement == .bottom { stacked(width: proxy.size.width) } else { split(width: proxy.size.width, placement: placement) }
            }
        }
        .background { openShortcut }
        .overlay(alignment: .bottom) { ActionBannerView(model: actions) }
        .animation(.default, value: actions.banner)
        .sheet(item: $actions.sheet) { GitHubActionSheet(sheet: $0, model: actions) }
        .onAppear {
            terminals.toggleFocus = { toggleTerminalFocus() }
            listWidth = GitHubLayout.repairedWidth(listWidth)
            model.loadCache()
            model.reconcile()
            Task { await model.refresh() }
        }
        .onChange(of: model.listed.map(\.url)) { model.reconcile() }
        .onChange(of: model.selectedURL) { if model.selectedURL == nil { showsDetail = false } }
    }

    private func split(width: CGFloat, placement: DockPlacement.Placement) -> some View {
        let list = GitHubLayout.listWidth(listWidth, in: width)
        return HStack(spacing: 0) {
            listPane(width: width, list: list).frame(width: list)
            splitter(current: list, total: width)
            detailPane(back: nil, placement: placement, column: width - list - GitHubLayout.splitterWidth)
        }
    }

    /// The list and the page on the top, the Claude session across the whole width below them.
    private func stacked(width: Double) -> some View {
        let list = GitHubLayout.listWidth(listWidth, in: width)
        return TerminalSplit(page: model.page, placement: .bottom) {
            HStack(spacing: 0) {
                listPane(width: width, list: list).frame(width: list)
                splitter(current: list, total: width)
                pageView(back: nil, column: width - list - GitHubLayout.splitterWidth)
            }
        }
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
                            listWidth = GitHubLayout.listWidth(start + drag.translation.width, in: total)
                        }
                        .onEnded { _ in dragStart = nil })
            }
    }

    private var openShortcut: some View {
        Group {
            Button("Open in Browser") { model.page.map { NSWorkspace.shared.open(URL(string: $0.pr.url)!) } }
                .keyboardShortcut("o")
            Button("Switch Between List and Terminal") { toggleTerminalFocus() }
                .keyboardShortcut("t", modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    /// The keyboard belongs to one of them at a time: the terminal when it is the first responder, the list otherwise.
    private func toggleTerminalFocus() {
        guard let key = model.page?.pr.url else { return }
        if terminals.terminalHasFocus(key) {
            terminals.releaseTerminal(key)
            focus = nil
            DispatchQueue.main.async { focus = .list }
        } else {
            _ = terminals.focusTerminal(key)
        }
    }

    private func detailPane(back: (() -> Void)?, placement: DockPlacement.Placement, column: Double) -> some View {
        TerminalSplit(page: model.page, placement: placement) { pageView(back: back, column: column) }
    }

    private func pageView(back: (() -> Void)?, column: Double) -> some View {
        Group {
            if let page = model.page {
                GitHubDetailView(page: page, model: model, back: back, column: column)
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

    private func listPane(width: Double, list: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.error, model.enabled, model.hasData { ErrorBanner(error: error) }
            if model.marked.count > 1 {
                MarkedBar(count: model.marked.count, model: actions, close: { actions.beginBulk(.close, model.markedPRs) }, clear: model.clearMarks)
            }
            content(titleLines: GitHubLayout.singleLineRows(listWidth: list) ? 1 : 2)
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
                FlowLayout(spacing: 2) {
                    ForEach(GitHubKind.pageKinds) { kind in
                        Button(kind.tabTitle) { model.kind = kind }
                            .buttonStyle(PillButtonStyle(selected: model.kind == kind))
                    }
                }
                .padding(.top, 8)
                .padding(.leading, -8)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(GitHubLogic.header(count: model.visible.count, kind: model.kind, capped: model.isCapped))
                        .font(.system(size: 22, weight: .medium))
                    if model.filter.state != .open { Text(model.filter.state.rawValue.lowercased()).foregroundStyle(.secondary) }
                    Spacer()
                    MergeablePill(isOn: $mergeable)
                }
                .padding(.top, 8)
                GitHubStatusTabs(selection: $model.filter.status, counts: model.statusCounts)
                    .padding(.top, 6)
                ViewThatFits(in: .horizontal) {
                    searchRow(compact: false)
                    searchRow(compact: true)
                }
                .controlSize(.small)
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private static let gutter: CGFloat = 16

    private func searchRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            SearchField(text: $model.filter.query).frame(minWidth: compact ? nil : 150)
            filtersMenu
            OpenPullRequestButton(model: model, compact: compact)
        }
    }

    private var refreshControls: some View {
        HStack(spacing: 8) {
            if let fetched = model.fetched {
                Text("Updated \(GitHubLogic.updatedText(fetched, now: Date()))").font(.callout).foregroundStyle(.tertiary)
            }
            ClaudeRunningIndicator(model: .shared)
            if terminals.runningCount > 0 {
                Label(EmbeddedTerminal.runningText(terminals.runningCount), systemImage: "circle.fill")
                    .font(.callout).foregroundStyle(.green).labelStyle(.titleAndIcon).lineLimit(1)
            }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.refreshing)
                .help("Fetch your pull requests now")
        }
    }

    /// The rarer filters, out of the way: the state, the repository, the sort and the activity filters.
    private var filtersMenu: some View {
        Menu {
            Picker("State", selection: $model.filter.state) {
                ForEach(GitHubLogic.StateFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Repository", selection: $model.filter.repo) {
                Text("All repositories").tag(String?.none)
                ForEach(model.repos, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Sort by", selection: $model.filter.sort) {
                ForEach(GitHubSort.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            ForEach(GitHubQuickFilter.allCases) { quick in
                Toggle(isOn: quickBinding(quick)) { Label(quick.rawValue, systemImage: quick.icon) }
            }
            Toggle(isOn: $model.filter.hideBotOnly) { Label("Hide bot-only activity", systemImage: "cpu") }
            Divider()
            Button("Reset Filters") { model.filter = model.filter.withoutRefinements }
                .disabled(model.filter.refinements == 0)
        } label: {
            Label(model.filter.refinements == 0 ? "Filters" : "Filters \u{00B7} \(model.filter.refinements)", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("State, repository, sort and activity filters")
    }

    private func quickBinding(_ quick: GitHubQuickFilter) -> Binding<Bool> {
        Binding(get: { model.filter.quick.contains(quick) }, set: { on in
            if on { model.filter.quick.insert(quick) } else { model.filter.quick.remove(quick) }
        })
    }

    @ViewBuilder private func content(titleLines: Int) -> some View {
        if !model.enabled {
            GitHubEmptyState(icon: "arrow.triangle.branch", title: "Your pull requests, in one place",
                       text: "Reads your pull requests through the GitHub CLI. Nothing is uploaded.") {
                Button("Turn On") { model.setEnabled(true) }.buttonStyle(.borderedProminent)
            }
        } else if let error = model.error, !model.hasData {
            ErrorState(error: error, refresh: { Task { await model.refresh() } })
        } else if model.listed.isEmpty {
            GitHubEmptyState(icon: model.refreshing && !model.hasData ? "arrow.clockwise" : "checkmark.circle",
                       title: model.refreshing && !model.hasData ? "Fetching pull requests\u{2026}"
                       : model.filter == GitHubLogic.Filter() ? "No pull requests" : "Nothing matches",
                       text: model.filter == GitHubLogic.Filter() ? nil : "Change the status, the search or the filters.") { EmptyView() }
                .focusable()
                .focused($focus, equals: .list)
                .focusEffectDisabled()
                .onKeyPress(characters: .letters, action: statusKey)
                .onPasteCommand(of: [.plainText, .url]) { _ in pasteLink() }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !model.reviewQueue.isEmpty {
                            section("Waiting for my review", count: model.reviewQueue.count)
                            ForEach(model.reviewQueue) { row($0, showsAuthor: true, titleLines: titleLines) }
                            section("My pull requests", count: model.visible.count)
                        }
                        let watching = model.watching
                        let main = model.visible.dropLast(watching.count)
                        if !watching.isEmpty, !main.isEmpty { section("Reviewing", count: main.count) }
                        ForEach(main) { row($0, showsAuthor: model.reviewer, titleLines: titleLines) }
                        if !watching.isEmpty {
                            section("Watching", count: watching.count)
                            ForEach(watching) { row($0, showsAuthor: true, titleLines: titleLines) }
                        }
                    }
                    .padding(.horizontal, Self.gutter - 8)
                    .padding(.bottom, 20)
                }
                .focusable()
                .focused($focus, equals: .list)
                .focusEffectDisabled()
                .onKeyPress(characters: .letters, action: statusKey)
                .onKeyPress(.upArrow) { step(.previous) }
                .onKeyPress(.downArrow) { step(.next) }
                .onKeyPress(.return) {
                    if model.page != nil { enterDetail() }
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !model.marked.isEmpty else { return .ignored }
                    model.clearMarks()
                    return .handled
                }
                .onPasteCommand(of: [.plainText, .url]) { _ in pasteLink() }
                .onChange(of: model.selectedURL) { if let url = model.selectedURL { proxy.scrollTo(url) } }
            }
        }
    }

    private func row(_ pr: GitHubPR, showsAuthor: Bool, titleLines: Int) -> some View {
        VStack(spacing: 0) {
            PullRequestRow(pr: pr, model: model, selected: pr.url == model.selectedURL, marked: model.marked.contains(pr.url),
                           titleLines: titleLines, showsAuthor: showsAuthor, show: show)
            Divider().padding(.horizontal, Self.gutter)
        }
    }

    private func section(_ title: String, count: Int) -> some View {
        Text("\(title) \u{00B7} \(count)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    /// A, M, W, P, D and H switch the status tab while the list has the keyboard.
    private func statusKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.subtracting(.shift).isEmpty, let key = press.characters.first, let tab = GitHubStatusTab.tab(for: key) else { return .ignored }
        model.filter.status = tab
        return .handled
    }

    /// Command-V on the list opens a pull request link from the clipboard.
    private func pasteLink() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        if model.openPasted(text) { showsDetail = true }
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
    let marked: Bool
    let titleLines: Int
    let showsAuthor: Bool
    let show: (GitHubPR) -> Void
    @ObservedObject private var claude = GitHubClaudeModel.shared
    @ObservedObject private var actions = GitHubActionsModel.shared

    var body: some View {
        PullRequestSummaryRow(pr: pr, showsAuthor: showsAuthor, titleLines: titleLines,
                              status: model.reviewer ? GitHubLogic.status(pr, reviewer: true) : nil)
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(marked ? Color.accentColor.opacity(0.18) : selected ? Color.primary.opacity(0.08) : .clear))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { click() }
            .simultaneousGesture(TapGesture(count: 2).onEnded { if NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty { open(pr.url) } })
            .contextMenu {
                Button("Show Details") { show(pr) }
                Button("Open in Browser") { open(pr.url) }
                Button("Copy Link") { GitHubModel.copy(pr.url) }
                Button("Copy Title") { GitHubModel.copy(pr.copyText) }
                Button("Copy Branch") { model.store?.githubHeadBranch(pr.url).map(GitHubModel.copy) }
                    .disabled(model.store?.githubHeadBranch(pr.url) == nil)
                Button("Open Repository") { open("https://\(GitHubLogic.host)/\(pr.repo)") }
                if model.isWatched(pr) { Button("Stop Watching") { model.stopWatching(pr) } }
                GitHubRowActions(pr: pr, targets: GitHubActions.targets(for: pr, marked: model.marked, in: model.visible), model: actions)
                Divider()
                Button("Ask About This Pull Request\u{2026}") { model.ask(about: pr) }
                Button("Open in Claude Code") { claude.openInClaudeCode(pr) }
                    .disabled(claude.checkout(pr) == nil)
                Menu("Open in Claude") {
                    ForEach(GitHubClaude.Preset.allCases) { preset in
                        Button(preset.title) { claude.openInClaude(pr, nil, preset) }
                    }
                }
                Menu("Ask Claude") {
                    ForEach(GitHubClaude.Preset.headless) { preset in
                        Button(preset.title) { claude.ask(pr, nil, preset) }
                    }
                }
            }
            .help(pr.url)
    }

    private func open(_ url: String) {
        URL(string: url).map { NSWorkspace.shared.open($0) }
    }

    /// Command adds or removes the row from the marked ones, shift marks the rows up to it; a plain click selects it alone.
    private func click() {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { model.toggleMark(pr) } else if flags.contains(.shift) { model.markRange(to: pr) } else {
            model.clearMarks()
            show(pr)
        }
    }
}

/// Opens a pull request from a pasted link or `owner/repo#number`, e.g. one a colleague sent, and keeps it on the Reviewing tab.
private struct OpenPullRequestButton: View {
    @ObservedObject var model: GitHubModel
    var compact = false
    @State private var showing = false
    @State private var text = ""

    var body: some View {
        Button { showing = true } label: {
            if compact { Image(systemName: "link") } else { Label("Open PR\u{2026}", systemImage: "link") }
        }
        .fixedSize()
        .help("Open a pull request from its link; it stays on the Reviewing tab as Watching")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open a pull request").font(.headline)
                TextField("https://github.com/owner/repo/pull/123 or owner/repo#123", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
                    .onSubmit(open)
                Text(invalid ? "Paste a GitHub pull request link or owner/repo#number." : "It stays on the Reviewing tab as Watching until a few days after it is merged or closed.")
                    .font(.caption)
                    .foregroundStyle(invalid ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { showing = false }.keyboardShortcut(.cancelAction)
                    Button("Open", action: open).keyboardShortcut(.defaultAction).disabled(target == nil)
                }
            }
            .padding(14)
            .frame(width: 388)
            .onAppear { text = NSPasteboard.general.string(forType: .string).flatMap { GitHubLink.pasted($0) != nil ? $0 : nil } ?? "" }
        }
    }

    private var target: GitHubLink.Target? { GitHubLink.pasted(text) }
    private var invalid: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty && target == nil }

    private func open() {
        guard target != nil, model.openPasted(text) else { return }
        showing = false
        text = ""
    }
}

/// The status tabs with their counts, in the notch bar and on the GitHub page. Empty tabs are left out.
struct GitHubStatusTabs: View {
    @Binding var selection: GitHubStatusTab
    let counts: [GitHubStatusTab: Int]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(tabs) { tab in
                Button { selection = tab } label: { label(tab) }
                    .help("\(tab.title) (\(String(tab.key).uppercased()))")
                    .buttonStyle(NotchChipStyle(selected: selection == tab))
            }
        }
    }

    private var tabs: [GitHubStatusTab] {
        GitHubStatusTab.allCases.filter { $0 == .all || $0 == selection || (counts[$0] ?? 0) > 0 }
    }

    private func label(_ tab: GitHubStatusTab) -> some View {
        HStack(spacing: 4) {
            if let status = tab.status { Circle().fill(status.color).frame(width: 6, height: 6) }
            Text(tab.title)
            Text("\(counts[tab] ?? 0)").foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}

struct PRStatusDot: View {
    let pr: GitHubPR
    var status: GitHubStatus?

    var body: some View {
        if let status = status ?? GitHubLogic.status(pr) {
            Circle().fill(status.color).frame(width: 7, height: 7).help(status.rawValue)
        }
    }
}

extension GitHubStatus {
    var color: Color {
        switch self {
        case .myTurn: return .accentColor
        case .waiting: return .orange
        case .approved: return .green
        case .draft: return .secondary
        case .onHold: return .brown
        }
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
            ClaudeSettingsRows(model: .shared)
            Divider().padding(.leading, 14)
            ActionSettingsRows(model: .shared)
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
