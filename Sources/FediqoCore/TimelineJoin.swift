import Foundation

// A source added later joining the timelines the reader already wrote (#372).
//
// **A joined timeline is the one the reader would have written with the source from the
// start.** Rules are any within a kind and all across kinds (`Rules.swift`), so joining adds a
// rule to each group that has to let the source through, and to no other: a category rule added
// to a timeline that has none would hide every other source.

/// One division of source Y as a timeline would take it (D4).
public struct TimelineJoinDivision: Hashable, Sendable {
    public let category: Category
    /// Already on for Y (an include scoped to Y or `.every`, not stale): drawn ticked and locked, never applied.
    public let locked: Bool

    public init(category: Category, locked: Bool) {
        self.category = category
        self.locked = locked
    }
}

/// What one written timeline is offered for joining source Y (D2–D4); only made when something would be added.
public struct TimelineJoinOffer: Hashable, Sendable, Identifiable {
    public var id: TimelineID { timeline }
    public let timeline: TimelineID
    public let name: String
    /// Y's divisions as this timeline takes them, offered or locked; empty where it has no category group ("the whole source").
    public let divisions: [TimelineJoinDivision]
    /// Whether joining also adds `source(Y)`: a source include group that lacks Y.
    public let addsSource: Bool
    /// Whether joining with no new division still adds something: the whole source, or "join with what is already on".
    public let joinsAsIs: Bool

    public init(timeline: TimelineID, name: String, divisions: [TimelineJoinDivision], addsSource: Bool, joinsAsIs: Bool) {
        self.timeline = timeline
        self.name = name
        self.divisions = divisions
        self.addsSource = addsSource
        self.joinsAsIs = joinsAsIs
    }
}

public enum TimelineJoin {
    /// What each of `timelines` is offered for `host`, in order. Leaves out a timeline that excludes source(Y), one Y
    /// still could not reach once joined (`sourcesToAsk` on the joined definition), and one with nothing to add (D3).
    /// Divisions: `kind.offers.categories(of:signedIn:marks:directs:)` less `.trends`; refused by the factory or
    /// excluded for Y/`.every` → dropped (D4).
    public static func offers(
        for host: String, in timelines: [TimelineDefinition], sources: [Source],
        signedIn: Bool, marks: Bool, directs: Bool
    ) -> [TimelineJoinOffer] {
        let host = host.lowercased()
        guard let source = sources.first(where: { $0.host == host }) else { return [] }
        let categories = source.kind.offers.categories(of: source, signedIn: signedIn, marks: marks, directs: directs)
            .filter { $0 != .trends }
        return timelines.compactMap { offer(of: $0, for: host, categories: categories, sources: sources) }
    }

    /// `timelines` with each choice applied (`TimelineDefinition.joining`), and the ids that changed.
    public static func apply(
        _ choices: [TimelineID: Set<Category>], of host: String,
        to timelines: [TimelineDefinition], sources: [Source]
    ) -> (timelines: [TimelineDefinition], changed: [TimelineID]) {
        var changed: [TimelineID] = []
        let joined = timelines.map { timeline -> TimelineDefinition in
            guard let picked = choices[timeline.id] else { return timeline }
            let result = timeline.joining(host, categories: picked, sources: sources)
            if result != timeline { changed.append(timeline.id) }
            return result
        }
        return (joined, changed)
    }

