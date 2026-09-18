import Foundation

// Timelines as rules over what this device holds (#26).
//
// **A timeline is a predicate, never a fetch.** It reads the notes already in the store, in
// store order, and lets through what its rules say. All and Trends are two fixed definitions
// evaluated by the same code as a timeline the reader wrote (Decision 17), so every timeline
// hides a post only by a rule it shows, and asks the same question of `sourcesToAsk`.
//
// How rules combine: rules of one kind are any, rules of different kinds are all, and an
// exclude hides whatever it matches. A timeline with no include rules is All, less its excludes.

/// Which sources a rule is for.
public enum RuleScope: Hashable, Sendable {
    case every
    /// One source, by its host, lowercased as `Source` keeps it.
    case source(host: String)
}

public enum RuleEffect: String, Hashable, Sendable {
    case include
    case exclude
}

/// What a rule names.
///
/// **Every kind a stored timeline can hold.** A loader meeting a kind it cannot name must refuse
/// the timelines rather than drop the rule (Decision 15): a dropped include widens a timeline and
/// a dropped exclude brings back what the reader hid.
public enum RuleKind: Hashable, Sendable {
    /// Everything that arrived through this source. Always for that one source.
    case source(host: String)
    /// One person, stored folded as `user@instance`.
    case author(handle: String, in: RuleScope)
    /// Text a post's body contains, stored as the reader typed it; folded when compiled.
    /// Anywhere, with no word breaking: `#swift` matches `#swiftui` too.
    case keyword(String, in: RuleScope)
    case category(Category, in: RuleScope)

    /// The kinds, in the order a timeline tries them — which is also the order that decides
    /// which rule an omitted post is put down to (Decision 14).
    public enum Tag: CaseIterable, Hashable, Sendable {
        case source, author, keyword, category
    }

    public var tag: Tag {
        switch self {
        case .source: .source
        case .author: .author
        case .keyword: .keyword
        case .category: .category
        }
    }

    var scope: RuleScope {
        switch self {
        case .source(let host): .source(host: host)
        case .author(_, let scope), .keyword(_, let scope), .category(_, let scope): scope
        }
    }
}

/// One rule of a timeline.
///
/// **Made only through the factories**, which refuse what cannot mean anything: an empty keyword,
/// a handle with no instance, a board or list for every source, and public, trends or home on a
/// forum. `id` is a parameter so a stored rule comes back as the same rule.
public struct Rule: Hashable, Sendable, Identifiable {
    public let id: UUID
    public var effect: RuleEffect
    public let kind: RuleKind

    private init(id: UUID, effect: RuleEffect, kind: RuleKind) {
        self.id = id
        self.effect = effect
        self.kind = kind
    }

    public static func source(_ host: String, effect: RuleEffect = .include, id: UUID = UUID()) -> Rule? {
        let host = host.lowercased()
        guard !host.isEmpty else { return nil }
        return Rule(id: id, effect: effect, kind: .source(host: host))
    }

    /// An author as `user@instance`, with or without the leading `@`.
    ///
    /// **A forum author is that forum's**, so naming one that `sources` holds as a forum makes
    /// the rule for that source whatever scope was asked for: the same name on another forum is
    /// somebody else.
    public static func author(
        _ handle: String,
        in scope: RuleScope,
        effect: RuleEffect = .include,
        sources: [Source],
        id: UUID = UUID()
    ) -> Rule? {
        let folded = Fold.handle(handle.trimmingCharacters(in: .whitespacesAndNewlines))
        let parts = folded.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, let scope = normalised(scope) else {
            return nil
        }
        let instance = String(parts[1])
        let forum = sources.contains { $0.host == instance && $0.kind.isForum }
        return Rule(id: id, effect: effect, kind: .author(handle: folded, in: forum ? .source(host: instance) : scope))
    }

