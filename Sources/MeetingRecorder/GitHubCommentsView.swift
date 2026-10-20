import SwiftUI

/// The Comments section of the pull request page: review threads by file, then the conversation. Read only.
struct GitHubCommentsSection: View {
    @ObservedObject var model: GitHubCommentsModel
    /// Off in the previews, which render the whole page at once.
    var lazy = true

    var body: some View {
        DetailSection("Comments", trailing: model.comments.map(GitHubLogic.commentsSummary)) {
            VStack(alignment: .leading, spacing: 14) {
                if let comments = model.comments {
                    if comments.isEmpty {
                        Text("No comments yet").foregroundStyle(.tertiary)
                    } else {
                        controls(comments)
                        list
                        footer(comments)
                    }
                    if let error = model.error { Text(error.message).font(.caption).foregroundStyle(.orange) }
                } else if let error = model.error {
                    Text(error.message).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading comments\u{2026}").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func controls(_ comments: GitHubComments) -> some View {
        let scopes = GitHubCommentsFilter.Scope.allCases.filter { $0 != .new || model.newCount > 0 || model.filter.scope == .new }
        return VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6) {
                ForEach(scopes) { scope in
                    FilterPill(title: scope == .unresolved ? "Unresolved (\(comments.unresolved))" : scope == .new ? "New (\(model.newCount))" : scope.rawValue,
                               selected: model.filter.scope == scope) { model.choose(scope) }
                }
                FilterPill(title: "Hide bots", icon: "cpu", selected: model.filter.hideBots) { model.filter.hideBots.toggle() }
            }
            SearchField(text: $model.filter.query).frame(maxWidth: 260).controlSize(.small)
        }
    }

    @ViewBuilder private var list: some View {
        let groups = GitHubLogic.groupedByFile(model.threads)
        let conversation = model.conversation
        if groups.isEmpty && conversation.isEmpty {
            Text(model.filter.scope == .unresolved && model.filter.query.isEmpty && !model.filter.hideBots ? "No unresolved threads" : "Nothing matches")
                .foregroundStyle(.tertiary)
        }
        stack(spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    (Text(group.directory).foregroundStyle(.tertiary) + Text(group.name).fontWeight(.semibold))
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    ForEach(group.threads) { ThreadCard(thread: $0, model: model) }
                }
            }
        }
        if !conversation.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Conversation").font(.subheadline.weight(.semibold))
                stack(spacing: 14) {
                    ForEach(conversation) { comment in
                        CommentView(comment: comment, thread: nil, model: model, showsReview: true)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder private func stack<Content: View>(spacing: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        if lazy { LazyVStack(alignment: .leading, spacing: spacing, content: content) } else { VStack(alignment: .leading, spacing: spacing, content: content) }
    }

    @ViewBuilder private func footer(_ comments: GitHubComments) -> some View {
        if let progress = GitHubLogic.commentsProgress(comments) {
            HStack(spacing: 10) {
                Text("Showing \(progress)").font(.callout).foregroundStyle(.secondary)
                Button("Load more") { model.loadMore() }.disabled(model.loadingMore)
                if model.loadingMore { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
        }
    }
}

private struct FilterPill: View {
    let title: String
    var icon: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 9)) }
                Text(title)
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

private struct ThreadCard: View {
    let thread: GitHubThread
    @ObservedObject var model: GitHubCommentsModel

    var body: some View {
        if thread.isResolved && !model.expanded.contains(thread.id) { resolved } else { card }
    }

    private var resolved: some View {
        Button { model.toggle(thread.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(GitHubLogic.resolvedLine(thread)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the resolved thread")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(GitHubLogic.location(thread)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let badge = GitHubLogic.badge(thread) { Badge(text: badge, tint: .orange) }
                if thread.isResolved { Badge(text: "resolved", tint: .green) }
                Spacer(minLength: 8)
                if let url = thread.url {
                    Button("Open on GitHub") { open(url) }
                    Button("Copy Link") { GitHubModel.copy(url) }
                }
                if thread.isResolved { Button("Collapse") { model.toggle(thread.id) } }
            }
            .buttonStyle(.link)
            .font(.caption)
            if !thread.diff.isEmpty { DiffBlock(lines: thread.diff) }
            ForEach(Array(thread.comments.enumerated()), id: \.element.id) { index, comment in
                if index > 0 { Divider() }
                CommentView(comment: comment, thread: thread, model: model, showsReview: false)
            }
            if thread.commentCount > thread.comments.count {
                Note(text: "\(thread.commentCount - thread.comments.count) more comments on GitHub")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        .opacity(thread.isOutdated ? 0.65 : 1)
    }
}

private struct CommentView: View {
    let comment: GitHubComment
    let thread: GitHubThread?
    @ObservedObject var model: GitHubCommentsModel
    let showsReview: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Initials(text: comment.author.login, color: comment.author.isBot ? .purple : .secondary)
            VStack(alignment: .leading, spacing: 6) {
                header
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(comment.author.login).fontWeight(.semibold)
            if comment.author.isBot { Badge(text: "bot", tint: .purple) }
            if let review = comment.review, showsReview || review != .commented, review != .pending { reviewBadge(review) }
            if let created = comment.created {
                Text(GitHubLogic.updatedText(created, now: Date())).foregroundStyle(.tertiary).help(created.formatted(date: .complete, time: .shortened))
            }
            if GitHubLogic.isNew(comment, me: model.me, after: model.cutoff) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("New since your last activity")
            }
            Spacer(minLength: 8)
            if thread == nil, let url = comment.url {
                Button { open(url) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.link).help("Open on GitHub")
            }
        }
        .font(.callout)
    }

    private func reviewBadge(_ review: GitHubPRDetail.ReviewState) -> some View {
        Badge(text: GitHubLogic.reviewText(review), tint: review == .approved ? .green : review == .changesRequested ? .red : .secondary)
    }

    @ViewBuilder private var content: some View {
        let before = thread.map(GitHubLogic.suggestionBefore) ?? []
        if let digest = comment.digest, !model.expanded.contains(comment.id) {
            if !digest.isEmpty { AnswerText(text: digest) }
            Button("Show full") { model.toggle(comment.id) }.buttonStyle(.link).font(.caption)
        } else {
            CommentParts(parts: comment.parts, before: before)
            if comment.digest != nil { Button("Show less") { model.toggle(comment.id) }.buttonStyle(.link).font(.caption) }
        }
    }
}

private struct CommentParts: View {
    let parts: [GitHubCommentPart]
    let before: [GitHubDiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .markdown(let text):
                    AnswerText(text: text)
                case .suggestion(let text):
                    SuggestionBlock(before: before, after: text)
                case .details(let summary, let inner):
                    DisclosureGroup {
                        CommentParts(parts: inner, before: before).padding(.top, 6)
                    } label: {
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct SuggestionBlock: View {
    let before: [GitHubDiffLine]
    let after: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Suggestion", systemImage: "lightbulb").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
            DiffBlock(lines: before.map { GitHubDiffLine(kind: .removed, text: $0.text) }
                      + (after.isEmpty ? [] : after.components(separatedBy: "\n").map { GitHubDiffLine(kind: .added, text: $0) }))
            if after.isEmpty { Note(text: "Removes the lines").padding(.horizontal, 8).padding(.bottom, 4) }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
    }
}

private struct DiffBlock: View {
    let lines: [GitHubDiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(Self.marker(line.kind) + (line.text.isEmpty ? " " : line.text))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Self.color(line.kind))
                    .help(line.text)
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private static func marker(_ kind: GitHubDiffLine.Kind) -> String {
        switch kind {
        case .added: return "+ "
        case .removed: return "\u{2212} "
        case .context: return "  "
        }
    }

    private static func color(_ kind: GitHubDiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.16)
        case .removed: return Color.red.opacity(0.16)
        case .context: return .clear
        }
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}
