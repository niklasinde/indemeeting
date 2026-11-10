import Foundation

/// The lists the notch bar can show, one icon each in its top row.
enum NotchPanelID: String, CaseIterable, Identifiable, Sendable {
    case jira, todo, gitHub, slack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jira: "Jira"
        case .todo: "Reminders"
        case .gitHub: "GitHub"
        case .slack: "Slack"
        }
    }

    var hotkey: Character {
        switch self {
        case .jira: "j"
        case .todo: "t"
        case .gitHub: "g"
        case .slack: "s"
        }
    }

    static func hotkey(_ key: Character) -> NotchPanelID? { allCases.first { $0.hotkey == key } }
}

/// Which panels the notch bar shows and in what order, as stored in UserDefaults.
struct NotchPanelSetup: Equatable, Sendable {
    static let orderKey = "notchPanelOrder"
    static let enabledKey = "notchPanelsEnabled"
    static let defaultOrder: [NotchPanelID] = [.jira, .todo, .gitHub, .slack]
    static let defaultEnabled: Set<NotchPanelID> = [.jira, .todo, .gitHub]
    static let standard = NotchPanelSetup(order: defaultOrder, enabled: defaultEnabled)

    var order: [NotchPanelID]
    var enabled: Set<NotchPanelID>

    var shown: [NotchPanelID] { order.filter(enabled.contains) }

    /// Unknown or repeated ids are dropped. A panel missing from the stored order is new: it goes last, with its default state.
    init(storedOrder: [String]?, storedEnabled: [String]?) {
        guard let storedOrder else {
            self = .standard
            return
        }
        var known: [NotchPanelID] = []
        for id in storedOrder.compactMap(NotchPanelID.init(rawValue:)) where !known.contains(id) { known.append(id) }
        let new = Self.defaultOrder.filter { !known.contains($0) }
        let stored = Set((storedEnabled ?? []).compactMap(NotchPanelID.init(rawValue:)))
        order = known + new
        enabled = stored.intersection(known).union(Self.defaultEnabled.intersection(new))
    }

    init(order: [NotchPanelID], enabled: Set<NotchPanelID>) {
        self.order = order
        self.enabled = enabled
    }

    /// What goes into UserDefaults: every panel in order, so a later one is known as new, and the ones turned on.
    var stored: (order: [String], enabled: [String]) {
        (order.map(\.rawValue), shown.map(\.rawValue))
    }

    init(defaults: UserDefaults) {
        self.init(storedOrder: defaults.stringArray(forKey: Self.orderKey), storedEnabled: defaults.stringArray(forKey: Self.enabledKey))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(stored.order, forKey: Self.orderKey)
        defaults.set(stored.enabled, forKey: Self.enabledKey)
    }

    func moving(_ id: NotchPanelID, by offset: Int) -> NotchPanelSetup {
        guard let from = order.firstIndex(of: id) else { return self }
        let to = min(max(from + offset, 0), order.count - 1)
        var copy = self
        copy.order.remove(at: from)
        copy.order.insert(id, at: to)
        return copy
    }

    func turning(_ id: NotchPanelID, on: Bool) -> NotchPanelSetup {
        var copy = self
        if on { copy.enabled.insert(id) } else { copy.enabled.remove(id) }
        return copy
    }
}

enum NotchWings {
    /// Splits the icons over the bar: the first half on the left wing, the second on the right, and an odd one out in the middle,
    /// where a notched screen shows it below the notch. A single icon sits on the right.
    static func split<T>(_ items: [T]) -> (left: [T], middle: [T], right: [T]) {
        guard items.count > 1 else { return ([], [], items) }
        let half = items.count / 2
        return (Array(items.prefix(half)), Array(items.dropFirst(half).prefix(items.count % 2)), Array(items.suffix(half)))
    }

    /// How wide each wing is: both as wide as the fuller one, so the bar stays centred on the notch.
    static func width<T>(_ items: [T], icon: CGFloat) -> CGFloat {
        let wings = split(items)
        return CGFloat(max(wings.left.count, wings.right.count, 1)) * icon
    }
}
