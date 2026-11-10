import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let notchPanelTests: [(name: String, run: () throws -> Void)] = [
    ("nothing stored shows today's panels in today's order, with Slack off", {
        let setup = NotchPanelSetup(storedOrder: nil, storedEnabled: nil)
        check(setup.order == [.jira, .todo, .gitHub, .slack], "order \(setup.order)")
        check(setup.shown == [.jira, .todo, .gitHub], "shown \(setup.shown)")
        check(setup == .standard, "the standard setup")
    }),

    ("unknown and repeated stored ids are dropped and a new panel is added last with its default state", {
        let setup = NotchPanelSetup(storedOrder: ["gitHub", "teams", "jira", "gitHub"], storedEnabled: ["gitHub", "teams"])
        check(setup.order == [.gitHub, .jira, .todo, .slack], "known ones keep their order, new ones follow: \(setup.order)")
        check(setup.enabled == [.gitHub, .todo], "Jira stays off as stored, Reminders is new and on by default, Slack new and off: \(setup.enabled)")
        check(setup.shown == [.gitHub, .todo], "shown \(setup.shown)")
        let removedAll = NotchPanelSetup(storedOrder: ["teams"], storedEnabled: ["teams"])
        check(removedAll == .standard, "only removed ids falls back to the defaults")
        let allOff = NotchPanelSetup(storedOrder: ["jira", "todo", "gitHub", "slack"], storedEnabled: [])
        check(allOff.shown.isEmpty, "a stored empty set stays empty")
    }),

    ("the setup is stored as id lists and read back the same", {
        let setup = NotchPanelSetup.standard.turning(.gitHub, on: false).turning(.slack, on: true).moving(.slack, by: -1)
        check(setup.stored.order == ["jira", "todo", "slack", "gitHub"], "order stored")
        check(setup.stored.enabled == ["jira", "todo", "slack"], "enabled stored in order")
        check(NotchPanelSetup(storedOrder: setup.stored.order, storedEnabled: setup.stored.enabled) == setup, "read back")
    }),

    ("moving stops at the ends and turning a panel off keeps its place", {
        let setup = NotchPanelSetup.standard
        check(setup.moving(.jira, by: -1).order == setup.order, "first stays first")
        check(setup.moving(.slack, by: 5).order == setup.order, "last stays last")
        check(setup.moving(.gitHub, by: -2).order == [.gitHub, .jira, .todo, .slack], "moved up twice")
        let off = setup.turning(.todo, on: false)
        check(off.order == setup.order && off.shown == [.jira, .gitHub], "off: \(off.shown)")
    }),

    ("the icons split into the left wing, the middle and the right wing for one to five panels", {
        let cases: [([Int], [Int], [Int], [Int])] = [
            ([], [], [], []), ([1], [], [], [1]), ([1, 2], [1], [], [2]), ([1, 2, 3], [1], [2], [3]),
            ([1, 2, 3, 4], [1, 2], [], [3, 4]), ([1, 2, 3, 4, 5], [1, 2], [3], [4, 5]),
        ]
        for (items, left, middle, right) in cases {
            let wings = NotchWings.split(items)
            check(wings.left == left && wings.middle == middle && wings.right == right, "\(items): \(wings)")
            check(NotchWings.width(items, icon: 34) == CGFloat(max(left.count, right.count, 1)) * 34, "width for \(items)")
        }
    }),

    ("today's set puts Jira left, Reminders in the middle and GitHub right", {
        let wings = NotchWings.split(NotchPanelSetup.standard.shown)
        check(wings.left == [.jira] && wings.middle == [.todo] && wings.right == [.gitHub], "\(wings)")
    }),

    ("with GitHub off and Slack on, Slack takes GitHub's place in the right wing", {
        let swapped = NotchPanelSetup.standard.turning(.gitHub, on: false).turning(.slack, on: true)
        check(swapped.shown == [.jira, .todo, .slack], "shown \(swapped.shown)")
        let wings = NotchWings.split(swapped.shown)
        check(wings.left == [.jira] && wings.middle == [.todo] && wings.right == [.slack], "\(wings)")
        check(NotchWings.width(swapped.shown, icon: 34) == NotchWings.width(NotchPanelSetup.standard.shown, icon: 34), "same wing width")
        let stored = NotchPanelSetup(storedOrder: ["jira", "todo", "gitHub", "slack"], storedEnabled: ["jira", "todo", "slack"])
        check(NotchWings.split(stored.shown).right == [.slack], "also when read from defaults")
    }),

    ("each panel has its own hotkey", {
        check(NotchPanelID.hotkey("g") == .gitHub && NotchPanelID.hotkey("j") == .jira, "g and j")
        check(NotchPanelID.hotkey("t") == .todo && NotchPanelID.hotkey("s") == .slack, "t and s")
        check(NotchPanelID.hotkey("x") == nil, "no x")
        check(Set(NotchPanelID.allCases.map(\.hotkey)).count == NotchPanelID.allCases.count, "unique")
    }),
]
