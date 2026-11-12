import AppKit
import SwiftUI

/// Opening the pull requests a transcript message mentions: in WorkTime's GitHub page or on GitHub.
@MainActor
enum TranscriptPullRequests {
    static let limit = 5

    static func mentioned(in text: String) -> [GitHubLink.Target] { Array(GitHubLink.mentions(in: text).prefix(limit)) }

    static func openInApp(_ target: GitHubLink.Target) { AgentModel.openPullRequestLink?(target) }

    static func openOnGitHub(_ target: GitHubLink.Target) { if let url = URL(string: target.url) { NSWorkspace.shared.open(url) } }

    static func title(_ target: GitHubLink.Target) -> String { "\(target.repo)#\(target.number)" }
}

/// Adds "Open in WorkTime" and "Open on GitHub" above the standard items of the text menu opened over a transcript message,
/// for the pull requests in the selection, or else those the message under the pointer mentions.
@MainActor
final class TranscriptPullRequestMenu: NSObject {
    static let shared = TranscriptPullRequestMenu()

    /// The pull requests of the transcript message under the pointer, nil when it is over none.
    var hovered: (id: UUID, targets: [GitHubLink.Target])?
    private var contextClick: Date?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            if event.type == .rightMouseDown || event.modifierFlags.contains(.control) { self?.contextClick = Date() }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(menuOpened(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    @objc private func menuOpened(_ note: Notification) {
        guard let menu = note.object as? NSMenu, menu.supermenu == nil, let clicked = contextClick, Date().timeIntervalSince(clicked) < 1,
              let hovered else { return }
        contextClick = nil
        let selected = Array(GitHubLink.mentions(in: selectionText()).prefix(TranscriptPullRequests.limit))
        let targets = selected.isEmpty ? hovered.targets : selected
        guard !targets.isEmpty else { return }
        for (index, item) in (items(for: targets) + [.separator()]).enumerated() { menu.insertItem(item, at: index) }
    }

    private func items(for targets: [GitHubLink.Target]) -> [NSMenuItem] {
        if targets.count == 1 { return actions(for: targets[0]) }
        return targets.map { target in
            let item = NSMenuItem(title: TranscriptPullRequests.title(target), action: nil, keyEquivalent: "")
            item.submenu = NSMenu()
            actions(for: target).forEach { item.submenu?.addItem($0) }
            return item
        }
    }

    private func actions(for target: GitHubLink.Target) -> [NSMenuItem] {
        [item(title: "Open in WorkTime", action: #selector(openInApp(_:)), target: target),
         item(title: "Open on GitHub", action: #selector(openOnGitHub(_:)), target: target)]
    }

    private func item(title: String, action: Selector, target: GitHubLink.Target) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = target.url
        return item
    }

    @objc private func openInApp(_ sender: NSMenuItem) { pullRequest(sender).map(TranscriptPullRequests.openInApp) }

    @objc private func openOnGitHub(_ sender: NSMenuItem) { pullRequest(sender).map(TranscriptPullRequests.openOnGitHub) }

    private func pullRequest(_ item: NSMenuItem) -> GitHubLink.Target? { (item.representedObject as? String).flatMap(GitHubLink.pullRequest(at:)) }

    /// The selected text with the addresses of the links in it, read the way the Services menu reads it.
    private func selectionText() -> String {
        guard let requestor = NSApp.keyWindow?.firstResponder as? NSServicesMenuRequestor else { return "" }
        let board = NSPasteboard(name: NSPasteboard.Name("WorkTime.TranscriptSelection"))
        board.clearContents()
        guard requestor.writeSelection?(to: board, types: [.rtf, .string]) == true else { return "" }
        var links: [String] = []
        if let rtf = board.data(forType: .rtf), let text = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let url = value as? URL { links.append(url.absoluteString) } else if let url = value as? String { links.append(url) }
            }
        }
        return ([board.string(forType: .string) ?? ""] + links).joined(separator: "\n")
    }
}

/// While the pointer is over the message, a small "Open in WorkTime" button for the pull requests it mentions, and the
/// pull requests offered in its text menu.
private struct TranscriptPullRequestActions: ViewModifier {
    let targets: [GitHubLink.Target]
    @State private var id = UUID()
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside && !targets.isEmpty
                let menu = TranscriptPullRequestMenu.shared
                if inside { menu.hovered = (id, targets) } else if menu.hovered?.id == id { menu.hovered = nil }
            }
            .onDisappear { if TranscriptPullRequestMenu.shared.hovered?.id == id { TranscriptPullRequestMenu.shared.hovered = nil } }
            .overlay(alignment: .topTrailing) {
                if hovering { button.offset(y: -12) }
            }
    }

    @ViewBuilder private var button: some View {
        let label = Label("Open in WorkTime", systemImage: "arrow.up.forward.app").font(.caption)
        Group {
            if targets.count == 1, let target = targets.first {
                Button { TranscriptPullRequests.openInApp(target) } label: { label }
                    .buttonStyle(.plain)
                    .help("Open \(TranscriptPullRequests.title(target)) on WorkTime\u{2019}s GitHub page")
            } else {
                Menu {
                    ForEach(targets, id: \.url) { target in
                        Button(TranscriptPullRequests.title(target)) { TranscriptPullRequests.openInApp(target) }
                    }
                } label: { label }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Open a pull request this message mentions on WorkTime\u{2019}s GitHub page")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }
}

extension View {
    func transcriptPullRequests(in text: String) -> some View {
        modifier(TranscriptPullRequestActions(targets: TranscriptPullRequests.mentioned(in: text)))
    }
}
