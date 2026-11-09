import Foundation

/// One rule a suggestion would add: an organisation, repository, ticket prefix or website, and the time it covers.
struct SetupMember: Equatable, Identifiable {
    let field: RuleField
    let pattern: String
    let seconds: TimeInterval

    var id: String { "\(field.rawValue):\(pattern.lowercased())" }
}

/// Unassigned activity that belongs to one organisation or project, and where it should go.
struct SetupSuggestion: Equatable, Identifiable {
    let id: String
    let members: [SetupMember]
    let seconds: TimeInterval
    let name: String
    /// The existing project the activity matches; nil suggests a new one.
    let projectID: Int64?
    /// Search, mail, social media and the like: offered, but left unchecked.
    let generic: Bool
    /// A few window titles or addresses, to tell what the time was.
    let samples: [String]
}

enum ProjectSuggestionLogic {
    /// Sites that are rarely a project of their own.
    static let genericDomains: Set<String> = [
        "google.com", "google.se", "gmail.com", "youtube.com", "instagram.com", "facebook.com", "messenger.com", "twitter.com", "x.com",
        "reddit.com", "linkedin.com", "tiktok.com", "netflix.com", "spotify.com", "twitch.tv", "claude.ai", "chatgpt.com", "openai.com",
        "claude.com", "anthropic.com", "bing.com", "duckduckgo.com", "wikipedia.org", "apple.com", "icloud.com", "outlook.com", "live.com", "office.com", "microsoft.com",
        "amazon.com", "svt.se", "aftonbladet.se", "expressen.se", "dn.se", "blocket.se",
    ]

    /// Services whose subdomain is the customer: `quiddly.atlassian.net` is Quiddly's, not Atlassian's.
    static let tenantDomains: Set<String> = [
        "atlassian.net", "slack.com", "github.io", "vercel.app", "netlify.app", "herokuapp.com", "zendesk.com", "sharepoint.com",
        "notion.site", "web.app", "firebaseapp.com", "azurewebsites.net", "pages.dev", "workers.dev", "sentry.io",
    ]

    private static let secondLevel: Set<String> = ["co.uk", "org.uk", "com.au", "co.nz", "co.jp", "com.br"]
    private static let repoNoise: Set<String> = ["datagrip", "local", "test", "tests", "api", "ui", "app", "web", "run", "the"]

