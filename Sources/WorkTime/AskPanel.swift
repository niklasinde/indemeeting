import AppKit
import Combine
import SwiftUI

@MainActor
final class AskPanel {
    static let shared = AskPanel()
    static let shownKey = "showAskBar"

    private var bars: [NotchBar] = []
    private var lists: AnyCancellable?

    func start() {
        UserDefaults.standard.register(defaults: [Self.shownKey: true])
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AskPanel.shared.screensChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AskPanel.shared.screensChanged() }
        }
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AskPanel.shared.refresh() }
        }
        let models = [GitHubModel.shared.objectWillChange, JiraModel.shared.objectWillChange, TodoModel.shared.objectWillChange,
                      SlackModel.shared.objectWillChange, NotchPanelsModel.shared.objectWillChange, ResumeModel.shared.objectWillChange]
        lists = Publishers.MergeMany(models).sink { _ in
            MainActor.assumeIsolated { AskPanel.shared.bars.filter(\.expanded).forEach { $0.position() } }
        }
        rebuild()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.screensChanged() }
    }

    /// Opens the bar on the main screen on the resume card alone, for a few seconds unless the pointer comes over it.
    func peekResume() {
        guard UserDefaults.standard.bool(forKey: Self.shownKey) else { return }
        (bars.first { $0.screen == NSScreen.main } ?? bars.first)?.peek()
    }

    private func screensChanged() {
        guard bars.map(\.screen) == NSScreen.screens else { return rebuild() }
        bars.forEach { $0.position() }
    }

    private func rebuild() {
        bars.forEach { $0.close() }
        bars = NSScreen.screens.map { NotchBar(screen: $0) }
        refresh()
    }

    private func refresh() {
        NotchPanelsModel.shared.reload()
        let shown = UserDefaults.standard.bool(forKey: Self.shownKey)
        bars.forEach { $0.show(shown) }
    }
}

@MainActor
final class NotchBar: ObservableObject {
    static let opening = Animation.spring(response: 0.2, dampingFraction: 0.85)
    static let closing = Animation.easeIn(duration: 0.15)
    @Published private(set) var expanded = false
    @Published private(set) var revealed = false
    @Published private(set) var list = NotchPanelID.gitHub
    @Published private(set) var barHeight: CGFloat = NSStatusBar.system.thickness
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var listCap: CGFloat = 420
    @Published private(set) var hasNotch = false
    let screen: NSScreen
    private lazy var panel = makePanel()
    private var resign: NSObjectProtocol?
    private var resized: NSObjectProtocol?
    @Published private(set) var openedByHover = false
    @Published private(set) var peeking = false
    private var typing = false
    private var held = false
    private var pendingCollapse: DispatchWorkItem?