    public static func keyword(
        _ text: String,
        in scope: RuleScope,
        effect: RuleEffect = .include,
        id: UUID = UUID()
    ) -> Rule? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let scope = normalised(scope) else {
            return nil
        }
        return Rule(id: id, effect: effect, kind: .keyword(text, in: scope))
    }

    /// A category. A board or a list is one source's, so it is never for every source; public,
    /// trends and home are Mastodon's, so never for a source `sources` holds as something else.
    public static func category(
        _ category: Category,
        in scope: RuleScope,
        effect: RuleEffect = .include,
        sources: [Source],
        id: UUID = UUID()
    ) -> Rule? {
        guard let scope = normalised(scope) else { return nil }
        switch (category, scope) {
        case (.board, .every), (.list, .every):
            return nil
        case (.public, .source(let host)), (.trends, .source(let host)), (.home, .source(let host)):
            if let source = sources.first(where: { $0.host == host }), !source.kind.hasTimelines { return nil }
        default:
            break
        }
        return Rule(id: id, effect: effect, kind: .category(category, in: scope))
    }

    private static func normalised(_ scope: RuleScope) -> RuleScope? {
        switch scope {
        case .every: .every
        case .source(let host): host.isEmpty ? nil : .source(host: host.lowercased())
        }
    }
}

public typealias TimelineID = UUID

/// A timeline: a name and its rules, in the reader's order.
public struct TimelineDefinition: Hashable, Sendable, Identifiable {
    public let id: TimelineID
    public var name: String
    public var rules: [Rule]

    public init(id: TimelineID = UUID(), name: String, rules: [Rule]) {
        self.id = id
        self.name = name
        self.rules = rules
    }

    /// Everything held. No rules.
    public static let all = TimelineDefinition(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000A11A")!,
        name: "All",
        rules: []
    )

    /// What arrived as trending, on every source that has trends.
    public static let trends = TimelineDefinition(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000073E5")!,
        name: "Trends",
        rules: [
            Rule.category(
                .trends, in: .every, sources: [], id: UUID(uuidString: "00000000-0000-0000-0000-0000000073E6")!
            )!,
        ]
    )
}

/// What a timeline does with one note: shows it, or names the one rule that hid it.
public enum Verdict: Equatable, Sendable {
    case shown
    case hidden(by: Rule.ID)
}

/// Whether what a rule names is still here. A rule naming something gone stays, says so, and
/// keeps matching the posts already held (Decision 16).
public enum RuleStatus: Equatable, Sendable {
    case present
    case missingSource(host: String)
    case missingCategory
}

/// One source a timeline wants asked on a reload (#29), and what to ask it for.
public struct FetchAsk: Hashable, Sendable {
    public let host: String
    /// The categories to fetch, or nothing for the source's usual reads.
    public let categories: Set<Category>?

    public init(host: String, categories: Set<Category>?) {
        self.host = host
        self.categories = categories
    }
}

/// A timeline made ready against the sources held now: build once, then ask it about many notes.
public struct CompiledTimeline: Sendable {
    private enum Check: Sendable {
        case host(String)
        case handle(String)
        case keyword(String)
        case category(Category)
    }

    private struct Matcher: Sendable {
        let id: Rule.ID
        let host: String?
        let check: Check
    }

    public let definition: TimelineDefinition
    private let sources: [Source]
    private let excludes: [Matcher]
    /// One entry per kind that has includes, in `Tag` order.
    private let groups: [[Matcher]]

    public init(_ definition: TimelineDefinition, sources: [Source]) {
        self.definition = definition
        self.sources = sources
        let matchers = definition.rules.map { rule in (rule, Self.matcher(rule)) }
        excludes = matchers.filter { $0.0.effect == .exclude }.map(\.1)
        let includes = matchers.filter { $0.0.effect == .include }
        groups = RuleKind.Tag.allCases.compactMap { tag in
            let group = includes.filter { $0.0.kind.tag == tag }.map(\.1)
            return group.isEmpty ? nil : group
        }
    }

