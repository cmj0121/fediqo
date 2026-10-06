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
// A rule on a field one kind of source declares (#287) is of its field's kind: two on one field
// are any, and two on two fields are all.

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
    /// What a field one kind of source declares says of a post (#287): the field by its stable
    /// name, and the value asked for, typed as the field is. **One kind for every such field**, so
    /// a field or a type added later is a new name or a new value and never a new kind.
    ///
    /// A post whose source's kind declares no such field, or says nothing for it, does not match:
    /// the rule neither shows it nor hides it.
    case field(name: String, is: FieldValue, in: RuleScope)

    /// The kinds, in the order a timeline tries them — which is also the order that decides
    /// which rule an omitted post is put down to (Decision 14).
    public enum Tag: CaseIterable, Hashable, Sendable {
        case source, author, keyword, category, field
    }

    public var tag: Tag {
        switch self {
        case .source: .source
        case .author: .author
        case .keyword: .keyword
        case .category: .category
        case .field: .field
        }
    }

    /// What rules are grouped by, to be any among themselves and all across: the kind — and,
    /// for a rule on a field, the field. Two rules on one field are any; a rule on one field and
    /// a rule on another are all.
    public enum Group: Hashable, Sendable {
        case kind(Tag)
        case field(String)
    }

    public var group: Group {
        if case .field(let name, _, _) = self { return .field(name) }
        return .kind(tag)
    }

    var scope: RuleScope {
        switch self {
        case .source(let host): .source(host: host)
        case .author(_, let scope), .keyword(_, let scope), .category(_, let scope), .field(_, _, let scope): scope
        }
    }

    /// The groups `rules` fall into, in the order a timeline tries them: the kinds in `Tag`'s
    /// order, then each field in the order its first rule stands.
    public static func groups(of rules: [Rule]) -> [Group] {
        var seen: Set<Group> = []
        let kinds = Tag.allCases.map(Group.kind).filter { group in rules.contains { $0.kind.group == group } }
        let fields = rules.map(\.kind.group).filter { group in
            if case .field = group { return seen.insert(group).inserted }
            return false
        }
        return kinds + fields
    }
}

