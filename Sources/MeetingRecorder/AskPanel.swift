import AppKit
import Combine
import SwiftUI

@MainActor
final class AskPanel {
    static let shared = AskPanel()
    static let shownKey = "showAskBar"

    enum List {
        case gitHub
        case jira
    }

    private var bars: [NotchBar] = []
    private var lists: AnyCancellable?

    func start() {
        UserDefaults.standard.register(defaults: [Self.shownKey: true])
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AskPanel.shared.rebuild() }
        }
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AskPanel.shared.refresh() }
        }
        lists = GitHubModel.shared.objectWillChange.merge(with: JiraModel.shared.objectWillChange).sink { _ in
            MainActor.assumeIsolated { AskPanel.shared.bars.filter(\.expanded).forEach { $0.position() } }
        }
        rebuild()
    }

    private func rebuild() {
        bars.forEach { $0.close() }
        bars = NSScreen.screens.map { NotchBar(screen: $0) }
        refresh()
    }

    private func refresh() {
        let shown = UserDefaults.standard.bool(forKey: Self.shownKey)
        bars.forEach { $0.show(shown) }
    }
}

@MainActor
final class NotchBar: ObservableObject {
    static let motion = Animation.spring(duration: 0.35, bounce: 0.15)
    @Published private(set) var expanded = false
    @Published private(set) var revealed = false
    @Published private(set) var list = AskPanel.List.gitHub
    @Published private(set) var barHeight: CGFloat = NSStatusBar.system.thickness
    @Published private(set) var notchWidth: CGFloat = 0
    private let screen: NSScreen
    private lazy var panel = makePanel()
    private var resign: NSObjectProtocol?
    private var openedByHover = false
    private var typing = false
    private var pendingCollapse: DispatchWorkItem?

    init(screen: NSScreen) {
        self.screen = screen
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
    }

    func expand(_ list: AskPanel.List? = nil, byHover: Bool = false) {
        if byHover && revealed { return }
        if let list { self.list = list }
        openedByHover = byHover
        pendingCollapse?.cancel()
        expanded = true
        position { withAnimation(Self.motion) { self.revealed = true } }
        panel.makeKeyAndOrderFront(nil)
    }

    func collapse() {
        guard expanded else { return }
        pendingCollapse?.cancel()
        typing = false
        withAnimation(Self.motion) {
            revealed = false
        } completion: { [weak self] in
            guard let self, !self.revealed else { return }
            self.expanded = false
            self.position()
        }
    }

    func hover(_ inside: Bool) {
        pendingCollapse?.cancel()
        guard !inside, expanded, openedByHover, !typing else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func type(_ text: String) {
        typing = !text.isEmpty
        if typing { pendingCollapse?.cancel() }
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
        if let resign { NotificationCenter.default.removeObserver(resign) }
        panel.orderOut(nil)
    }

    func position(then: @escaping () -> Void = {}) {
        guard let content = panel.contentView else { return }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        barHeight = menuBar > 0 ? menuBar : NSStatusBar.system.thickness
        var centre = screen.frame.midX
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
            centre = (left.maxX + right.minX) / 2
        } else {
            notchWidth = 200
        }
        let top = screen.frame.maxY
        DispatchQueue.main.async {
            let size = content.fittingSize
            self.panel.setFrame(NSRect(x: centre - size.width / 2, y: top - size.height,
                                       width: size.width, height: size.height), display: true)
            then()
        }
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
        let host = NSHostingView(rootView: AskPanelView(panel: self))
        host.sizingOptions = .intrinsicContentSize
        panel.contentView = host
        return panel
    }
}

private final class KeyablePanel: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func keyDown(with event: NSEvent) {
        event.keyCode == 53 ? onCancel() : super.keyDown(with: event)
    }
}

private struct AskPanelView: View {
    static let wing: CGFloat = 34
    @ObservedObject var panel: NotchBar

    var body: some View {
        let collapsedWidth = panel.notchWidth + 2 * Self.wing
        ZStack(alignment: .top) {
            if panel.expanded {
                VStack(spacing: 12) {
                    AskBar(onSubmit: panel.collapse, onType: panel.type)
                    switch panel.list {
                    case .gitHub: WaitingPullRequests(onOpen: panel.collapse)
                    case .jira: AssignedTickets(onOpen: panel.collapse)
                    }
                }
                    .frame(width: 560)
                    .padding(.top, panel.barHeight)
                    .padding(.bottom, 14)
                    .padding(.horizontal, 14)
                    .opacity(panel.revealed ? 1 : 0)
                    .offset(y: panel.revealed ? 0 : -12)
                    .animation(panel.revealed ? .easeOut(duration: 0.22).delay(0.08) : .easeIn(duration: 0.12), value: panel.revealed)
                    .onExitCommand(perform: panel.collapse)
                    .background(HoverArea(onHover: panel.hover))
            }
            HStack {
                mark(BrandMark.jira, list: .jira)
                Spacer()
                mark(BrandMark.gitHub.foregroundStyle(.white), list: .gitHub)
            }
            .padding(.horizontal, 4)
            .frame(width: collapsedWidth, height: panel.barHeight)
            .contentShape(Rectangle())
            .onTapGesture { panel.expand() }
            .opacity(panel.revealed ? 0 : 1)
            .animation(panel.revealed ? .easeIn(duration: 0.1) : .easeOut(duration: 0.15).delay(0.18), value: panel.revealed)
            .allowsHitTesting(!panel.expanded)
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
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func mark(_ image: some View, list: AskPanel.List) -> some View {
        image.scaledToFit()
            .frame(width: 17, height: 17)
            .padding(6)
            .contentShape(Rectangle())
            .onTapGesture { panel.expand(list) }
            .background(HoverArea { if $0 { panel.expand(list, byHover: true) } })
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

private struct WaitingPullRequests: View {
    let onOpen: () -> Void
    @ObservedObject private var model = GitHubModel.shared

    var body: some View {
        let created = model.enabled ? GitHubLogic.filter(model.prs[.created] ?? [], GitHubLogic.Filter()) : []
        let prs = GitHubLogic.waitingFirst(created)
        if !prs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label { Text("\(created.count) created") } icon: { BrandMark.gitHub.scaledToFit().frame(width: 12, height: 12) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                ForEach(prs) { pr in
                    Button { open(pr) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(pr.repo) #\(String(pr.number))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(pr.title).lineLimit(1).truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .trailing) { StatusMark(pr: pr) }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func open(_ pr: GitHubPR) {
        onOpen()
        SessionsModel.shared.showGitHub?(GitHubLink.Target(repo: pr.repo, number: pr.number))
    }
}

private struct AssignedTickets: View {
    let onOpen: () -> Void
    @ObservedObject private var model = JiraModel.shared

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
                ForEach(model.tickets.prefix(6)) { ticket in
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
        SettingsWindow.shared.show(tab: .activity, anchor: .jira)
    }
}

private enum BrandMark {
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

    private static func image(_ svg: String, template: Bool) -> Image {
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = template
        return Image(nsImage: image).resizable()
    }
}
