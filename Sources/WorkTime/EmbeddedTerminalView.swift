import SwiftUI

#if canImport(SwiftTerm)
import AppKit

/// SwiftTerm's view for a session. The view is the session's own, so selecting another pull request and coming back shows the
/// same screen and scrollback; keys go to it only while it is the first responder.
struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    @AppStorage(EmbeddedTerminal.fontSizeKey) private var fontSize = EmbeddedTerminal.defaultFontSize

    func makeNSView(context: Context) -> ClaudeTerminalView {
        let view = session.view
        view.removeFromSuperview()
        configure(view)
        return view
    }

    func updateNSView(_ view: ClaudeTerminalView, context: Context) { configure(view) }

    private func configure(_ view: ClaudeTerminalView) {
        let size = EmbeddedTerminal.fontSize(fontSize)
        if view.font.pointSize != size { view.font = Self.font(size) }
        view.apply(TerminalTheme.palette(for: view.effectiveAppearance))
    }

    static func font(_ size: Double) -> NSFont {
        EmbeddedTerminal.fontName { NSFont(name: $0, size: size) != nil }.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// The terminal's colours, derived from the window surface the page sits on in the same appearance.
enum TerminalTheme {
    static func palette(for appearance: NSAppearance) -> EmbeddedTerminal.Palette {
        EmbeddedTerminal.palette(surface: NSColor.windowBackgroundColor.hex(in: appearance), accent: NSColor.controlAccentColor.hex(in: appearance))
    }
}

extension NSColor {
    func hex(in appearance: NSAppearance) -> UInt32 {
        var value: UInt32 = 0
        appearance.performAsCurrentDrawingAppearance {
            guard let color = usingColorSpace(.sRGB) else { return }
            func channel(_ component: CGFloat) -> UInt32 { UInt32((component * 255).rounded()) }
            value = channel(color.redComponent) << 16 | channel(color.greenComponent) << 8 | channel(color.blueComponent)
        }
        return value
    }
}

extension EmbeddedTerminal.Activity {
    var color: Color {
        switch self {
        case .working: return .green
        case .idle: return .secondary.opacity(0.5)
        case .ended: return .red
        }
    }

    var help: String {
        switch self {
        case .working: return "Claude is working"
        case .idle: return "Claude is idle"
        case .ended: return "Claude has ended"
        }
    }
}

/// The page with its terminal: beside it in a wide window, and below it otherwise, where the terminal is the bottom part of the
/// column and shows its start while no session is open. A handle resizes it.
struct TerminalSplit<Page: View>: View {
    let page: GitHubDetailModel?
    let width: Double
    /// The terminal is a bottom half under the whole content, whatever the width.
    var stacked = false
    @ViewBuilder let content: Page
    @ObservedObject private var model = EmbeddedTerminalModel.shared
    @AppStorage(EmbeddedTerminal.rightSizeKey) private var rightSize = EmbeddedTerminal.defaultRight
    @AppStorage(EmbeddedTerminal.belowSizeKey) private var belowSize = EmbeddedTerminal.defaultBelow
    @State private var dragStart: Double?

    var body: some View {
        if let page { docked(page) } else { content }
    }

    private func docked(_ page: GitHubDetailModel) -> some View {
        let key = page.pr.url
        let placement = stacked ? EmbeddedTerminal.Placement.below : EmbeddedTerminal.placement(width: width)
        return GeometryReader { proxy in
            if placement == .right, model.isShown(key), let session = model.session(for: key) {
                let length = EmbeddedTerminal.paneLength(rightSize, placement: .right, available: proxy.size.width)
                HStack(spacing: 0) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    handle(horizontal: true, current: length)
                    TerminalPane(session: session, model: model).id(key).frame(width: length)
                }
            } else if placement == .below {
                let length = EmbeddedTerminal.paneLength(belowSize, placement: .below, available: proxy.size.height)
                VStack(spacing: 0) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    handle(horizontal: false, current: length)
                    TerminalDock(page: page, model: model).frame(height: length)
                }
            } else {
                content
            }
        }
    }

    private func handle(horizontal: Bool, current: Double) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? 9 : nil, height: horizontal ? nil : 9)
                    .contentShape(Rectangle())
                    .pointerStyle(horizontal ? .columnResize : .rowResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? current
                            dragStart = start
                            let size = start - (horizontal ? drag.translation.width : drag.translation.height)
                            if horizontal { rightSize = size } else { belowSize = size }
                        }
                        .onEnded { _ in dragStart = nil })
            }
    }
}

/// The bottom part of the page: the Claude terminal, or while none is open what can start one, with the Open in Claude choices.
struct TerminalDock: View {
    @ObservedObject var page: GitHubDetailModel
    @ObservedObject var model: EmbeddedTerminalModel
    @ObservedObject private var claude = GitHubClaudeModel.shared

