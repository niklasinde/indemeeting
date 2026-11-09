import Foundation

/// A rule that would map blocks like the one it was offered for.
struct RuleCandidate: Equatable, Hashable {
    let field: RuleField
    let pattern: String

    var text: String { "\(field.label.lowercased()) \u{201C}\(pattern)\u{201D}" }
}

extension ActivityLogic {
    /// The rules that would map blocks like this one, in the order they are tried. A code-host address offers its
    /// repository and organisation instead of the host, which every repository shares.
    static func ruleCandidates(_ key: ActivityKey) -> [RuleCandidate] {
        let host = key.owner == nil ? key.host : nil
        let fields: [(RuleField, String?)] = [(.branch, key.branch), (.ticket, key.ticketPrefix), (.repo, key.repo), (.owner, key.owner),
                                              (.host, host), (.app, host == nil && key.repo == nil ? key.appName : nil)]
        return fields.compactMap { field, pattern in pattern.map { RuleCandidate(field: field, pattern: $0) } }
    }

    /// For a row of "By branch": the exact branch, its ticket prefix and its repository.
    static func ruleCandidates(for item: WorkTotal) -> [RuleCandidate] {
        var candidates = item.name == item.ticket ? [] : [RuleCandidate(field: .branch, pattern: item.name)]
        candidates += item.ticket.map { [RuleCandidate(field: .ticket, pattern: ticketPrefix($0))] } ?? []
        candidates += item.repo.map { [RuleCandidate(field: .repo, pattern: $0)] } ?? []
        return candidates
    }

    static func ruleCandidates(forTicket ticket: String) -> [RuleCandidate] {
        [RuleCandidate(field: .ticket, pattern: ticketPrefix(ticket))]
    }

    /// Whether a rule or a manual choice, not the AI guess, gives the block its project.
    static func hasResolvedProject(_ block: ActivityBlock, rules: [ProjectRule]) -> Bool {
        block.projectID != nil || matchingRule(block.key, rules) != nil
    }

    /// The share of the active time in `range` that has no rule or manual project.
    static func unassignedShare(_ blocks: [ActivityBlock], in range: Range<Date>, rules: [ProjectRule]) -> Double {
        let total = activeSeconds(blocks, in: range)
        guard total > 0 else { return 0 }
        return activeSeconds(blocks.filter { !hasResolvedProject($0, rules: rules) }, in: range) / total
    }
}

/// A rule to create and the project it goes to.
struct SetupChoice: Equatable {
    let field: RuleField
    let pattern: String
    let name: String
}

enum ProjectSetup {
    /// The choices that still need a rule: named, and not already a rule of the same field and pattern.
    static func plan(_ choices: [SetupChoice], rules: [ProjectRule]) -> [SetupChoice] {
        choices.compactMap { choice in
            let name = choice.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let exists = rules.contains { $0.field == choice.field && $0.pattern.caseInsensitiveCompare(choice.pattern) == .orderedSame }
            return name.isEmpty || exists ? nil : SetupChoice(field: choice.field, pattern: choice.pattern, name: name)
        }
    }
}