/// One rule of a timeline.
///
/// **Made only through the factories**, which refuse what cannot mean anything: an empty keyword,
/// a handle with no instance, a board or list for every source, public or home on a forum, and
/// trends on a forum that ranks nothing. `id` is a parameter so a stored rule comes back as the same rule.
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
        guard let folded = Self.handle(handle), let scope = normalised(scope) else { return nil }
        let instance = String(folded.split(separator: "@")[1])
        let forum = sources.contains { $0.host == instance && $0.kind.isForum }
        return Rule(id: id, effect: effect, kind: .author(handle: folded, in: forum ? .source(host: instance) : scope))
    }

    /// A handle as a rule holds one: `user@instance`, folded, with or without a leading `@` and
    /// whatever space was typed round it — or nothing where it is not a user and an instance.
    /// **The one reading of a handle a rule is made from**, an author's and a field's alike.
    public static func handle(_ raw: String) -> String? {
        let folded = Fold.handle(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let parts = folded.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return folded
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

    /// A category. A board or a list is one source's, so it is never for every source; public
    /// and home are Mastodon's, so never for a source `sources` holds as something else; trends
    /// are also a Discuz!'s (`ProtocolKind.hasTrends`), and never a Discourse's.
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
        case (.public, .source(let host)), (.home, .source(let host)):
            if let source = sources.first(where: { $0.host == host }), !source.kind.hasTimelines { return nil }
        // A Discuz! has Trends — its ranking lists — without having the other two.
        case (.trends, .source(let host)):
            if let source = sources.first(where: { $0.host == host }), !source.kind.hasTrends { return nil }
        default:
            break
        }
        return Rule(id: id, effect: effect, kind: .category(category, in: scope))
    }

    /// A rule on a field one kind of source declares (#287): the field's name, and the value
    /// asked for. An option is folded to lower case, as a note's is.
    ///
    /// **Nothing for a value no rule can be asked of yet** — a number, a date, and a text for
    /// any field but one that holds a handle — so a stored
    /// rule of a type this build cannot compare is refused whole, never kept as one that matches
    /// nothing. **And nothing for a value its field cannot hold**, where this build declares the
    /// field (`SourceField.accepts`): a yes asked of how far a post was sent, an audience that is
    /// not one of the four, a language that is no language tag, a text that is no handle where
    /// the field holds one. Such a rule could never match —
    /// a hide written that way would hide nothing and say it was hiding — so it is not a rule.
    ///
    /// Whether any source *here* declares the field is not asked: a rule naming one that no
    /// source here declares stays and says so (`RuleStatus.missingField`), as one naming a source
    /// that has gone does; and a name no kind of source declares at all is the same, since a
    /// later build may.
    public static func field(
        _ name: String,
        is value: FieldValue,
        in scope: RuleScope,
        effect: RuleEffect = .include,
        id: UUID = UUID()
    ) -> Rule? {
        guard !name.isEmpty, value.isAsked, let scope = normalised(scope) else { return nil }
        if case .option(let option) = value, option.isEmpty { return nil }
        var folded = value.folded
        // **A text is asked only of a field that says how its text is compared**, and the one
        // that does holds a handle: kept as an author rule keeps one, however it was typed. A
        // text for any other name — one this build does not declare — has no comparison here,
        // and is refused as a number is.
        if case .text(let text) = value {
            guard SourceField.declared[name]?.holdsHandle == true, let handle = Self.handle(text) else { return nil }
            folded = .text(handle)
        }
        if let field = SourceField.declared[name], !field.accepts(folded) { return nil }
        return Rule(id: id, effect: effect, kind: .field(name: name, is: folded, in: scope))
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
    /// Empty or whitespace is none, so a kept timeline never invents a description.
    public var desc: String?

    public init(id: TimelineID = UUID(), name: String, rules: [Rule], desc: String? = nil) {
        self.id = id
        self.name = name
        self.rules = rules
        let trimmed = desc?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.desc = trimmed.isEmpty ? nil : trimmed
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
    /// No source the rule is for declares the field it names (#287): the kind of source that did
    /// has gone from this device.
    case missingField
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
        case field(String, FieldValue)
    }

    private struct Matcher: Sendable {
        let id: Rule.ID
        let host: String?
        let check: Check
    }

    public let definition: TimelineDefinition
    private let sources: [Source]
    private let excludes: [Matcher]
    /// One entry per kind — and per field (#287) — that has includes, in the order they are tried.
    private let groups: [[Matcher]]

    public init(_ definition: TimelineDefinition, sources: [Source]) {
        self.definition = definition
        self.sources = sources
        let matchers = definition.rules.map { rule in (rule, Self.matcher(rule)) }
        excludes = matchers.filter { $0.0.effect == .exclude }.map(\.1)
        let includes = matchers.filter { $0.0.effect == .include }
        groups = RuleKind.groups(of: includes.map(\.0)).map { group in
            includes.filter { $0.0.kind.group == group }.map(\.1)
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
        case .field(let name, let value, _): .field(name, value)
        }
        return Matcher(id: rule.id, host: host, check: check)
    }

    /// What this timeline's rules say of `note`.
    ///
    /// **A reblog is asked two ways** (#290). Where it came from, what it arrived through and
    /// who made it are its own: a rule on a source, a category or an author is asked of the
    /// reblog, and the author is whoever reblogged. What it says is the post it reblogs —
    /// `reblogged`, handed in by whoever holds the notes — so a rule on words, or on a field of
    /// the post (its language, its cover, whom it was for), is asked of that post: an include
    /// finds the reblog by the post's words, and what hides the post hides its reblog.
    /// **A reblog whose post is not held says nothing**: it matches no rule on words or fields.
    ///
    /// **A rule on an author is asked of who made the item, and of nobody else** — a hide
    /// exactly as an include. A person's rule is about what they made: the posts they wrote and
    /// the reblogs they made. Somebody else's reblog of their post is that somebody's item, and
    /// is shown or hidden by a rule on whose post a reblog reblogs (`SourceField.reblogOf`),
    /// which the person writes where they want it: hide the author and hide reblogs of them, and
    /// their words are drawn nowhere.
    ///
    /// **A field about the item is handed the post too**, since one of them is read off it.
    public func verdict(_ note: Note, _ index: TextIndex, reblogged: Note? = nil) -> Verdict {
        let said: Note? = note.isReblog ? reblogged.flatMap { $0.isReblog ? nil : $0 } : note
        var entry: TextIndex.Entry?
        var saidEntry: TextIndex.Entry?
        func folded(_ note: Note) -> TextIndex.Entry {
            let found = saidEntry ?? index.entry(for: note)
            saidEntry = found
            return found
        }
        func matches(_ matcher: Matcher) -> Bool {
            if let host = matcher.host, host != note.source.host { return false }
            switch matcher.check {
            case .host: return true
            case .category(let category): return note.categories.contains(category)
            // Nothing said is not a value: a post whose source declares no such field, or says
            // nothing for it, matches no rule on it.
            // Asked of what the field is about, as its declaration says (`SourceField.about`):
            // the item itself, or — for a fact about a post — what a reblog reblogs.
            case .field(let name, let value):
                if note.source.kind.field(named: name)?.about == .item {
                    return note.value(of: name, reblogged: note.isReblog ? said : nil) == value
                }
                return said?.value(of: name) == value
            case .handle(let handle):
                let found = entry ?? index.entry(for: note)
                entry = found
                return found.foldedHandle == handle
            case .keyword(let text):
                guard let post = said else { return false }
                return Fold.contains(folded(post).text, text)
            }
        }
        if let hit = excludes.first(where: matches) { return .hidden(by: hit.id) }
        for group in groups where !group.contains(where: matches) {
            return .hidden(by: group[0].id)
        }
        return .shown
    }

    /// Whether any rule here is asked of the post a reblog reblogs: a rule on words or on a
    /// field.
    private var readsWhatIsSaid: Bool {
        (excludes + groups.joined()).contains {
            switch $0.check {
            case .keyword, .field: true
            case .host, .handle, .category: false
            }
        }
    }

    /// The notes this timeline lets through, in the order given. `targets` is what each reblog
    /// held reblogs (`verdict`) — the one lookup built where the held notes were replaced; where
    /// none is handed in, it is looked up among `notes`, which must then be everything held.
    public func shown(_ notes: [Note], _ index: TextIndex, targets: ReblogTargets? = nil) -> [Note] {
        if excludes.isEmpty && groups.isEmpty { return notes }
        guard readsWhatIsSaid else { return notes.filter { verdict($0, index) == .shown } }
        let held = targets ?? ReblogTargets(notes)
        return notes.filter { verdict($0, index, reblogged: held.target(of: $0)) == .shown }
    }

    public func status(of rule: Rule) -> RuleStatus {
        guard case .source(let host) = rule.kind.scope else {
            // For every source: missing only where no source here declares the field it names.
            if case .field(let name, _, _) = rule.kind, !sources.contains(where: { $0.kind.field(named: name) != nil }) {
                return .missingField
            }
            return .present
        }
        guard let source = sources.first(where: { $0.host == host }) else { return .missingSource(host: host) }
        if case .field(let name, _, _) = rule.kind, source.kind.field(named: name) == nil { return .missingField }
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
        for key in RuleKind.groups(of: includes) {
            let group = includes.filter { $0.kind.group == key }
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
        // A rule on a field reaches only a source whose kind declares it (#287): no post of any
        // other can match, so asking one for this timeline would bring nothing it shows.
        if case .field(let name, _, _) = rule.kind { return source.kind.field(named: name) != nil }
        guard case .category(let category, _) = rule.kind else { return true }
        return source.kind.offers.serves(category)
    }
}
