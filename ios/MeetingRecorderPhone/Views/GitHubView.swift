import SwiftUI

enum PRTab: String, CaseIterable, Identifiable {
    case created = "Created", review = "Review requested", assigned = "Assigned", mentioned = "Mentioned"
    var id: String { rawValue }

    var key: String {
        switch self {
        case .created: return "created"
        case .review: return "review_requested"
        case .assigned: return "assigned"
        case .mentioned: return "mentioned"
        }
    }

    var shortName: String { self == .review ? "Review" : rawValue }
}

struct GitHubView: View {
    @Environment(AppModel.self) private var appModel
    @State private var resource: Resource<PhoneGitHub>?
    @State private var tab = PRTab.created
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            Group {
                if let resource { content(resource) } else { ProgressView() }
            }
            .navigationTitle("GitHub")
        }
        .task {
            let resource = resource ?? Resource<PhoneGitHub>(model: appModel)
            self.resource = resource
            await resource.load("github", .get("/v1/github"))
        }
    }

    @ViewBuilder
    private func content(_ resource: Resource<PhoneGitHub>) -> some View {
        if let github = resource.value, !github.enabled {
            ProblemView(title: "GitHub is off", message: "Turn on GitHub in the Mac app's Settings to see your pull requests here.", systemImage: "arrow.triangle.pull")
        } else {
            List {
                Section {
                    Picker("List", selection: $tab) {
                        ForEach(PRTab.allCases) { Text("\($0.shortName) \(count($0, resource))").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                SyncBanner(error: resource.error, syncedAt: resource.syncedAt) { Task { await refresh(resource) } }
                    .listRowBackground(Color.orange.opacity(0.12))
                if let message = resource.value?.error {
                    Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                let prs = resource.value?.prs[tab.key] ?? []
                Section {
                    ForEach(prs, id: \.url) { PRRow(pr: $0) }
                } footer: {
                    if let refreshed = resource.value?.refreshedAt { Text("Updated on the Mac \(refreshed.formatted(.relative(presentation: .named)))") }
                }
            }
            .overlay {
                if resource.value == nil {
                    if resource.isLoading { ProgressView() }
                    else if let error = resource.error { ProblemView(title: error.problemTitle, message: error.hint, actionTitle: "Try again") { Task { await resource.load("github", .get("/v1/github")) } } }
                } else if (resource.value?.prs[tab.key] ?? []).isEmpty {
                    ProblemView(title: "Nothing here", message: "No pull requests in \u{201C}\(tab.rawValue)\u{201D}.", systemImage: "checkmark.circle")
                }
            }
            .refreshable { await refresh(resource) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if refreshing { ProgressView() } else {
                        Button { Task { await refresh(resource) } } label: { Label("Refresh from GitHub", systemImage: "arrow.clockwise") }
                    }
                }
            }
        }
    }

    private func count(_ tab: PRTab, _ resource: Resource<PhoneGitHub>) -> String {
        let number = resource.value?.prs[tab.key]?.count ?? 0
        return number > 0 ? "\(number)" : ""
    }

    /// Asks the Mac to fetch from GitHub, which can take several seconds, and falls back to its cache.
    private func refresh(_ resource: Resource<PhoneGitHub>) async {
        refreshing = true
        defer { refreshing = false }
        do {
            let fresh: PhoneGitHub = try await appModel.request(PhoneRequest(method: "POST", path: "/v1/github/refresh"), idleTimeout: 90)
            resource.replace(fresh, key: "github")
        } catch is CancellationError {
        } catch {
            await resource.load("github", .get("/v1/github"))
        }
    }
}

struct PRRow: View {
    @Environment(\.openURL) private var openURL
    let pr: PhonePR

    var body: some View {
        Button { URL(string: pr.url).map { openURL($0) } } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: stateSymbol).foregroundStyle(stateColor).font(.title3).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(pr.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(3)
                    Text("\(pr.repo) #\(pr.number)\(pr.author.map { " \u{00B7} \($0)" } ?? "") \u{00B7} \(pr.updated.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 4) {
                        if pr.isDraft { Chip(text: "Draft", systemImage: "pencil") }
                        if pr.phase == .open, let check = checkChip { check }
                        if pr.phase == .open, let review = reviewChip { review }
                        if let ticket = pr.ticket { Chip(text: ticket, systemImage: "ticket", tint: .blue) }
                        Chip(text: "+\(pr.additions)", tint: .green)
                        Chip(text: "\u{2212}\(pr.deletions)", tint: .red)
                        if pr.comments > 0 { Chip(text: "\(pr.comments)", systemImage: "bubble.left") }
                        ForEach(pr.labels.prefix(3), id: \.self) { Chip(text: $0) }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the pull request in Safari")
    }

    private var stateSymbol: String {
        switch pr.phase {
        case .open: return pr.isDraft ? "pencil.circle" : "arrow.triangle.pull"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        }
    }

    private var stateColor: Color {
        switch pr.phase {
        case .open: return pr.isDraft ? .secondary : .green
        case .merged: return .purple
        case .closed: return .red
        }
    }

    private var checkChip: Chip? {
        switch pr.checks {
        case "passed": return Chip(text: "Checks passed", systemImage: "checkmark.circle.fill", tint: .green)
        case "failed": return Chip(text: "Checks failed", systemImage: "xmark.circle.fill", tint: .red)
        case "running": return Chip(text: "Checks running", systemImage: "clock", tint: .orange)
        default: return nil
        }
    }

    private var reviewChip: Chip? {
        switch pr.review {
        case "approved": return Chip(text: "Approved", systemImage: "checkmark.seal", tint: .green)
        case "changes_requested": return Chip(text: "Changes requested", systemImage: "exclamationmark.bubble", tint: .red)
        case "required": return Chip(text: "Review required", systemImage: "eye", tint: .orange)
        default: return nil
        }
    }
}

extension PhonePR {
    enum Phase { case open, merged, closed }

    var phase: Phase {
        switch state {
        case "merged": return .merged
        case "closed": return .closed
        default: return .open
        }
    }
}
