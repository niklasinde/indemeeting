import AppKit
import Combine
import SwiftUI

@MainActor
final class AskPanel: ObservableObject {
    static let shared = AskPanel()
    static let shownKey = "showAskBar"

    @Published private(set) var expanded = false
    @Published private(set) var barHeight: CGFloat = NSStatusBar.system.thickness
    @Published private(set) var notchWidth: CGFloat = 0
    private lazy var panel = makePanel()
    private var github: AnyCancellable?

    func start() {
        UserDefaults.standard.register(defaults: [Self.shownKey: true])
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AskPanel.shared.position() }
        }
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AskPanel.shared.refresh() }
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { AskPanel.shared.collapse() }
        }
        github = GitHubModel.shared.objectWillChange.sink { _ in
            MainActor.assumeIsolated { if AskPanel.shared.expanded { AskPanel.shared.position() } }
        }
        refresh()
    }

    func expand() {
        expanded = true
        position()
        panel.makeKeyAndOrderFront(nil)
    }

    func collapse() {
        guard expanded else { return }
        expanded = false
        position()
    }

    private func refresh() {
        if UserDefaults.standard.bool(forKey: Self.shownKey) {
            position()
            panel.orderFrontRegardless()
        } else {
            collapse()
            panel.orderOut(nil)
        }
    }

    private func position() {
        guard let screen = NSScreen.screens.first, let content = panel.contentView else { return }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        barHeight = menuBar > 0 ? menuBar : NSStatusBar.system.thickness
        var centre = screen.frame.midX
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
            centre = (left.maxX + right.minX) / 2
        } else {
            notchWidth = 0
        }
        DispatchQueue.main.async {
            let size = content.fittingSize
            self.panel.setFrame(NSRect(x: centre - size.width / 2, y: screen.frame.maxY - size.height,
                                       width: size.width, height: size.height), display: true)
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
        let host = NSHostingView(rootView: AskPanelView(panel: self))
        host.sizingOptions = .intrinsicContentSize
        panel.contentView = host
        return panel
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct AskPanelView: View {
    static let wing: CGFloat = 100
    @ObservedObject var panel: AskPanel

    var body: some View {
        Group {
            if panel.expanded {
                VStack(spacing: 12) {
                    AskBar(onSubmit: panel.collapse)
                    WaitingPullRequests(onOpen: panel.collapse)
                }
                    .frame(width: 560)
                    .padding(.top, panel.barHeight)
                    .padding(.bottom, 14)
                    .padding(.horizontal, 14)
                    .onExitCommand(perform: panel.collapse)
            } else {
                HStack {
                    BrandMark.jira.scaledToFit().frame(width: 17, height: 17)
                    Spacer()
                    BrandMark.gitHub.scaledToFit().foregroundStyle(.white).frame(width: 17, height: 17)
                }
                .padding(.horizontal, 14)
                .frame(width: panel.notchWidth + 2 * Self.wing, height: panel.barHeight)
                .contentShape(Rectangle())
                .onTapGesture(perform: panel.expand)
            }
        }
        .background(UnevenRoundedRectangle(bottomLeadingRadius: panel.expanded ? 22 : 10,
                                           bottomTrailingRadius: panel.expanded ? 22 : 10, style: .continuous).fill(Color.black))
        .environment(\.colorScheme, .dark)
        .fixedSize()
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
