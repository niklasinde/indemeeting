import SwiftUI

/// A changed file: a row that opens its diff inline, with the review threads under their lines.
struct GitHubFileDiff: View {
    let file: GitHubPRDetail.File
    @ObservedObject var diffs: GitHubDiffModel
    let source: GitHubDiffModel.Source
    /// Where the file is on GitHub, for a diff that cannot be shown here.
    let url: String
    var threads: [GitHubThread] = []
    var comments: GitHubCommentsModel?

    var body: some View {
        let open = diffs.expanded.contains(file.path)
        let patch = diffs.patches[file.path]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.tertiary).frame(width: 10)
                Image(systemName: file.change.symbol).foregroundStyle(file.change.color).frame(width: 18).help(file.change.rawValue.capitalized)
                if let previous = patch?.previousPath {
                    Text("\(previous) \u{2192} \(file.path)").lineLimit(1).truncationMode(.middle)
                } else {
                    (Text(file.directory).foregroundStyle(.tertiary) + Text(file.name)).lineLimit(1).truncationMode(.middle)
                }
                if !threads.isEmpty {
                    Label("\(threads.count)", systemImage: "bubble.left").font(.caption).foregroundStyle(.secondary).help("Review threads on this file")
                }
                Spacer(minLength: 8)
                if open, let text = patch?.patch {
                    Button { GitHubModel.copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy the diff")
                }
                Text(GitHubLogic.changesText(additions: file.additions, deletions: file.deletions)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { diffs.toggle(file.path, from: source) }
            .help(open ? "Hide the diff" : "Show the diff")
            if open { content(patch) }
        }
    }

    @ViewBuilder private func content(_ patch: GitHubFilePatch?) -> some View {
        if let text = patch?.patch {
            let render = diffs.render(file.path, patch: text)
            let placement = GitHubDiffLogic.placement(threads, in: render.rows)
            if !placement.unplaced.isEmpty, let comments {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(placement.unplaced) { ThreadCard(thread: $0, model: comments) }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("\(placement.unplaced.count) thread\(placement.unplaced.count == 1 ? "" : "s") on the file or on lines outside the diff")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            DiffTable(render: render, placed: placement.placed, comments: comments, whole: Binding(
                get: { diffs.whole.contains(file.path) },
                set: { if $0 { diffs.whole.insert(file.path) } else { diffs.whole.remove(file.path) } }))
        } else if diffs.loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching the diff\u{2026}").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if let error = diffs.error {
            HStack(spacing: 8) {
                Text(error.message).foregroundStyle(.secondary)
                Button("Try again") { diffs.load(source) }.buttonStyle(.link)
            }
            .font(.callout)
        } else if diffs.loaded {
            Button("Diff too large or binary \u{2013} open on GitHub") { open(url) }.buttonStyle(.link).font(.callout)
        }
    }
}

private struct DiffTable: View {
    let render: GitHubDiffRender
    let placed: [Int: [GitHubThread]]
    let comments: GitHubCommentsModel?
    @Binding var whole: Bool
    @State private var width = 0.0

    var body: some View {
        let rows = render.rows
        let shown = whole ? rows.count : min(rows.count, GitHubDiffLogic.visibleRows)
        let digits = String(rows.map { max($0.old ?? 0, $0.new ?? 0) }.max() ?? 0).count
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<shown, id: \.self) { index in
                        DiffRowView(row: rows[index], spans: render.spans?[index], digits: digits)
                        if let threads = placed[index], let comments {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(threads) { ThreadCard(thread: $0, model: comments) }
                            }
                            .frame(width: max(width - 24, 240), alignment: .leading)
                            .padding(12)
                        }
                    }
                }
                .frame(minWidth: width, alignment: .leading)
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
            if shown < rows.count {
                Button("Show all \(rows.count) lines") { whole = true }.buttonStyle(.link).font(.caption).padding(8)
            }
        }
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
    }
}

