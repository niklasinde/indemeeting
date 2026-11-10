import SwiftUI

/// The notch bar's panels as set up in Settings. Panels that are off, or the whole bar when it is hidden, fetch nothing.
@MainActor
final class NotchPanelsModel: ObservableObject {
    static let shared = NotchPanelsModel()

    @Published private(set) var setup = NotchPanelSetup(defaults: .standard)

    var shown: [NotchPanelID] { setup.shown }

    func update(_ setup: NotchPanelSetup) {
        self.setup = setup
        setup.save(to: .standard)
        apply()
    }

    func reload() {
        let stored = NotchPanelSetup(defaults: .standard)
        if stored != setup { setup = stored }
        apply()
    }

    #if DEBUG
    /// Shows a setup without storing it, for the previews.
    func showSample(_ setup: NotchPanelSetup) { self.setup = setup }
    #endif

    private func apply() {
        let visible = UserDefaults.standard.bool(forKey: AskPanel.shownKey) ? Set(setup.shown) : []
        JiraModel.shared.setShown(visible.contains(.jira))
        SlackModel.shared.setShown(visible.contains(.slack))
    }
}

extension NotchPanelID {
    @MainActor var available: Bool {
        switch self {
        case .jira: JiraModel.shared.configured
        case .todo: true
        case .gitHub: GitHubModel.shared.enabled
        case .slack: SlackModel.shared.configured
        }
    }

    @MainActor var setupHint: String? {
        guard !available else { return nil }
        switch self {
        case .jira: return "Not set up: add your Jira site and token below."
        case .todo: return nil
        case .gitHub: return "Off: turn on GitHub below."
        case .slack: return "Not set up: paste a Slack user token below."
        }
    }

    @ViewBuilder var icon: some View {
        switch self {
        case .jira: BrandMark.jira
        case .todo: Image(systemName: "checklist").resizable()
        case .gitHub: BrandMark.gitHub
        case .slack: BrandMark.slack
        }
    }
}

struct NotchBarSettingsSection: View {
    @ObservedObject var model: NotchPanelsModel
    @AppStorage(AskPanel.shownKey) private var showsBar = true

    var body: some View {
        SettingsSection("Notch bar", footer: "The icons are split over the bar in this order: the first half left of the notch, the "
                        + "second half right of it, and an odd one out in the middle, below the notch. To put one panel in another's "
                        + "place, turn the old one off and the new one on, then move it with the arrows. Panels that are off fetch nothing.") {
            SettingsRow("Show the notch bar") {
                Toggle("Show the notch bar", isOn: $showsBar).labelsHidden().toggleStyle(.switch)
            }
            ForEach(Array(model.setup.order.enumerated()), id: \.element) { index, id in
                Divider().padding(.leading, 14)
                row(id, index: index)
            }
            Divider().padding(.leading, 14)
            Text(placement).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func row(_ id: NotchPanelID, index: Int) -> some View {
        let enabled = model.setup.enabled.contains(id)
        return HStack(spacing: 10) {
            id.icon.scaledToFit().frame(width: 16, height: 16).opacity(enabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(id.title)
                if enabled, let hint = id.setupHint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            Button { model.update(model.setup.moving(id, by: -1)) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).help("Move \(id.title) earlier")
            Button { model.update(model.setup.moving(id, by: 1)) } label: { Image(systemName: "chevron.down") }
                .disabled(index == model.setup.order.count - 1).help("Move \(id.title) later")
            Toggle("Show \(id.title)", isOn: Binding(get: { enabled }, set: { model.update(model.setup.turning(id, on: $0)) }))
                .labelsHidden().toggleStyle(.switch)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
    }

    private var placement: String {
        let wings = NotchWings.split(model.setup.shown)
        let names = { (ids: [NotchPanelID]) in ids.isEmpty ? "nothing" : ids.map(\.title).joined(separator: ", ") }
        let middle = wings.middle.isEmpty ? "" : " \u{00B7} Middle: \(names(wings.middle))"
        return "Left: \(names(wings.left))\(middle) \u{00B7} Right: \(names(wings.right))"
    }
}