    private static func offer(
        of timeline: TimelineDefinition, for host: String, categories: [Category], sources: [Source]
    ) -> TimelineJoinOffer? {
        func adds(_ picked: Set<Category>) -> Bool {
            timeline.joining(host, categories: picked, sources: sources) != timeline
        }
        // A stale list or board is never among `categories`, which are the lists and boards chosen now (D4).
        var divisions: [TimelineJoinDivision] = []
        if timeline.hasIncludes(.category) {
            for category in categories where !timeline.excludes(category, for: host) {
                if timeline.rules.contains(where: { $0.effect == .include && $0.isCategory(category, for: host) }) {
                    divisions.append(TimelineJoinDivision(category: category, locked: true))
                } else if Rule.category(category, in: .source(host: host), sources: sources) != nil, adds([category]) {
                    divisions.append(TimelineJoinDivision(category: category, locked: false))
                }
            }
        }
        let asIs = (!timeline.hasIncludes(.category) || divisions.contains(where: \.locked)) && adds([])
        guard asIs || divisions.contains(where: { !$0.locked }) else { return nil }
        return TimelineJoinOffer(
            timeline: timeline.id, name: timeline.name, divisions: divisions,
            addsSource: timeline.lacksSource(host), joinsAsIs: asIs
        )
    }
}

extension TimelineDefinition {
    /// This timeline with `host` joined for `categories` (D2), from its own rules: with a category group,
    /// `Rule.category(d, in: .source(host:), sources:)` per d not already on, plus `Rule.source(host)` where a source
    /// group lacks it; with only a source group, `Rule.source(host)` (categories ignored); empty set = as is / whole
    /// source. Factories only, never a duplicate rule, unchanged where nothing would be added or Y still could not
    /// reach it (`sourcesToAsk`).
    public func joining(_ host: String, categories: Set<Category>, sources: [Source]) -> TimelineDefinition {
        let host = host.lowercased()
        var joined = self
        if hasIncludes(.category) {
            let added = Self.ordered(categories, of: sources.first { $0.host == host }).compactMap { category -> Rule? in
                let held = rules.contains { $0.effect == .include && $0.isCategory(category, for: host) }
                guard !held, !excludes(category, for: host) else { return nil }
                return Rule.category(category, in: .source(host: host), sources: sources)
            }
            joined.insert(added, after: .category)
        }
        if lacksSource(host), let source = Rule.source(host) {
            joined.insert([source], after: .source)
        }
        // Rules Y still cannot pass — an exclude of Y, a group scoped elsewhere, categories that let none of Y's
        // in — would add nothing but words, so the timeline stays as it was (D3): a fresh copy may not be what
        // `offers` saw.
        guard joined != self, CompiledTimeline(joined, sources: sources).sourcesToAsk().contains(where: { $0.host == host })
        else { return self }
        return joined
    }

    func hasIncludes(_ tag: RuleKind.Tag) -> Bool {
        rules.contains { $0.effect == .include && $0.kind.tag == tag }
    }

    /// A source include group that does not hold `host`.
    func lacksSource(_ host: String) -> Bool {
        hasIncludes(.source) && !rules.contains { $0.effect == .include && $0.kind == .source(host: host) }
    }

    func excludes(_ category: Category, for host: String) -> Bool {
        rules.contains { $0.effect == .exclude && $0.isCategory(category, for: host) }
    }

    /// `rules` placed after the last include of `tag`, or at the end where there is none.
    private mutating func insert(_ added: [Rule], after tag: RuleKind.Tag) {
        guard !added.isEmpty else { return }
        let at = rules.lastIndex { $0.effect == .include && $0.kind.tag == tag }.map { $0 + 1 } ?? rules.endIndex
        rules.insert(contentsOf: added, at: at)
    }

    /// `categories` in the order the source offers them, so a join adds its rules the same way every time.
    private static func ordered(_ categories: Set<Category>, of source: Source?) -> [Category] {
        let offered = source.map { $0.kind.offers.categories(of: $0, signedIn: true, marks: true, directs: true) } ?? []
        let known = offered.filter(categories.contains)
        let rest = categories.subtracting(known).sorted { String(describing: $0) < String(describing: $1) }
        return known + rest
    }
}

extension Rule {
    /// Whether this rule names `category` for `host`: scoped to it, or to every source.
    fileprivate func isCategory(_ category: Category, for host: String) -> Bool {
        kind == .category(category, in: .source(host: host)) || kind == .category(category, in: .every)
    }
}
