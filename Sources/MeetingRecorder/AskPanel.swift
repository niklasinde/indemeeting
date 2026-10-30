import AppKit
import SwiftUI

@MainActor
final class AskPanel: ObservableObject {
    static let shared = AskPanel()
    static let shownKey = "showAskBar"

    @Published private(set) var expanded = false
    @Published private(set) var barHeight: CGFloat = NSStatusBar.system.thickness
    @Published private(set) var notchWidth: CGFloat = 0
    private lazy var panel = makePanel()

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
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        panel.setFrame(NSRect(x: centre - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height),
                       display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: AskPanelView(panel: self))
        return panel
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct AskPanelView: View {
    static let wing: CGFloat = 140
    @ObservedObject var panel: AskPanel

    var body: some View {
        Group {
            if panel.expanded {
                AskBar(onSubmit: panel.collapse)
                    .frame(width: 560)
                    .padding(.top, panel.barHeight)
                    .padding(.bottom, 14)
                    .padding(.horizontal, 14)
                    .onExitCommand(perform: panel.collapse)
            } else {
                HStack {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 18, height: 18)
                    Spacer()
                    Button(action: panel.expand) {
                        Image(systemName: "bubble.left").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