    init(screen: NSScreen) {
        self.screen = screen
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
        resized = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    func expand(_ list: NotchPanelID? = nil, byHover: Bool = false) {
        let shown = NotchPanelsModel.shared.shown
        if let list {
            self.list = list
        } else if !shown.contains(self.list), let first = shown.first {
            self.list = first
        }
        peeking = false
        if expanded && revealed {
            if !byHover { openedByHover = false }
            return
        }
        openedByHover = byHover
        pendingCollapse?.cancel()
        expanded = true
        position { withAnimation(Self.opening) { self.revealed = true } }
        if byHover { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
    }

    func peek(for seconds: TimeInterval = 8) {
        guard !expanded else { return }
        expand(byHover: true)
        peeking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.peeking, self.openedByHover, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.collapse()
        }
    }

    /// A click inside makes the panel key, so the field, the hotkeys and Esc work; it then stays open until Esc or a click outside.
    func clicked() {
        openedByHover = false
        pendingCollapse?.cancel()
    }

    func collapse() {
        guard expanded else { return }
        pendingCollapse?.cancel()
        typing = false
        held = false
        peeking = false
        withAnimation(Self.closing) {
            revealed = false
        } completion: { [weak self] in
            guard let self, !self.revealed else { return }
            self.expanded = false
            self.giveBackKeyboard()
            self.position()
        }
    }

    /// Ordering the key panel out and back hands the keyboard to the window that had it, without activating this app.
    private func giveBackKeyboard() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    func hover(_ inside: Bool) {
        pendingCollapse?.cancel()
        guard !inside, expanded, openedByHover, !typing, !held else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.collapse()
        }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func type(_ text: String) {
        typing = !text.isEmpty
        if typing { pendingCollapse?.cancel() }
    }

    /// While no field has the keyboard, a panel's letter (g, j, t, s) switches the list, and in the GitHub list a letter switches the status tab.
    func key(_ key: Character) -> Bool {
        guard expanded else { return false }
        if let list = NotchPanelID.hotkey(key), NotchPanelsModel.shared.shown.contains(list) {
            self.list = list
            return true
        }
        guard list == .gitHub, let tab = GitHubStatusTab.tab(for: key) else { return false }
        UserDefaults.standard.set(tab.rawValue, forKey: GitHubModel.notchStatusKey)
        return true
    }

    func hold(_ on: Bool) {
        held = on
        if on { pendingCollapse?.cancel() }
    }

    func show(_ shown: Bool) {
        if shown {
            position()
            panel.orderFrontRegardless()
        } else {
            collapse()
            panel.orderOut(nil)
        }
    }

    func close() {
        [resign, resized].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
        panel.orderOut(nil)
    }

    /// Where the bar sits on a screen: centred on the notch if it has one, as tall as the menu bar.
    static func metrics(of screen: NSScreen) -> (centre: CGFloat, barHeight: CGFloat, notchWidth: CGFloat?) {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let barHeight = menuBar > 0 ? menuBar : NSStatusBar.system.thickness
        let notch = NotchLayout.notch(screen: screen.frame, left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        return (notch.centre, barHeight, notch.width)
    }

    func position(then: @escaping () -> Void = {}) {
        guard let content = panel.contentView else { return }
        let metrics = Self.metrics(of: screen)
        barHeight = metrics.barHeight
        listCap = NotchLayout.listCap(visibleHeight: screen.visibleFrame.height)
        hasNotch = metrics.notchWidth != nil
        notchWidth = metrics.notchWidth ?? 200
        DispatchQueue.main.async {
            self.place(size: content.fittingSize)
            then()
        }
    }

    /// The hosting view resizes the panel from its bottom-left corner when the content changes, so every resize is put back on the notch.
    private func place(size: NSSize? = nil) {
        let frame = NotchLayout.panelFrame(screen: screen.frame, left: screen.auxiliaryTopLeftArea,
                                           right: screen.auxiliaryTopRightArea, size: size ?? panel.frame.size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.collapse() }
        panel.onKey = { [weak self] in self?.key($0) ?? false }
        panel.onClick = { [weak self] in self?.clicked() }
        panel.onScroll = { [weak self] in self?.pendingCollapse?.cancel() }
        let host = NSHostingView(rootView: AskPanelView(panel: self))
        host.sizingOptions = .intrinsicContentSize
        panel.contentView = host
        return panel
    }

    #if DEBUG
    /// The bar's view in a given state, for the previews; the panel itself stays hidden.
    func sample(list: NotchPanelID?, hasNotch: Bool, peeking: Bool = false) -> AnyView {
        self.peeking = peeking
        self.hasNotch = hasNotch
        notchWidth = hasNotch ? 188 : 200
        barHeight = 32
        listCap = NotchLayout.listCap(visibleHeight: screen.visibleFrame.height)
        expanded = list != nil || peeking
        revealed = list != nil || peeking
        openedByHover = true
        if let list { self.list = list }
        return AnyView(AskPanelView(panel: self))
    }
    #endif
}

private final class KeyablePanel: NSPanel {
    var onCancel: () -> Void = {}
    var onKey: (Character) -> Bool = { _ in false }
    var onClick: () -> Void = {}
    var onScroll: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel { onScroll() }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if !isKeyWindow { makeKey() }
            onClick()
        }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return onCancel() }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plain, let key = event.charactersIgnoringModifiers?.first, onKey(key) { return }
        super.keyDown(with: event)
    }
}

