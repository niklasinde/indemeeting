import SwiftUI

/// The notch bar's GitHub list: the first few created pull requests, with a Mergeable filter and an inline merge.
struct WaitingPullRequests: View {
    let onOpen: () -> Void
    let onHold: (Bool) -> Void
    @ObservedObject private var model = GitHubModel.shared
    @ObservedObject private var actions = GitHubActionsModel.shared
    @AppStorage(GitHubModel.notchMergeableKey) private var mergeable = false
    @State private var draft: GitHubActionDraft?
    @State private var result: (url: String, text: String, isError: Bool)?

    var body: some View {
        let created = model.enabled ? GitHubLogic.filter(model.prs[.created] ?? [], GitHubLogic.Filter(), mergeable: mergeable) : []
        let prs = GitHubLogic.waitingFirst(created)
        if model.enabled && !(model.prs[.created] ?? []).isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label { Text("\(created.count) \(mergeable ? "mergeable" : "created")") } icon: {
                        BrandMark.gitHub.scaledToFit().frame(width: 12, height: 12)
                    }
                    Spacer()
                    Button { mergeable.toggle() } label: {
                        Text("Mergeable")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(mergeable ? 0.22 : 0.08)))
                            .foregroundStyle(mergeable ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Only pull requests that are approved, pass their checks and have no conflicts")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                ForEach(prs) { pr in row(pr) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func row(_ pr: GitHubPR) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { open(pr) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pr.repo) #\(String(pr.number))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
