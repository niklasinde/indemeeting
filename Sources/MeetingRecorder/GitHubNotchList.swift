import SwiftUI

/// The notch bar's GitHub list: the reviews asked of me and the first few created pull requests, with status tabs, a Mergeable
/// filter and an inline merge.
struct WaitingPullRequests: View {
    let onOpen: () -> Void
    let onHold: (Bool) -> Void
    @ObservedObject private var model = GitHubModel.shared
    @ObservedObject private var actions = GitHubActionsModel.shared
    @AppStorage(GitHubModel.notchMergeableKey) private var mergeable = false
    @AppStorage(GitHubModel.notchStatusKey) private var status = GitHubStatusTab.all
    @State private var draft: GitHubActionDraft?
    @State private var result: (url: String, text: String, isError: Bool)?

    var body: some View {
        let all = model.prs[.created] ?? []
        let created = model.enabled ? GitHubLogic.filter(all, GitHubLogic.Filter(status: status), mergeable: mergeable) : []
        let prs = GitHubLogic.waitingFirst(created, status: status)
        let reviews = model.enabled && status == .all && !mergeable ? GitHubLogic.reviewQueue(model.prs[.reviewRequested] ?? []) : []
        if model.enabled && !all.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if !reviews.isEmpty {
                    heading("\(reviews.count) waiting for my review")
                    ForEach(reviews.prefix(Self.reviewLimit)) { row($0, showsAuthor: true) }
                    Spacer().frame(height: 8)
                }
                HStack {
                    heading("\(created.count) \(mergeable ? "mergeable" : status == .all ? "created" : status.title.lowercased())")
                    Spacer()
                    Button("Mergeable") { mergeable.toggle() }
                        .buttonStyle(NotchChipStyle(selected: mergeable))
                        .help("Only pull requests that are approved, pass their checks and have no conflicts")
                }
                .font(.caption.weight(.semibold))
                .padding(.trailing, 8)
                GitHubStatusTabs(selection: $status, counts: GitHubLogic.statusCounts(all, GitHubLogic.Filter(), mergeable: mergeable), compact: true)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                ForEach(prs) { row($0, showsAuthor: false) }
            }
            .padding(.horizontal, 16)
        }
    }

    static let reviewLimit = 3

    private func heading(_ text: String) -> some View {
        Label { Text(text) } icon: { BrandMark.gitHub.scaledToFit().frame(width: 12, height: 12) }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }

    private func row(_ pr: GitHubPR, showsAuthor: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                PRStatusDot(pr: pr)
                Button { open(pr) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pr.repo) #\(String(pr.number))\(showsAuthor ? pr.author.map { " \u{00B7} \($0)" } ?? "" : "")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(pr.title).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if GitHubLogic.isMergeable(pr) && draft?.pr.url != pr.url {
                    Button { begin(pr) } label: {
                        Image(systemName: "arrow.triangle.merge").frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(actions.enabled ? .primary : .tertiary)
                    .disabled(!actions.enabled)
                    .help(actions.enabled ? "Merge this pull request. You confirm first." : GitHubActions.disabledHelp)
                }
                StatusMark(pr: pr)
            }
            if let draft, draft.pr.url == pr.url {
                MergeConfirmation(draft: draft, onCancel: { finish(nil) }, onMerge: { merge(draft) })
            } else if let result, result.url == pr.url {
                Text(result.text).font(.caption).foregroundStyle(result.isError ? .red : .green).lineLimit(2)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }

    private func begin(_ pr: GitHubPR) {
        guard actions.enabled else { return }
        let draft = GitHubActionDraft(.merge, pr: pr, detail: nil)
        result = nil
        self.draft = draft
        onHold(true)
        Task { await draft.refresh() }
    }

    private func merge(_ draft: GitHubActionDraft) {
        Task {
            guard let outcome = await actions.run(draft) else { return }
            let text = actions.resultText(outcome, for: draft.request)
            finish((draft.pr.url, text.text, text.isError))
        }
    }

    private func finish(_ result: (url: String, text: String, isError: Bool)?) {
        draft = nil
        self.result = result
        onHold(false)
    }

    private func open(_ pr: GitHubPR) {
        onOpen()
        SessionsModel.shared.showGitHub?(GitHubLink.Target(repo: pr.repo, number: pr.number))
    }
}

private struct MergeConfirmation: View {
    @ObservedObject var draft: GitHubActionDraft
    let onCancel: () -> Void
    let onMerge: () -> Void

    var body: some View {
        let confirmation = draft.confirmation
        HStack(spacing: 8) {
            if draft.running {
                ProgressView().controlSize(.small)
                Text("Merging \(draft.request.shortReference)\u{2026}")
            } else if draft.checking {
                ProgressView().controlSize(.small)
                Text("Checking \(draft.request.shortReference)\u{2026}")
            } else if let blocker = confirmation.blocker {
                Text(blocker).foregroundStyle(.orange).lineLimit(2)
            } else {
                Text("\(draft.request.method.verb) \(draft.request.shortReference)?")
            }
            Spacer()
            Button("Cancel", action: onCancel).disabled(draft.running)
            Button(draft.request.method.verb, action: onMerge)
                .buttonStyle(.borderedProminent)
                .disabled(draft.running || draft.checking || !confirmation.canConfirm)
        }
        .font(.caption)
        .controlSize(.small)
    }
}

struct NotchChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.22 : configuration.isPressed ? 0.14 : 0.08)))
            .foregroundStyle(selected ? .primary : .secondary)
            .contentShape(Capsule())
    }
}