private struct AskPanelView: View {
    static let wing: CGFloat = 34
    @ObservedObject var panel: NotchBar
    @ObservedObject private var panels = NotchPanelsModel.shared
    @ObservedObject private var slack = SlackModel.shared
    @ObservedObject private var resume = ResumeModel.shared

    var body: some View {
        let shown = panels.shown
        let wings = NotchWings.split(shown)
        let wingWidth = NotchWings.width(shown, icon: Self.wing)
        let collapsedWidth = panel.notchWidth + 2 * wingWidth
        ZStack(alignment: .top) {
            if panel.expanded {
                VStack(spacing: 12) {
                    if panel.hasNotch && !wings.middle.isEmpty {
                        marks(wings.middle, height: 22).padding(.bottom, -8)
                    }
                    if let card = resume.card { ResumeCardView(card: card, onClose: panel.collapse) }
                    if !panel.peeking { AskBar(onSubmit: panel.collapse, onType: panel.type, autofocus: !panel.openedByHover) }
                    if !panel.peeking && shown.contains(panel.list) {
                        switch panel.list {
                        case .gitHub: WaitingPullRequests(onOpen: panel.collapse, onHold: panel.hold)
                        case .jira: AssignedTickets(onOpen: panel.collapse)
                        case .todo: TodoNotchList(onHold: panel.hold, onType: panel.type)
                        case .slack: SlackNotchList(onOpen: panel.collapse)
                        }
                    }
                }
                    .frame(width: 560)
                    .padding(.top, panel.barHeight)
                    .padding(.bottom, 14)
                    .padding(.horizontal, 14)
                    .opacity(panel.revealed ? 1 : 0)
                    .offset(y: panel.revealed ? 0 : -12)
                    .animation(panel.revealed ? .easeOut(duration: 0.12).delay(0.02) : .easeIn(duration: 0.08), value: panel.revealed)
                    .onExitCommand(perform: panel.collapse)
                    .background(HoverArea(onHover: panel.hover))
            }
            HStack(spacing: 0) {
                marks(wings.left).frame(width: wingWidth, alignment: .leading)
                Spacer()
                if !panel.hasNotch && !wings.middle.isEmpty {
                    marks(wings.middle)
                    Spacer()
                }
                marks(wings.right).frame(width: wingWidth, alignment: .trailing)
            }
            .frame(width: collapsedWidth, height: panel.barHeight)
            .contentShape(Rectangle())
            .onTapGesture { panel.expand() }
            if !panel.expanded && resume.unseen {
                ResumeNotchDot { panel.peek() }.padding(.top, panel.barHeight)
            }
        }
        .background(alignment: .top) {
            GeometryReader { geo in
                UnevenRoundedRectangle(bottomLeadingRadius: panel.revealed ? 22 : 10,
                                       bottomTrailingRadius: panel.revealed ? 22 : 10, style: .continuous)
                    .fill(Color.black)
                    .frame(width: panel.revealed ? geo.size.width : collapsedWidth,
                           height: panel.revealed ? geo.size.height : panel.barHeight)
                    .frame(maxWidth: .infinity)
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.notchListCap, panel.listCap)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func marks(_ ids: [NotchPanelID], height: CGFloat? = nil) -> some View {
        HStack(spacing: 0) {
            ForEach(ids) { mark($0, height: height) }
        }
    }

    private func mark(_ list: NotchPanelID, height: CGFloat? = nil) -> some View {
        list.icon.scaledToFit()
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .overlay(alignment: .topTrailing) {
                if list == .slack && slack.badge > 0 { NotchBadge(count: slack.badge).offset(x: 7, y: -5) }
            }
            .opacity(!panel.expanded || panel.list == list ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: panel.list)
            .frame(width: Self.wing, height: height ?? panel.barHeight)
            .contentShape(Rectangle())
            .onTapGesture { panel.expand(list) }
            .background(HoverArea { if $0 { panel.expand(list, byHover: true) } })
    }
}

extension EnvironmentValues {
    @Entry var notchListCap: CGFloat = 420
}

/// The rows of a notch list, as tall as they are up to the space left on screen, then scrolling. Headers and chips go above it.
struct NotchScroll<Content: View>: View {
    @Environment(\.notchListCap) private var cap
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content.onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        }
        .scrollIndicators(.automatic)
        .frame(height: min(height, cap))
    }
}

