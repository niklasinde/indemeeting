import SwiftUI

#if canImport(SwiftTerm)
import AppKit

/// SwiftTerm's view for a session. The view is the session's own, so selecting another pull request and coming back shows the
/// same screen and scrollback; keys go to it only while it is the first responder.
struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    @AppStorage(EmbeddedTerminal.fontSizeKey) private var fontSize = EmbeddedTerminal.defaultFontSize
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> ClaudeTerminalView {
        let view = session.view
        view.removeFromSuperview()
        configure(view)
        return view
    }

    func updateNSView(_ view: ClaudeTerminalView, context: Context) { configure(view) }

    private func configure(_ view: ClaudeTerminalView) {
        let size = EmbeddedTerminal.fontSize(fontSize)
        if view.font.pointSize != size { view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        view.apply(scheme == .dark ? EmbeddedTerminal.dark : EmbeddedTerminal.light)
    }
}

extension EmbeddedTerminal.Palette {
    var backgroundColor: Color {
        Color(.sRGB, red: Double(background >> 16 & 0xFF) / 255, green: Double(background >> 8 & 0xFF) / 255, blue: Double(background & 0xFF) / 255)
    }
}

/// The page with its terminal: to the right of it in a wide window, below it otherwise, with a handle to resize it.
struct TerminalSplit<Page: View>: View {
    let key: String?
    let width: Double
    @ViewBuilder let page: Page
    @ObservedObject private var model = EmbeddedTerminalModel.shared
    @AppStorage(EmbeddedTerminal.rightSizeKey) private var rightSize = EmbeddedTerminal.defaultRight
    @AppStorage(EmbeddedTerminal.belowSizeKey) private var belowSize = EmbeddedTerminal.defaultBelow
    @State private var dragStart: Double?

    var body: some View {
        if let key, let session = model.session(for: key), model.isShown(key) {
            let placement = EmbeddedTerminal.placement(width: width)
            GeometryReader { proxy in
                let length = EmbeddedTerminal.paneLength(placement == .right ? rightSize : belowSize, placement: placement,
                                                         available: placement == .right ? proxy.size.width : proxy.size.height)
                let pane = TerminalPane(session: session, model: model).id(key)
                switch placement {
                case .right:
                    HStack(spacing: 0) {
                        page.frame(maxWidth: .infinity, maxHeight: .infinity)
                        handle(.right, current: length)
                        pane.frame(width: length)
                    }
                case .below:
                    VStack(spacing: 0) {
                        page.frame(maxWidth: .infinity, maxHeight: .infinity)
                        handle(.below, current: length)
                        pane.frame(height: length)
                    }
                }
            }
        } else {
            page
        }
    }

    private func handle(_ placement: EmbeddedTerminal.Placement, current: Double) -> some View {
        let horizontal = placement == .right
        return Rectangle()
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

/// The terminal under a toolbar with the session's title and what can be done to it.
struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: EmbeddedTerminalModel
    @AppStorage(EmbeddedTerminal.noteHiddenKey) private var noteHidden = false
    @State private var noteDismissed = false
    @Environment(\.colorScheme) private var scheme

    private var palette: EmbeddedTerminal.Palette { scheme == .dark ? EmbeddedTerminal.dark : EmbeddedTerminal.light }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let hint = session.hint { notice(hint.text, copy: hint.copy) }
            if let resume = session.resume { resumed(resume) }
            if !noteHidden, !noteDismissed, session.isRunning { safetyNote }
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
        .background(palette.backgroundColor)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(session.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .help(session.isRunning ? "Claude is running" : "Claude is not running")
            Text(session.title).font(.callout.weight(.medium)).lineLimit(1)
            Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button { session.restart() } label: { Image(systemName: "arrow.clockwise") }
                .help("Start Claude again with the same prompt")
            Button { session.stop() } label: { Image(systemName: "stop.fill") }
                .disabled(!session.isRunning)
                .help("Stop Claude: Ctrl-C first, then end it if it stays")
            Button { GitHubModel.copy(session.view.allOutput) } label: { Image(systemName: "doc.on.doc") }
                .help("Copy everything the terminal shows, scrollback included")
            Button { model.setShown(session.key, false) } label: { Image(systemName: "chevron.down") }
                .help("Hide the terminal; Claude keeps running")
            Button { model.close(session.key) } label: { Image(systemName: "xmark") }
                .help("Close the terminal and end Claude")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var status: String {
        switch session.state {
        case .idle: return ""
        case .running: return session.programTitle
        case .exited(let code): return code.map { $0 == 0 ? "Finished" : "Exited with \($0)" } ?? "Ended"
        case .unavailable: return "Unavailable"
        }
    }

    private func notice(_ text: String, copy: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
            if let copy { Button("Copy \(copy)") { GitHubModel.copy(copy) }.buttonStyle(.link) }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func resumed(_ resume: GitHubClaude.Resume) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.counterclockwise").foregroundStyle(.secondary)
            Text("Resumed previous session \u{00B7} \(resume.title ?? "saved session")").foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Button("Start new session instead") {
                GitHubClaudeModel.shared.startNewSession(session.key, folder: session.directory, preset: session.preset)
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var safetyNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.and.list.clipboard").foregroundStyle(.secondary)
            Text(EmbeddedTerminal.safetyNote(directory: (session.directory.path as NSString).abbreviatingWithTildeInPath))
                .foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            Button("Don't show again") { noteHidden = true }.buttonStyle(.link)
            Button { noteDismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
    }
}

#else

struct TerminalSplit<Page: View>: View {
    let key: String?
    let width: Double
    @ViewBuilder let page: Page

    var body: some View { page }
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
