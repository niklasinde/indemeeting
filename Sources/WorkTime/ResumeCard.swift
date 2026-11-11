import AppKit
import SwiftUI

/// Shows a "pick up where you left off" card in the notch bar when the user settles back into a branch or ticket they had left
/// for longer than the gap in Settings.
@MainActor
final class ResumeModel: ObservableObject {
    static let shared = ResumeModel()

    @Published private(set) var card: ResumeCard?
    @Published private(set) var unseen = false
    private var trigger = ResumeTrigger()
    private var building: Task<Void, Never>?

    /// Called with the tracker's open block after every sample.
    func observe(_ block: ActivityBlock?, store: MeetingStore) {
        let settings = ResumeSettings(.standard)
        guard settings.enabled, store.isAvailable else { return }
        let key = block.flatMap { ResumeContextKey.of($0.key) }
        guard let fired = trigger.observe(key, at: block?.end ?? Date(), gap: settings.gap) else { return }
        if card?.key != fired.key { dismiss() }
        building?.cancel()
        building = Task { [weak self] in
            let sources = ResumeSources(store: { store })
            let card = try? await Task.detached {
                let blocks = try ResumeGatherer.blocks(store, before: fired.entered)
                guard ResumeLogic.shouldShow(ResumeLogic.lastVisit(blocks, key: fired.key, before: fired.entered), entered: fired.entered,
                                             gap: settings.gap) else { return nil as ResumeCard? }
                return try await ResumeGatherer.card(for: fired.key, entered: fired.entered, blocks: blocks, sources: sources)
            }.value
            guard let self, !Task.isCancelled, let card else { return }
            self.show(card)
        }
    }

    func show(_ card: ResumeCard) {
        self.card = card
        unseen = true
        AskPanel.shared.peekResume()
    }

    func seen() { unseen = false }

    func dismiss() {
        card = nil
        unseen = false
    }

    func openPR() {
        guard let url = card?.pr.flatMap({ URL(string: $0.url) }) else { return }
        NSWorkspace.shared.open(url)
    }

    func openAgent() {
        guard let card else { return }
        if let url = card.agent?.prURL ?? card.pr?.url, let target = GitHubLink.pullRequest(at: url) {
            AgentModel.openAgentLink?(target)
        } else if let ticket = card.ticket {
            TopicAgentStore.shared.open(ticket: JiraTicket(key: ticket.key, summary: ticket.summary, status: ticket.status, priority: nil, updated: nil))
        }
    }

    #if DEBUG
    func showSample(_ card: ResumeCard?, unseen: Bool) {
        self.card = card
        self.unseen = unseen
    }
    #endif
}

struct ResumeCardView: View {
    let card: ResumeCard
    var now = Date()
    var onClose: () -> Void = {}
    @ObservedObject private var model = ResumeModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !card.prompts.isEmpty || !(card.visit?.prompts.isEmpty ?? true) { prompts }
            if let pr = card.pr { pullRequest(pr) }
            if let ticket = card.ticket { jira(ticket) }
            if !card.meetings.isEmpty { meetings }
            if let agent = card.agent { agentRow(agent) }
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .padding(.horizontal, 16)
        .onHover { if $0 { model.seen() } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pick up where you left off").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(card.key.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(card.visit.map { ResumeLogic.visitLine($0, now: now) } ?? "No tracked time here lately")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
    }

    private var prompts: some View {
        let typed = card.prompts.map { ($0.session, $0.text) }
        let stored = typed.isEmpty ? (card.visit?.prompts ?? []).prefix(2).map { ("", $0) } : []
        return section("text.bubble", "Claude") {
            ForEach(Array((typed + stored).prefix(2).enumerated()), id: \.offset) { _, prompt in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\u{201C}\(prompt.1)\u{201D}").lineLimit(2)
                    if !prompt.0.isEmpty { Text(prompt.0).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                }
            }
        }
    }

    private func pullRequest(_ pr: ResumePR) -> some View {
        section(nil, "\(ResumeLogic.repoName(pr.repo)) #\(pr.number)", mark: BrandMark.gitHub, trailing: AnyView(ChecksBadge(checks: pr.checks))) {
            Text(pr.title).lineLimit(1)
            Text(prSummary(pr)).font(.caption).foregroundStyle(pr.hasChanges ? .primary : .secondary)
            ForEach(Array(pr.newComments.prefix(2).enumerated()), id: \.offset) { _, comment in commentLine(comment) }
        }
    }