private struct NotchBadge: View {
    let count: Int

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 8, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 3)
            .frame(minWidth: 11, minHeight: 11)
            .background(Capsule().fill(Color.red))
    }
}

private struct HoverArea: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.onHover = onHover }

    final class TrackingView: NSView {
        var onHover: (Bool) -> Void = { _ in }

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .assumeInside], owner: self))
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
    }
}

private struct AssignedTickets: View {
    let onOpen: () -> Void
    @ObservedObject private var model = JiraModel.shared
    @ObservedObject private var claude = GitHubClaudeModel.shared
    @ObservedObject private var github = GitHubModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.ready {
                Label { Text(header) } icon: { BrandMark.jira.scaledToFit().frame(width: 12, height: 12) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                if let error = model.error, model.tickets.isEmpty {
                    Text(error.message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                NotchScroll {
                    VStack(alignment: .leading, spacing: 2) { ForEach(model.tickets, content: row) }
                }
            } else {
                Button(action: setUp) {
                    Label { Text("Set up Jira in Settings") } icon: { BrandMark.jira.scaledToFit().frame(width: 12, height: 12) }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private func row(_ ticket: JiraTicket) -> some View {
        HStack(spacing: 0) {
            Button { open(ticket) } label: {
                HStack(spacing: 8) {
                    Text(ticket.key).foregroundStyle(.secondary).fixedSize()
                    Text(ticket.summary).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    Text(ticket.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let pr = claude.pullRequest(for: ticket.key) { OpenInClaudeCodeButton(pr: pr).padding(.trailing, 8) }
        }
        .contextMenu {
            Button("Open in Agent") {
                onOpen()
                TopicAgentStore.shared.open(ticket: ticket)
            }
        }
    }

    private var header: String {
        if model.fetched != nil { return JiraLogic.headline(total: model.total, shown: model.tickets.count) }
        return model.error == nil ? "Fetching your tickets\u{2026}" : "Jira"
    }

    private func open(_ ticket: JiraTicket) {
        onOpen()
        if let url = model.browseURL(ticket) { NSWorkspace.shared.open(url) }
    }

    private func setUp() {
        onOpen()
        SettingsWindow.shared.show(anchor: .jira)
    }
}

enum BrandMark {
    static let jira = image("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
        <path fill="#2684FF" d="M30.4 15.1 17.6 2.3 16 .7 6.4 10.3 1.6 15.1a1.3 1.3 0 0 0 0 1.8l8.8 8.8L16 31.3l9.6-9.6.2-.2 4.6-4.6a1.3 1.3 0 0 0 0-1.8ZM16 20.4 11.6 16 16 11.6l4.4 4.4Z"/>
        <path fill="#0052CC" d="M16 11.6a7.4 7.4 0 0 1 0-10.4L6.4 10.8l5.2 5.2Z"/>
        <path fill="#0052CC" d="m20.4 16-4.4 4.4a7.4 7.4 0 0 1 0 10.4l9.6-9.6Z"/>
        </svg>
        """, template: false)
    static let gitHub = image("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>
        """, template: true)
    static let slack = image("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        <path fill="#E01E5A" d="M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313z"/>
        <path fill="#36C5F0" d="M8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312z"/>
        <path fill="#2EB67D" d="M18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312z"/>
        <path fill="#ECB22E" d="M15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z"/>
        </svg>
        """, template: false)

    private static func image(_ svg: String, template: Bool) -> Image {
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = template
        return Image(nsImage: image).resizable()
    }
}
