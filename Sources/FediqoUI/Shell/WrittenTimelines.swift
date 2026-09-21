import FediqoCore
import Foundation

/// The timelines the reader wrote, kept on this device in their order (#27).
///
/// **In the preferences, not the store.** A timeline is the reader's setting, like the language
/// or the keep window, and the GRDB index holds what servers sent; keeping it beside `DummyPrefs`
/// adds no migration to the one 0.2.0 has (Decision 2).
///
/// **The shape is versioned** — this build writes `{"version":2,"timelines":[…]}` (`desc` on a
/// timeline) and still reads version 1, which has none. Kind, effect and category strings stay
/// what a later build reads. **Any later shape change bumps `version`.** The load **fails closed**
/// (Decision 15): a missing or other version, a field or a kind this build does not know, is
/// reported as unreadable and never written over, because dropping one rule would widen a
/// timeline or bring back what the reader hid.
struct WrittenTimelineStore {
    enum Loaded: Equatable {
        case timelines([TimelineDefinition])
        case unreadable
    }

    static let version = 2

    let defaults: UserDefaults
    var key = "fediqo.timelines"

    /// Nothing kept only where nothing is under the key: a value of another type there is
    /// something this build cannot read, not an absence.
    func load() -> Loaded {
        guard let value = defaults.object(forKey: key) else { return .timelines([]) }
        guard let data = value as? Data,
              Self.knowsEveryField(data),
              let kept = try? JSONDecoder().decode(Kept.self, from: data),
              (1...Self.version).contains(kept.version)
        else { return .unreadable }
        var timelines: [TimelineDefinition] = []
        for row in kept.timelines {
            guard let timeline = row.definition else { return .unreadable }
            timelines.append(timeline)
        }
        return .timelines(timelines)
    }

    /// Refused while what is kept cannot be read: it is never written over, whoever asks.
    func save(_ timelines: [TimelineDefinition]) {
        guard load() != .unreadable else { return }
        let kept = Kept(version: Self.version, timelines: timelines.map(TimelineRow.init))
        guard let data = try? JSONEncoder().encode(kept) else { return }
        defaults.set(data, forKey: key)
    }

    /// Whether every object holds only the fields this version writes. A field added by a later
    /// shape that forgot to bump `version` is still not read past.
    private static func knowsEveryField(_ data: Data) -> Bool {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(top.keys).isSubset(of: ["version", "timelines"]),
              let timelines = top["timelines"] as? [[String: Any]]
        else { return false }
        for timeline in timelines {
            guard Set(timeline.keys).isSubset(of: ["id", "name", "rules", "desc"]),
                  let rules = timeline["rules"] as? [[String: Any]]
            else { return false }
            for rule in rules {
                guard Set(rule.keys).isSubset(of: ["id", "effect", "kind", "value", "category", "host"]) else {
                    return false
                }
                if let category = rule["category"] {
                    guard let fields = category as? [String: Any],
                          Set(fields.keys).isSubset(of: ["kind", "id"])
                    else { return false }
                }
            }
        }
        return true
    }
}

private struct Kept: Codable {
    var version: Int
    var timelines: [TimelineRow]
}

private struct TimelineRow: Codable {
    var id: UUID
    var name: String
    var rules: [RuleRow]
    var desc: String?

    init(_ timeline: TimelineDefinition) {
        id = timeline.id
        name = timeline.name
        rules = timeline.rules.map(RuleRow.init)
        desc = timeline.desc
    }

    /// Nothing where any one rule cannot be read.
    var definition: TimelineDefinition? {
        var read: [Rule] = []
        for row in rules {
            guard let rule = row.rule else { return nil }
            read.append(rule)
        }
        return TimelineDefinition(id: id, name: name, rules: read, desc: desc)
    }
}

/// One rule. `host` is the source of a source rule and the scope of every other, `nil` for every
/// source.
private struct RuleRow: Codable {
    var id: UUID
    var effect: String
    var kind: String
    var value: String?
    var category: CategoryValue?
    var host: String?

    init(_ rule: Rule) {
        id = rule.id
        effect = rule.effect.rawValue
        switch rule.kind {
        case .source(let source):
            kind = "source"
            host = source
        case .author(let handle, let scope):
            kind = "author"
            value = handle
            host = Self.host(of: scope)
        case .keyword(let text, let scope):
            kind = "keyword"
            value = text
            host = Self.host(of: scope)
        case .category(let category, let scope):
            kind = "category"
            self.category = CategoryValue(category)
            host = Self.host(of: scope)
        }
    }

    private static func host(of scope: RuleScope) -> String? {
        switch scope {
        case .every: nil
        case .source(let host): host
        }
    }

    /// Made again through the factories, so a stored rule is held to what a new one is. Nothing
    /// for a kind, effect or category this build does not know.
    var rule: Rule? {
        guard let effect = RuleEffect(rawValue: effect) else { return nil }
        let scope: RuleScope = host.map { .source(host: $0) } ?? .every
        switch (kind, value, category?.category) {
        case ("source", _, _):
            return host.flatMap { Rule.source($0, effect: effect, id: id) }
        case ("author", let handle?, _):
            return Rule.author(handle, in: scope, effect: effect, sources: [], id: id)
        case ("keyword", let text?, _):
            return Rule.keyword(text, in: scope, effect: effect, id: id)
        case ("category", _, let category?):
            return Rule.category(category, in: scope, effect: effect, sources: [], id: id)
        default:
            return nil
        }
    }
}

/// A category as the store's own `categories` column spells it, so one kind string means one
/// thing on this device wherever it is written.
private struct CategoryValue: Codable {
    var kind: String
    var id: String?

    init(_ category: FediqoCore.Category) {
        switch category {
        case .public: kind = "public"
        case .trends: kind = "trends"
        case .home: kind = "home"
        case .list(let list): kind = "list"; id = list
        case .board(let board): kind = "board"; id = board
        }
    }

    var category: FediqoCore.Category? {
        switch (kind, id) {
        case ("public", _): .public
        case ("trends", _): .trends
        case ("home", _): .home
        case ("list", let id?): .list(id: id)
        case ("board", let id?): .board(id: id)
        default: nil
        }
    }
}