    private func prSummary(_ pr: ResumePR) -> String {
        var parts: [String] = []
        if !pr.newCommits.isEmpty { parts.append(plural(pr.newCommits.count, "new commit")) }
        if !pr.newComments.isEmpty { parts.append(plural(pr.newComments.count, "new comment")) }
        if let failed = pr.finishedChecks.first(where: { $0.hasSuffix(" failed") }) { parts.append(failed) }
        else if !pr.finishedChecks.isEmpty { parts.append(plural(pr.finishedChecks.count, "check") + " finished") }
        if let unresolved = pr.unresolved, unresolved > 0 { parts.append("\(unresolved) unresolved") }
        return parts.isEmpty ? "Nothing new since you left" : parts.joined(separator: " \u{00B7} ")
    }

    private func jira(_ ticket: ResumeTicket) -> some View {
        section(nil, ticket.key, mark: BrandMark.jira, trailing: AnyView(Text(ticket.status).font(.caption).foregroundStyle(.secondary))) {
            Text(ticket.summary).lineLimit(1)
            if ticket.changes.isEmpty && ticket.newComments.isEmpty {
                Text(ticket.assignee.map { "Assigned to \($0) \u{00B7} no changes since you left" } ?? "Unassigned \u{00B7} no changes since you left")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ticket.changes.suffix(2), id: \.self) { Text($0).font(.caption) }
            ForEach(Array(ticket.newComments.prefix(2).enumerated()), id: \.offset) { _, comment in commentLine(comment) }
        }
    }

    private var meetings: some View {
        section("person.2", "Mentioned in meetings") {
            ForEach(card.meetings, id: \.meeting) { mention in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(mention.title) \u{00B7} \(ClaudePlugin.ago(mention.date, now: now))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(mention.line).font(.caption).italic().lineLimit(2)
                }
            }
        }
    }

    private func agentRow(_ agent: ResumeAgent) -> some View {
        section("sparkles", "Agent \u{00B7} \(agent.status)") {
            if let result = agent.lastResult { Text(result).font(.caption).lineLimit(2) }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if card.pr != nil { Button("Open PR") { act(model.openPR) }.keyboardShortcut(.defaultAction) }
            if card.pr != nil || card.agent != nil { Button("Open agent") { act(model.openAgent) } }
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .controlSize(.small)
    }

    private func commentLine(_ comment: ResumeComment) -> some View {
        Text("\(Text(comment.author).fontWeight(.semibold)) \(comment.text)").font(.caption).lineLimit(1)
    }

    private func section<Content: View>(_ symbol: String?, _ title: String, mark: Image? = nil, trailing: AnyView? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let mark { mark.scaledToFit() } else if let symbol { Image(systemName: symbol).resizable().scaledToFit() }
            }
            .frame(width: 14, height: 14).foregroundStyle(.secondary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    trailing
                }
                content()
            }
        }
    }

    private func act(_ action: () -> Void) {
        model.seen()
        action()
        onClose()
    }

    private func dismiss() {
        model.dismiss()
        onClose()
    }

    private func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
}

private struct ChecksBadge: View {
    let checks: GitHubPR.Checks

    var body: some View {
        switch checks {
        case .passed: label("checkmark.circle.fill", "Checks passed", .green)
        case .failed: label("xmark.circle.fill", "Checks failed", .red)
        case .running: label("clock.fill", "Checks running", .yellow)
        case .none: EmptyView()
        }
    }

    private func label(_ symbol: String, _ text: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(color).labelStyle(.titleAndIcon)
    }
}

/// The pulsing dot under the notch while a resume card waits; hovering it opens the bar on the card.
struct ResumeNotchDot: View {
    let onHover: () -> Void
    @State private var pulsing = false

    var body: some View {
        Circle().fill(Color.orange)
            .frame(width: 7, height: 7)
            .scaleEffect(pulsing ? 1.35 : 0.85)
            .opacity(pulsing ? 1 : 0.6)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.black))
            .contentShape(Rectangle())
            .onHover { if $0 { onHover() } }
            .onTapGesture(perform: onHover)
            .onAppear { pulsing = true }
            .help("Pick up where you left off")
    }
}

struct ResumeSettingsSection: View {
    @AppStorage(ResumeSettings.enabledKey) private var enabled = true
    @AppStorage(ResumeSettings.gapKey) private var gapHours = 2.0

    var body: some View {
        SettingsSection("Pick up where you left off", footer: "When you come back to a branch or ticket after a while and stay 30 seconds, the "
                        + "top notch bar shows when you were last there, your last Claude prompts, what changed on its pull request and "
                        + "Jira ticket, meetings that mentioned it and its agent. Needs activity tracking.") {
            SettingsRow("Show the card") {
                Toggle("Show the card", isOn: $enabled).labelsHidden().toggleStyle(.switch)
            }
            Divider().padding(.leading, 14)
            SettingsRow("After being away for") {
                Picker("After being away for", selection: $gapHours) {
                    ForEach(ResumeSettings.gapChoices, id: \.self) { Text(ActivityLogic.hoursText($0 * 3600)).tag($0) }
                }
                .labelsHidden().fixedSize().disabled(!enabled)
            }
        }
    }
}