private struct DiffRowView: View {
    let row: GitHubDiffRow
    let spans: [SyntaxSpan]?
    let digits: Int

    var body: some View {
        Group {
            switch row.kind {
            case .hunk, .note:
                Text(row.text)
                    .foregroundStyle(.secondary)
                    .italic(row.kind == .note)
                    .padding(.leading, gutter * 2 + 8)
                    .padding(.vertical, 3)
            case .added, .removed, .context:
                HStack(spacing: 0) {
                    number(row.old)
                    number(row.new)
                    Text(marker).foregroundStyle(.secondary).padding(.leading, 8).padding(.trailing, 4)
                    Text(code)
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 1)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var gutter: Double { Double(digits) * 7 + 12 }

    private var code: AttributedString {
        guard !row.text.isEmpty else { return AttributedString(" ") }
        return (spans ?? [SyntaxSpan(text: row.text)]).reduce(into: AttributedString()) { line, span in
            var part = AttributedString(span.text.replacingOccurrences(of: "\t", with: "    "))
            part.foregroundColor = span.kind?.color
            line += part
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: gutter, alignment: .trailing)
    }

    private var marker: String {
        switch row.kind {
        case .added: return "+"
        case .removed: return "\u{2212}"
        default: return " "
        }
    }

    private var background: Color {
        switch row.kind {
        case .added: return Color.green.opacity(0.16)
        case .removed: return Color.red.opacity(0.16)
        case .hunk: return Color.blue.opacity(0.07)
        case .context, .note: return .clear
        }
    }
}

/// A commit's changed files, fetched when the commit is opened.
struct GitHubCommitDiff: View {
    let repo: String
    let commit: GitHubPRDetail.Commit
    @StateObject private var diffs = GitHubDiffModel()

    var body: some View {
        let source = GitHubDiffModel.Source.commit(repo: repo, sha: commit.oid)
        VStack(alignment: .leading, spacing: 0) {
            if diffs.loading && !diffs.loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching the commit\u{2026}").foregroundStyle(.secondary)
                }
                .font(.callout)
            } else if let error = diffs.error {
                Text(error.message).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(diffs.files) { patch in
                GitHubFileDiff(file: GitHubPRDetail.File(path: patch.path, additions: patch.additions, deletions: patch.deletions, change: patch.change),
                               diffs: diffs, source: source, url: commit.url ?? "")
                Divider()
            }
        }
        .padding(.leading, 18)
        .padding(.bottom, 6)
        .onAppear { diffs.load(source) }
    }
}

extension SyntaxKind {
    /// Xcode's default theme colours, which stay readable on the tinted added and removed rows.
    var color: Color { Self.palette[self] ?? .primary }

    private static let palette: [SyntaxKind: Color] = [
        .keyword: adaptive(light: 0x9B2393, dark: 0xFC5FA3),
        .builtin: adaptive(light: 0x6C36A9, dark: 0xA167E6),
        .string: adaptive(light: 0xC41A16, dark: 0xFC6A5D),
        .number: adaptive(light: 0x1C00CF, dark: 0xD0BF69),
        .comment: adaptive(light: 0x5D6C79, dark: 0x7F8C98),
        .decorator: adaptive(light: 0x815F03, dark: 0xBF8555),
        .definition: adaptive(light: 0x0F68A0, dark: 0x41A1C0),
    ]

    private static func adaptive(light: Int, dark: Int) -> Color {
        func rgb(_ hex: Int) -> NSColor {
            NSColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) })
    }
}

extension GitHubPRDetail.Change {
    var symbol: String {
        switch self {
        case .added: return "plus.square.fill"
        case .removed: return "minus.square.fill"
        case .renamed, .copied: return "arrow.right.square.fill"
        case .modified, .changed: return "diamond.fill"
        }
    }

    var color: Color {
        switch self {
        case .added: return .green
        case .removed: return .red
        case .renamed, .copied: return .blue
        case .modified, .changed: return .orange
        }
    }
}
