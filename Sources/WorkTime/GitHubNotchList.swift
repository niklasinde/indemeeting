import SwiftUI

enum NotchGitHubList: String, CaseIterable, Identifiable {
    case created, reviewing

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// The notch bar's GitHub list: my created pull requests with the reviews asked of me above them, or the ones I am reviewing,
/// with status tabs, a Mergeable filter and an inline merge.
struct WaitingPullRequests: View {
    let onOpen: () -> Void
    let onHold: (Bool) -> Void
    @ObservedObject private var model = GitHubModel.shared
    @ObservedObject private var actions = GitHubActionsModel.shared
    @AppStorage(GitHubModel.notchListKey) private var list = NotchGitHubList.created
    @AppStorage(GitHubModel.notchMergeableKey) private var mergeable = false
    @AppStorage(GitHubModel.notchStatusKey) private var status = GitHubStatusTab.all
    @AppStorage(GitHubModel.notchReviewStatusKey) private var reviewStatus = GitHubStatusTab.all
    @State private var draft: GitHubActionDraft?
    @State private var result: (url: String, text: String, isError: Bool)?

    var body: some View {
        let all = model.enabled ? model.prs[.created] ?? [] : []
        let fetched = model.enabled ? model.prs : [:]
        let createdCounts = GitHubLogic.statusCounts(all, GitHubLogic.Filter(), mergeable: mergeable)
        let reviewingCounts = GitHubLogic.reviewingCounts(fetched)
        let totals: [NotchGitHubList: Int] = [.created: createdCounts[.all, default: 0], .reviewing: reviewingCounts[.all, default: 0]]
        if !all.isEmpty || totals[.reviewing, default: 0] > 0 {
            VStack(alignment: .leading, spacing: 2) {
                switch list {
                case .created:
                    header(totals: totals)
                    tabs(selection: $status, counts: createdCounts)
                    let reviews = status == .all && !mergeable ? GitHubLogic.reviewQueue(fetched[.reviewRequested] ?? []) : []
                    let created = GitHubLogic.filter(all, GitHubLogic.Filter(status: status), mergeable: mergeable)
                    NotchScroll {
                        VStack(alignment: .leading, spacing: 2) {
                            if !reviews.isEmpty {
                                heading("\(reviews.count) waiting for my review")
                                ForEach(reviews.prefix(Self.reviewLimit)) { row($0, showsAuthor: true) }
                                Spacer().frame(height: 8)
                            }
                            ForEach(GitHubLogic.waitingFirst(created, status: status)) { row($0, showsAuthor: false) }
                        }
                    }
                case .reviewing:
                    header(totals: totals)
                    tabs(selection: $reviewStatus, counts: reviewingCounts)
                    NotchScroll {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(GitHubLogic.reviewing(fetched, status: reviewStatus).prefix(GitHubLogic.notchLimit)) {
                                row($0, showsAuthor: true, status: GitHubLogic.reviewStatus($0))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    static let reviewLimit = 10

    private var mark: some View { BrandMark.gitHub.scaledToFit().frame(width: 12, height: 12) }

    private func heading(_ text: String) -> some View {
        Label { Text(text) } icon: { mark }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }

    private func header(totals: [NotchGitHubList: Int]) -> some View {
        HStack(spacing: 4) {
            mark.foregroundStyle(.secondary).padding(.trailing, 4)
            ForEach(NotchGitHubList.allCases) { option in
                Button { list = option } label: {
                    HStack(spacing: 4) {
                        Text(option.title)
                        Text("\(totals[option, default: 0])").foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .buttonStyle(NotchChipStyle(selected: list == option))
            }
            Spacer()
            if list == .created { MergeablePill(isOn: $mergeable) }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private func tabs(selection: Binding<GitHubStatusTab>, counts: [GitHubStatusTab: Int]) -> some View {
        GitHubStatusTabs(selection: selection, counts: counts)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
    }

    private func row(_ pr: GitHubPR, showsAuthor: Bool, status: GitHubStatus? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PullRequestSummaryRow(pr: pr, showsAuthor: showsAuthor, status: status, open: { open(pr) }) {
                if GitHubLogic.isMergeable(pr) && draft?.pr.url != pr.url {
                    Button { begin(pr) } label: {
                        Image(systemName: "arrow.triangle.merge").frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(actions.enabled ? .primary : .tertiary)
                    .disabled(!actions.enabled)
                    .help(actions.enabled ? "Merge this pull request. You confirm first." : GitHubActions.disabledHelp)
                }
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

/// One pull request as the notch bar and the GitHub page list it: the status, where it lives, its title, Claude Code and its checks.
struct PullRequestSummaryRow<Accessory: View>: View {
    let pr: GitHubPR
    var showsAuthor = false
    var titleLines = 1
    var status: GitHubStatus?
    var open: (() -> Void)?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            PRStatusDot(pr: pr, status: status)
            if let open {
                Button(action: open) { labels }.buttonStyle(.plain)
            } else {
                labels
            }
            accessory
            OpenInClaudeCodeButton(pr: pr)
            StatusMark(pr: pr)
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(pr.repo) #\(String(pr.number))\(showsAuthor ? pr.author.map { " \u{00B7} \($0)" } ?? "" : "")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(pr.title).lineLimit(titleLines).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension PullRequestSummaryRow where Accessory == EmptyView {
    init(pr: GitHubPR, showsAuthor: Bool = false, titleLines: Int = 1, open: (() -> Void)? = nil) {
        self.init(pr: pr, showsAuthor: showsAuthor, titleLines: titleLines, open: open) { EmptyView() }
    }
}

struct MergeablePill: View {
    @Binding var isOn: Bool

    var body: some View {
        Button("Mergeable") { isOn.toggle() }
            .buttonStyle(NotchChipStyle(selected: isOn))
            .help("Only pull requests that are approved, pass their checks and have no conflicts")
    }
}

struct NotchChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(selected ? 0.22 : configuration.isPressed ? 0.14 : 0.08)))
            .foregroundStyle(selected ? .primary : .secondary)
            .contentShape(Capsule())
    }
}
