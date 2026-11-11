import SwiftUI

enum SlackNotchFilter: String, CaseIterable, Identifiable {
    case needsMe, all

    static let storageKey = "slackNotchView"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .needsMe: "Needs me"
        case .all: "All"
        }
    }

    func includes(_ message: SlackMessage) -> Bool { self == .all || message.handled == nil }
}

/// The notch bar's Slack list: unread DMs and the mentions from the last week still waiting on me, newest first; All adds the handled mentions.
struct SlackNotchList: View {
    static let limit = 40
    let onOpen: () -> Void
    @ObservedObject private var model = SlackModel.shared
    @AppStorage(SlackNotchFilter.storageKey) private var filter = SlackNotchFilter.needsMe

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.configured {
                header
                if let error = model.error, model.messages.isEmpty {
                    Text(error.message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                } else if model.fetched == nil {
                    Text("Fetching your mentions and DMs\u{2026}").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                } else if !model.unreadKnown {
                    Text("Slack gave no read state, so DMs are the ones from the last 24 hours.")
                        .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 8)
                }
                let rows = model.messages.filter(filter.includes)
                if model.fetched != nil && rows.isEmpty {
                    Text(filter == .all ? "No mentions or unread DMs this week." : "Nothing waiting on you.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                }
                NotchScroll {
                    VStack(alignment: .leading, spacing: 2) { ForEach(rows.prefix(Self.limit), content: row) }
                }
            } else {
                Button(action: setUp) {
                    Label { Text("Set up Slack in Settings") } icon: { mark }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .onAppear { model.refreshIfStale() }
    }

    private var mark: some View { BrandMark.slack.scaledToFit().frame(width: 12, height: 12) }

    private var header: some View {
        HStack(spacing: 4) {
            mark.padding(.trailing, 4)
            ForEach(SlackNotchFilter.allCases) { option in
                Button { filter = option } label: {
                    HStack(spacing: 4) {
                        Text(option.title)
                        Text("\(model.messages.filter(option.includes).count)").foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .buttonStyle(NotchChipStyle(selected: filter == option))
            }
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private func row(_ message: SlackMessage) -> some View {
        Button { open(message) } label: {
            HStack(spacing: 8) {
                Image(systemName: message.kind == .mention ? "at" : "bubble.left.fill")
                    .font(.caption)
                    .foregroundStyle(message.kind == .direct && (message.unread ?? 0) > 0 ? Color.accentColor : .secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(topLine(message)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(message.text).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            .padding(.leading, 8)
            .padding(.trailing, 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if message.kind == .mention && message.handled == nil {
                Button { model.mark(message, .dismissed) } label: {
                    Image(systemName: "xmark").font(.caption2).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Dismiss").padding(.trailing, 4)
            }
        }
        .contextMenu {
            Button("Open in Agent") {
                onOpen()
                TopicAgentStore.shared.open(slack: message, link: SlackLogic.webLink(message, workspace: model.identity?.url))
            }
        }
    }

    private func topLine(_ message: SlackMessage) -> String {
        var parts = [message.place]
        if let author = message.author, author != message.place { parts.append(author) }
        parts.append(ClaudePlugin.ago(message.date, now: Date()))
        if message.kind == .direct, let unread = message.unread, unread > 1 { parts.append("\(unread) unread") }
        if filter == .all, let handled = message.handled { parts.append(handled.label) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func open(_ message: SlackMessage) {
        onOpen()
        model.open(message)
    }

    private func setUp() {
        onOpen()
        SettingsWindow.shared.show(anchor: .slack)
    }
}
