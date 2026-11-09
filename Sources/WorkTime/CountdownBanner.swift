import AppKit
import Carbon
import SwiftUI

/// "Recording starts in 5 · Cancel" under the notch bar on every screen. The panels never take focus, so Esc is a
/// global hotkey while the banner shows.
@MainActor
final class CountdownBanner: ObservableObject {
    @Published private(set) var text = ""
    private var panels: [ClickPanel] = []
    private var escape: GlobalHotKey?
    private var screens: NSObjectProtocol?
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func show(_ text: String) {
        let changed = self.text != text
        self.text = text
        guard panels.isEmpty else {
            if changed { DispatchQueue.main.async { self.panels.forEach(self.position) } }
            return
        }
        panels = NSScreen.screens.map(makePanel)
        escape = GlobalHotKey(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in self?.onCancel() }
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let text = self.text
                self.hide()
                self.show(text)
            }
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        escape?.unregister()
        escape = nil
        if let screens { NotificationCenter.default.removeObserver(screens) }
        screens = nil
    }

    private func position(_ panel: ClickPanel) {
        guard let content = panel.contentView else { return }
        let metrics = NotchBar.metrics(of: panel.home)
        let size = content.fittingSize
        panel.setFrame(NSRect(x: metrics.centre - size.width / 2, y: panel.home.frame.maxY - metrics.barHeight - 8 - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private func makePanel(screen: NSScreen) -> ClickPanel {
        let panel = ClickPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onClick = { [weak self] in self?.onCancel() }
        let host = NSHostingView(rootView: CountdownBannerView(banner: self))
        host.sizingOptions = .intrinsicContentSize
        panel.contentView = host
        panel.home = screen
        position(panel)
        panel.orderFrontRegardless()
        return panel
    }
}

private final class ClickPanel: NSPanel {
    var onClick: () -> Void = {}
    var home: NSScreen!
    override var canBecomeKey: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { return onClick() }
        super.sendEvent(event)
    }
}

private struct CountdownBannerView: View {
    @ObservedObject var banner: CountdownBanner

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text(banner.text).monospacedDigit()
            Text("\u{00B7}").foregroundStyle(.secondary)
            Text("Cancel").foregroundStyle(.secondary)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}