    /// `www.quiddly.com` and `testadmin.quiddly.com` give `quiddly.com`; `papyrus-se.atlassian.net` stays as it is.
    static func site(_ host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let keep = tenantDomains.contains(lastTwo) || secondLevel.contains(lastTwo) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// The organisation a site belongs to: `quiddly.dev` and `quiddly.com` are both `quiddly`.
    static func organisation(site: String) -> String {
        let labels = site.split(separator: ".").map(String.init)
        let tenant = labels.count > 2 && tenantDomains.contains(labels.suffix(2).joined(separator: "."))
        return organisation(owner: tenant ? labels[0] : labels.first ?? site)
    }

    /// The organisation of the browser profile a window belongs to: Chrome ends its titles with `Niklas (quiddly.com)`.
    static func profileOrganisation(title: String?) -> String? {
        guard let title, let match = title.range(of: #"\(([a-z0-9-]+\.)+[a-z]{2,}\)\s*$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let domain = title[match].trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
        return organisation(site: site(String(domain)))
    }

    /// A window title without the browser and profile Chrome and Safari add to it.
    static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s[-\u2013\u2014]\s(Google Chrome|Safari|Firefox|Brave|Microsoft Edge|Arc)(\s[-\u2013\u2014]\s.*)?$"#,
                                   with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s[-\u2013\u2014]\s(Audio playing|Camera and microphone recording)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func isAddress(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
    }

    /// A site of a generic organisation: `google.co.jp` is as generic as `google.com`.
    static func isGeneric(site: String) -> Bool {
        genericDomains.contains(site.lowercased()) || genericOrganisations.contains(organisation(site: site))
    }

    private static let genericOrganisations = Set(genericDomains.map { organisation(site: $0) })

    /// `quiddly-com` is `quiddly`.
    static func organisation(owner: String) -> String {
        var name = owner.lowercased()
        for suffix in ["-com", "-se", "-io", "-ab", "-app", "-hq", "-inc", "-org", "-dev"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
        }
        return name
    }

    /// `datagrip_finq.api` is `finq`, `indehouse3` is `indehouse`.
    static func cleanName(repo: String) -> String {
        let words = repo.lowercased().split(whereSeparator: { "._- ".contains($0) }).map { word in
            String(word.reversed().drop { $0.isNumber }.reversed()).replacingOccurrences(of: #"v$"#, with: "", options: .regularExpression)
        }
        return words.first { !$0.isEmpty && !repoNoise.contains($0) } ?? repo.lowercased()
    }

    static func displayName(_ word: String) -> String { word.prefix(1).uppercased() + word.dropFirst() }

    /// The owner of a repository without one: from a clone or another block with the same repository, or a known repository
    /// whose name is a whole part of this one (`datagrip_finq.api` holds `finq.api`).
    static func owner(of repo: String, known: [String: String]) -> String? {
        let repo = repo.lowercased()
        if let owner = known[repo] { return owner }
        let candidates = known.keys.filter { name in
            guard name.count >= 4, let range = repo.range(of: name) else { return false }
            let before = range.lowerBound == repo.startIndex ? nil : repo[repo.index(before: range.lowerBound)]
            let after = range.upperBound == repo.endIndex ? nil : repo[range.upperBound]
            return [before, after].allSatisfy { $0.map { !$0.isLetter && !$0.isNumber } ?? true }
        }
        return candidates.max { ($0.count, $1) < ($1.count, $0) }.flatMap { known[$0] }
    }

    /// The owners of the repositories cloned under `root`, by repository and folder name.
    static func cloneOwners(under root: URL, fileManager: FileManager = .default) -> [String: String] {
        ActivityLogic.repositories(under: root, fileManager: fileManager).reduce(into: [:]) { owners, folder in
            let config = (try? String(contentsOf: folder.appendingPathComponent(".git/config"), encoding: .utf8)) ?? ""
            for remote in GitHubClaude.remotes(inGitConfig: config) {
                let parts = remote.split(separator: "/").map(String.init)
                guard parts.count == 2 else { continue }
                owners[parts[1]] = owners[parts[1]] ?? parts[0]
                owners[folder.lastPathComponent.lowercased()] = owners[folder.lastPathComponent.lowercased()] ?? parts[0]
            }
        }
    }

    /// Unassigned activity grouped by organisation, longest first. Members of a group come from the same organisation or
    /// show up together in a block; each group is matched to an existing project when its rules, name or the AI guess point there.
    static func suggestions(_ blocks: [ActivityBlock], rules: [ProjectRule], projects: [Project], owners: [String: String] = [:],
                            minimumSeconds: TimeInterval = 300, memberSeconds: TimeInterval = 120) -> [SetupSuggestion] {
        var known = owners
        for block in blocks { if let repo = block.key.repo, let owner = block.key.owner { known[repo.lowercased()] = owner.lowercased() } }

        var parent: [String: String] = [:]
        func root(_ id: String) -> String {
            var id = id
            while let up = parent[id], up != id { id = up }
            return id
        }
        func union(_ a: String, _ b: String) {
            parent[a] = parent[a] ?? a
            parent[b] = parent[b] ?? b
            let (ra, rb) = (root(a), root(b))
            if ra != rb { parent[rb] = ra }
        }

        var members: [String: (RuleField, String)] = [:]
        var memberTime: [String: TimeInterval] = [:]
        var genericMembers: Set<String> = []
        var profileTime: [String: [String: TimeInterval]] = [:]
        var used: [(ActivityBlock, String)] = []
        for block in blocks where !block.key.idle && !ActivityLogic.hasResolvedProject(block, rules: rules) {
            let key = block.key
            let repoOwner = key.owner ?? key.repo.flatMap { owner(of: $0, known: known) }
            var found: [(RuleField, String, String)] = []
            if let owner = key.owner, !owner.isEmpty { found.append((.owner, owner, "org:" + organisation(owner: owner))) }
            if let repo = key.repo, !repo.isEmpty {
                found.append((.repo, repo, "org:" + (repoOwner.map(organisation(owner:)) ?? cleanName(repo: repo))))
            }
            if let prefix = key.ticketPrefix, !prefix.isEmpty { found.append((.ticket, prefix, "")) }
            if key.owner == nil, let host = key.host, !host.isEmpty, !isAddress(host) {
                let site = site(host)
                found.append((.host, site, "org:" + organisation(site: site)))
            }
            let ids = found.map { field, pattern, org -> String in
                let id = "\(field.rawValue):\(pattern.lowercased())"
                members[id] = members[id] ?? (field, pattern)
                memberTime[id, default: 0] += block.duration
                if field == .host, isGeneric(site: pattern) { genericMembers.insert(id) }
                if field == .host, let profile = profileOrganisation(title: key.windowTitle) { profileTime[id, default: [:]][profile, default: 0] += block.duration }
                union(org.isEmpty ? id : org, id)
                return id
            }
            guard let first = ids.first else { continue }
            for id in ids.dropFirst() where !genericMembers.contains(id) && !genericMembers.contains(first) { union(first, id) }
            used.append((block, first))
        }

        for (id, profiles) in profileTime where !genericMembers.contains(id) {
            if let best = profiles.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value * 2 >= memberTime[id]!, parent["org:" + best.key] != nil {
                union("org:" + best.key, id)
            }
        }

        let ruleProject = Dictionary(grouping: rules) { rule -> String in
            switch rule.field {
            case .owner: return "org:" + organisation(owner: rule.pattern)
            case .host: return "org:" + organisation(site: site(rule.pattern.replacingOccurrences(of: "*.", with: "")))
            default: return "\(rule.field.rawValue):\(rule.pattern.lowercased())"
            }
        }.mapValues { $0.map(\.projectID) }

        let byRoot = Dictionary(grouping: used) { root($0.1) }.mapValues { $0.map(\.0) }
        return byRoot.compactMap { top, groupBlocks -> SetupSuggestion? in
            let seconds = groupBlocks.map(\.duration).reduce(0, +)
            let nodes = parent.keys.filter { root($0) == top }
            let groupMembers = nodes.compactMap { id in
                members[id].flatMap { memberTime[id]! >= memberSeconds ? SetupMember(field: $0.0, pattern: $0.1, seconds: memberTime[id]!) : nil }
            }.sorted { ($0.seconds, $1.id) > ($1.seconds, $0.id) }
            guard seconds >= minimumSeconds, !groupMembers.isEmpty else { return nil }

            let orgs = nodes.filter { $0.hasPrefix("org:") }.sorted()
            let derived = name(members: groupMembers, orgs: orgs)
            let byRule = nodes.flatMap { ruleProject[$0] ?? [] }
            let ruled = Dictionary(grouping: byRule) { $0 }.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
            let named = projects.first { $0.name.caseInsensitiveCompare(derived) == .orderedSame }?.id
            let project = ruled ?? named ?? aiProject(groupBlocks, projects: projects)

            let code = groupMembers.contains { $0.field == .owner || $0.field == .repo }
            let known = groupMembers.allSatisfy { genericMembers.contains($0.id) }
            let workLike = code || ruled != nil || named != nil || mostlyWork(groupBlocks)
            let generic = !code && (known || !workLike || mostlyPersonal(groupBlocks))
            return SetupSuggestion(id: top, members: groupMembers, seconds: seconds,
                                   name: projects.first { $0.id == project }?.name ?? derived, projectID: project,
                                   generic: generic, samples: samples(groupBlocks))
        }
        .sorted { ($0.seconds, $1.id) > ($1.seconds, $0.id) }
    }

    /// The organisation when there is one, else the cleaned repository name, ticket prefix or site.
    private static func name(members: [SetupMember], orgs: [String]) -> String {
        if let owner = members.first(where: { $0.field == .owner }) { return displayName(organisation(owner: owner.pattern)) }
        if let site = members.first(where: { $0.field == .host }), orgs.count == 1 || members.allSatisfy({ $0.field == .host }) {
            return displayName(organisation(site: site.pattern))
        }
        if let org = orgs.first { return displayName(String(org.dropFirst(4))) }
        return members.first.map { $0.field == .ticket ? $0.pattern : displayName(cleanName(repo: $0.pattern)) } ?? ""
    }

    /// The project the AI guessed for at least half of the time.
    private static func aiProject(_ blocks: [ActivityBlock], projects: [Project]) -> Int64? {
        let total = blocks.map(\.duration).reduce(0, +)
        let guesses = Dictionary(grouping: blocks.filter { $0.aiProjectID != nil }) { $0.aiProjectID! }.mapValues { $0.map(\.duration).reduce(0, +) }
        guard let best = guesses.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value * 2 >= total else { return nil }
        return projects.contains { $0.id == best.key } ? best.key : nil
    }

    private static func mostlyWork(_ blocks: [ActivityBlock]) -> Bool {
        let total = blocks.map(\.duration).reduce(0, +)
        return total > 0 && blocks.filter { $0.aiWork == true }.map(\.duration).reduce(0, +) / total >= 0.5
    }

    private static func mostlyPersonal(_ blocks: [ActivityBlock]) -> Bool {
        let total = blocks.map(\.duration).reduce(0, +)
        let personal = blocks.filter { $0.aiWork == false || $0.category == .entertainment }.map(\.duration).reduce(0, +)
        return total > 0 && personal / total >= 0.6
    }

    private static func samples(_ blocks: [ActivityBlock], limit: Int = 2) -> [String] {
        let texts = Dictionary(grouping: blocks) { block -> String in
            let text = block.key.windowTitle.map(cleanTitle) ?? ""
            return text.isEmpty ? block.key.host ?? block.key.repo ?? block.key.appName ?? "" : text
        }
        return texts.filter { !$0.key.isEmpty }.map { ($0.key, $0.value.map(\.duration).reduce(0, +)) }
            .sorted { ($0.1, $1.0) > ($1.1, $0.0) }.prefix(limit).map { String($0.0.prefix(90)) }
    }

    /// What creating the choices does: new projects (by name) and rules not there yet.
    static func summary(_ choices: [SetupChoice], projects: [Project], rules: [ProjectRule]) -> (projects: Int, rules: Int) {
        let plan = ProjectSetup.plan(choices, rules: rules)
        let existing = Set(projects.map { $0.name.lowercased() })
        return (Set(plan.map { $0.name.lowercased() }).subtracting(existing).count, plan.count)
    }

    static func buttonTitle(projects: Int, rules: Int) -> String {
        func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if rules == 0 { return "Create projects & rules" }
        return projects == 0 ? "Add \(count(rules, "rule"))" : "Create \(count(projects, "project")), add \(count(rules, "rule"))"
    }
}
