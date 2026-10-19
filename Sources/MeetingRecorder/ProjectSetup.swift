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

/// One repository, organisation, ticket prefix or website found in unassigned activity, with the project name suggested for it.
struct SetupGroup: Equatable, Identifiable {
    let field: RuleField
    let pattern: String
    let seconds: TimeInterval
    let suggestedName: String

    var id: String { "\(field.rawValue):\(pattern)" }
}

/// A rule to create and the project it goes to.
struct SetupChoice: Equatable {
    let field: RuleField
    let pattern: String
    let name: String
}

enum ProjectSetup {
    /// Groups of unassigned activity, longest first. Groups that appear together in a block (a repository and the
    /// organisation or ticket prefix of its pages) get the same suggested name.
    static func groups(_ blocks: [ActivityBlock], rules: [ProjectRule], minimumSeconds: TimeInterval = 300) -> [SetupGroup] {
        var seconds: [String: TimeInterval] = [:]
        var items: [String: (RuleField, String)] = [:]
        var parent: [String: String] = [:]
        func root(_ id: String) -> String {
            var id = id
            while let up = parent[id], up != id { id = up }
            return id
        }
        for block in blocks where !block.key.idle && !ActivityLogic.hasResolvedProject(block, rules: rules) {
            let key = block.key
            let found: [(RuleField, String?)] = [(.owner, key.owner), (.repo, key.repo), (.ticket, key.ticketPrefix),
                                                 (.host, key.owner == nil ? key.host : nil)]
            let ids = found.compactMap { field, pattern -> String? in
                guard let pattern, !pattern.isEmpty else { return nil }
                let id = "\(field.rawValue):\(pattern.lowercased())"
                items[id] = items[id] ?? (field, pattern)
                seconds[id, default: 0] += block.duration
                return id
            }
            for id in ids {
                parent[id] = parent[id] ?? id
                parent[root(id)] = root(ids[0])
            }
        }
        let ranked = [RuleField.owner, .repo, .host, .ticket]
        var names: [String: String] = [:]
        for top in Set(items.keys.map(root)) {
            let best = items.keys.filter { root($0) == top }.min { a, b in
                (ranked.firstIndex(of: items[a]!.0)!, -seconds[a]!, a) < (ranked.firstIndex(of: items[b]!.0)!, -seconds[b]!, b)
            }!
            names[top] = suggestedName(for: items[best]!.1)
        }
        return items.compactMap { id, item in
            seconds[id]! >= minimumSeconds ? SetupGroup(field: item.0, pattern: item.1, seconds: seconds[id]!, suggestedName: names[root(id)]!) : nil
        }.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }
    }

    /// `quiddly-com` and `quiddly.atlassian.net` suggest "Quiddly", `finq.api` "Finq".
    static func suggestedName(for pattern: String) -> String {
        var name = pattern.lowercased()
        if name.hasPrefix("www.") { name.removeFirst(4) }
        let word = name.split(whereSeparator: { ".-_".contains($0) }).first.map(String.init) ?? name
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// The choices that still need a rule: named, and not already a rule of the same field and pattern.
    static func plan(_ choices: [SetupChoice], rules: [ProjectRule]) -> [SetupChoice] {
        choices.compactMap { choice in
            let name = choice.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let exists = rules.contains { $0.field == choice.field && $0.pattern.caseInsensitiveCompare(choice.pattern) == .orderedSame }
            return name.isEmpty || exists ? nil : SetupChoice(field: choice.field, pattern: choice.pattern, name: name)
        }
    }
}