    var body: some View {
        let key = page.pr.url
        if let session = model.session(for: key), model.isShown(key) {
            TerminalPane(session: session, model: model).id(key)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "apple.terminal").font(.system(size: 22)).foregroundStyle(.tertiary)
                Text(model.hasSession(key) ? "The Claude terminal is hidden. Claude keeps running in it." : "No Claude session for this pull request.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    if model.hasSession(key) { Button("Show Terminal") { model.setShown(key, true) } }
                    OpenInClaudeMenu(pr: page.pr, detail: page.detail, model: claude)
                    AskClaudeMenu(pr: page.pr, detail: page.detail, model: claude)
                }
                .controlSize(.small)
            }
            .font(.callout)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.03))
        }
    }
}

/// The terminal under one header: the pull request, the session and what can be done to it, then one notice strip.
struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: EmbeddedTerminalModel
    @AppStorage(EmbeddedTerminal.noteHiddenKey) private var noteHidden = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = EmbeddedTerminal.currentNotice(notices, dismissed: session.dismissedNotices) { strip(notice) }
            if case .unavailable(let text, let copy) = session.state {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let copy { Button("Copy \(copy)") { GitHubModel.copy(copy) } }
                }
                .font(.callout)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TerminalHost(session: session).padding(6).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let activity = EmbeddedTerminal.activity(running: session.isRunning, ended: session.hasEnded, lastOutput: session.lastOutput, now: context.date)
                Circle().fill(activity.color).frame(width: 7, height: 7).help(activity.help)
            }
            Text(EmbeddedTerminal.pullRequestLabel(session.key) ?? session.title)
                .font(.callout.weight(.medium)).lineLimit(1).help(session.programTitle)
            if let preset = session.preset { Text(preset.shortTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 4)
            headerButton("doc.on.doc", "Copy everything the terminal shows, scrollback included") { GitHubModel.copy(session.view.allOutput) }
            headerButton("textformat.size.smaller", "Smaller text (\u{2318}-)") { _ = EmbeddedTerminal.steppedFontSize(-1) }
            headerButton("textformat.size.larger", "Larger text (\u{2318}+, \u{2318}0 resets)") { _ = EmbeddedTerminal.steppedFontSize(1) }
            Divider().frame(height: 14)
            headerButton("arrow.clockwise", "Start Claude again with the same prompt") { session.restart() }
            headerButton("stop.fill", "Stop Claude: Ctrl-C first, then end it if it stays") { session.stop() }
                .disabled(!session.isRunning)
            Divider().frame(height: 14)
            headerButton("chevron.down", "Hide the terminal; Claude keeps running") { model.setShown(session.key, false) }
            headerButton("xmark", "Close the terminal and end Claude") { model.close(session.key) }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func headerButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.help(help)
    }

    private var status: String? {
        switch session.state {
        case .idle, .running: return nil
        case .exited(let code): return code.map { $0 == 0 ? "Finished" : "Exited with \($0)" } ?? "Ended"
        case .unavailable: return "Unavailable"
        }
    }

    private var notices: [EmbeddedTerminal.Notice] {
        var list: [EmbeddedTerminal.Notice] = []
        if let hint = session.hint { list.append(EmbeddedTerminal.Notice(id: "hint", symbol: "info.circle", text: hint.text, copy: hint.copy)) }
        if let resume = session.resume {
            list.append(EmbeddedTerminal.Notice(id: "resume", symbol: "arrow.counterclockwise",
                                                text: "Resumed previous session \u{00B7} \(resume.title ?? "saved session")", action: "Start new session instead"))
        }
        let folder = (session.directory.path as NSString).abbreviatingWithTildeInPath
        if let safety = EmbeddedTerminal.safetyNotice(directory: folder, neverAgain: noteHidden, running: session.isRunning) { list.append(safety) }
        return list
    }

    private func strip(_ notice: EmbeddedTerminal.Notice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: notice.symbol).foregroundStyle(.secondary)
            Text(notice.text).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            if let copy = notice.copy { Button("Copy \(copy)") { GitHubModel.copy(copy) }.buttonStyle(.link) }
            if let action = notice.action { Button(action) { act(notice.id) }.buttonStyle(.link) }
            Button { session.dismissNotice(notice.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
    }

    private func act(_ id: String) {
        switch id {
        case "resume": GitHubClaudeModel.shared.startNewSession(session.key, folder: session.directory, preset: session.preset)
        case "safety": noteHidden = true
        default: break
        }
    }
}

#else

struct TerminalSplit<Page: View>: View {
    let page: GitHubDetailModel?
    let width: Double
    /// The terminal is a bottom half under the whole content, whatever the width.
    var stacked = false
    @ViewBuilder let content: Page

    var body: some View { content }
}

#endif

/// The "Terminal" button on the pull request page: shows or hides its terminal, with a dot while Claude runs in it.
struct TerminalToggle: View {
    let key: String
    @ObservedObject var model: EmbeddedTerminalModel

    var body: some View {
        if model.hasSession(key) {
            Button { model.setShown(key, !model.isShown(key)) } label: {
                Label(model.isRunning(key) ? "Terminal \u{25CF}" : "Terminal", systemImage: "apple.terminal")
            }
            .help(model.isShown(key) ? "Hide the Claude terminal" : "Show the Claude terminal")
        }
    }
}