    private static func matcher(_ rule: Rule) -> Matcher {
        let host: String? = switch rule.kind.scope {
        case .every: nil
        case .source(let host): host
        }
        let check: Check = switch rule.kind {
        case .source(let host): .host(host)
        case .author(let handle, _): .handle(handle)
        case .keyword(let text, _): .keyword(Fold.key(text))
        case .category(let category, _): .category(category)
        }
        return Matcher(id: rule.id, host: host, check: check)
    }

    public func verdict(_ note: Note, _ index: TextIndex) -> Verdict {
        var entry: TextIndex.Entry?
        func matches(_ matcher: Matcher) -> Bool {
            if let host = matcher.host, host != note.source.host { return false }
            switch matcher.check {
            case .host: return true
            case .category(let category): return note.categories.contains(category)
            case .handle(let handle):
                let found = entry ?? index.entry(for: note)
                entry = found
                return found.foldedHandle == handle || found.foldedBooster == handle
            case .keyword(let text):
                let found = entry ?? index.entry(for: note)
                entry = found
                return Fold.contains(found.text, text)
            }
        }
        if let hit = excludes.first(where: matches) { return .hidden(by: hit.id) }
        for group in groups where !group.contains(where: matches) {
            return .hidden(by: group[0].id)
        }
        return .shown
    }

    /// The notes this timeline lets through, in the order given.
    public func shown(_ notes: [Note], _ index: TextIndex) -> [Note] {
        if excludes.isEmpty && groups.isEmpty { return notes }
        return notes.filter { verdict($0, index) == .shown }
    }

    public func status(of rule: Rule) -> RuleStatus {
        guard case .source(let host) = rule.kind.scope else { return .present }
        guard let source = sources.first(where: { $0.host == host }) else { return .missingSource(host: host) }
        if case .category(.board(let id), _) = rule.kind, !source.boards.contains(where: { String($0.fid) == id }) {
            return .missingCategory
        }
        // A list no longer chosen on this device, or no longer the account's (#25).
        if case .category(.list(let id), _) = rule.kind, !source.lists.contains(where: { $0.id == id }) {
            return .missingCategory
        }
        return .present
    }

    /// Which sources a reload of this timeline should ask, and for what (#29).
    ///
    /// Only sources held now: a rule naming something gone asks nothing. A source every include
    /// kind can reach is asked; an excluded source is not. With category rules it is asked for
    /// the categories they name there, less those excluded; without, for its usual reads.
    public func sourcesToAsk() -> [FetchAsk] {
        let includes = definition.rules.filter { $0.effect == .include }
        let excludes = definition.rules.filter { $0.effect == .exclude }

        var hosts = Set(sources.map(\.host))
        for tag in RuleKind.Tag.allCases {
            let group = includes.filter { $0.kind.tag == tag }
            guard !group.isEmpty else { continue }
            hosts.formIntersection(sources.filter { source in group.contains { reaches($0, source) } }.map(\.host))
        }
        for rule in excludes {
            if case .source(let host) = rule.kind { hosts.remove(host) }
        }

        let categoryRules = includes.filter { $0.kind.tag == .category }
        return sources.compactMap { source in
            guard hosts.contains(source.host) else { return nil }
            guard !categoryRules.isEmpty else { return FetchAsk(host: source.host, categories: nil) }
            var wanted: Set<Category> = []
            for rule in categoryRules where reaches(rule, source) {
                if case .category(let category, _) = rule.kind { wanted.insert(category) }
            }
            for rule in excludes where reaches(rule, source) {
                if case .category(let category, _) = rule.kind { wanted.remove(category) }
            }
            return wanted.isEmpty ? nil : FetchAsk(host: source.host, categories: wanted)
        }
    }

    /// Whether a rule can be about notes from this source at all. A rule naming something gone
    /// reaches nothing, so an include kind made only of those asks nobody.
    private func reaches(_ rule: Rule, _ source: Source) -> Bool {
        guard status(of: rule) == .present else { return false }
        if case .source(let host) = rule.kind.scope, host != source.host { return false }
        guard case .category(let category, _) = rule.kind else { return true }
        switch category {
        case .public, .trends, .home, .list: return source.kind.hasTimelines
        case .board: return source.kind.isForum
        }
    }
}
