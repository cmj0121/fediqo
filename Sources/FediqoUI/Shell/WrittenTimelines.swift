import FediqoCore
import Foundation

/// The timelines the reader wrote, kept on this device in their order (#27).
///
/// **Not in the index.** A timeline is the reader's setting, like the language or the keep
/// window, and the GRDB index holds what servers sent; keeping it out adds no migration to the
/// one 0.2.0 has (Decision 2). **And no longer in the preferences** (#344): a timeline names
/// the sources a person reads and the words they filter, so it is a file beside the index
/// (`file`), unreadable while the device is locked, moved there once from the key earlier
/// builds kept it under. Only a store handed no file — a test, a preview — keeps to the key.
///
/// **The shape is versioned** — this build writes `{"version":4,"timelines":[…],"gone":[…]}`
/// (each timeline's `stamp` and each removed one's tombstone, D3/D4) and still reads version 3
/// (a rule on a field one kind of source declares, #287: `field` and `type` on a rule), version
/// 2 (`desc` on a timeline) and version 1, which has neither. **A build from before a
/// version does not read it**: version 4 is outside what it reads, so it says the timelines
/// cannot be read and writes nothing over them, rather than open them with a rule dropped. Kind, effect and category strings stay
/// what a later build reads. **Any later shape change bumps `version`.** The load **fails closed**
/// (Decision 15): a missing or other version, a field or a kind this build does not know, is
/// reported as unreadable and never written over, because dropping one rule would widen a
/// timeline or bring back what the reader hid.
///
/// **Save for a rule on what is trending**, which a timeline no longer holds: Trends is a page of
/// its own. Read, it is let go without a word, and the timeline loads without it — a timeline
/// whose one rule it was loads with none. The next save writes the rest in this build's shape.
struct WrittenTimelineStore {
    enum Loaded: Equatable {
        case timelines([TimelineDefinition])
        case unreadable
    }

    /// When each timeline was last written, and the tombstone of each removed (D3, D4).
    struct Stamps: Equatable {
        var timelines: [UUID: SyncStamp]
        var gone: [UUID: SyncStamp]
    }

    /// Version 4 (D3, D4): each timeline carries `stamp`, and `gone` holds each removed one's
    /// id and stamp. Versions 1–3 read with every stamp `.zero` and nothing gone.
    static let version = 4

    /// Posted after every save and every settle that wrote to a file (`userInfo["place"]`:
    /// `place`; `userInfo["poster"]`: the poster's `ObjectIdentifier`, absent from a merge;
    /// `userInfo["timelines"]`: the `[TimelineDefinition]` written, as a load reads them): every
    /// other window that keeps its timelines in the same file takes them up.
    static let kept = Notification.Name("fediqo.timelines.kept")

    let defaults: UserDefaults
    var key = "fediqo.timelines"
    /// The file beside the index the timelines are kept in, where the app handed one in.
    var file: ListFile?

    /// The file the timelines are kept in, as a path: what a `kept` notice names, so a window
    /// reads again only what was written where its own are. Nothing for a store handed no file
    /// (a test, a preview), which no other window shares.
    var place: String? {
        file?.url.path
    }

    /// Nothing kept only where nothing is under the key: a value of another type there is
    /// something this build cannot read, not an absence. **Nor is a file that would not be
    /// read, or preferences that may only look empty behind a lock** (`ListFile.Read.unread`):
    /// unreadable, and so never written over.
    func load() -> Loaded {
        loadStamped().map { .timelines($0.timelines) } ?? .unreadable
    }

    /// The definitions with their stamps and tombstones, or nil where unreadable.
    func loadStamped() -> (timelines: [TimelineDefinition], stamps: Stamps)? {
        let value: Any?
        switch file?.read() {
        case .unread?, .notKnown?: return nil
        case .data(let kept)?: value = kept
        case .some(.none): value = nil
        case nil: value = defaults.object(forKey: key)
        }
        guard let value else { return ([], Stamps(timelines: [:], gone: [:])) }
        guard let data = value as? Data,
              Self.knowsEveryField(data),
              let kept = try? JSONDecoder().decode(Kept.self, from: data),
              (1...Self.version).contains(kept.version)
        else { return nil }
        var timelines: [TimelineDefinition] = []
        var stamps = Stamps(timelines: [:], gone: [:])
        for row in kept.timelines {
            guard let timeline = row.definition else { return nil }
            timelines.append(timeline)
            guard let stamp = row.stamp else { continue }
            guard Self.holds(stamp) else { return nil }
            stamps.timelines[timeline.id] = stamp
        }
        for row in kept.gone ?? [] {
            guard Self.holds(row.stamp) else { return nil }
            stamps.gone[row.id] = row.stamp
        }
        for timeline in timelines { stamps.gone[timeline.id] = nil }
        return (timelines, stamps)
    }

    /// Refused while what is kept cannot be read: it is never written over, whoever asks.
    /// Says whether it was written down.
    ///
    /// **Stamps what changed** (D3, D4), against what the file holds now: a timeline new or not
    /// equal to the one kept takes `clock.now()`, one kept and no longer here becomes a
    /// tombstone at `clock.now()`, an unchanged one keeps its stamp, and one back from a
    /// tombstone drops it. The clock is told every stamp read first, so each new one is later.
    /// Posts `kept` with `poster` once written.
    @discardableResult
    func save(_ timelines: [TimelineDefinition], clock: SyncClock = .unpaired, poster: ObjectIdentifier? = nil) -> Bool {
        guard let held = loadStamped() else { return false }
        for stamp in Array(held.stamps.timelines.values) + Array(held.stamps.gone.values) { clock.witness(stamp) }
        let before = Dictionary(held.timelines.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var stamps = Stamps(timelines: [:], gone: held.stamps.gone)
        for timeline in timelines where stamps.timelines[timeline.id] == nil {
            stamps.timelines[timeline.id] = before[timeline.id] == timeline
                ? held.stamps.timelines[timeline.id] ?? .zero
                : clock.now()
            stamps.gone[timeline.id] = nil
        }
        for id in before.keys.sorted(by: { $0.uuidString < $1.uuidString }) where stamps.timelines[id] == nil {
            stamps.gone[id] = clock.now()
        }
        return write(timelines, stamps, poster: poster)
    }

    /// Every timeline and tombstone as merge entries, or nil while unreadable.
    func syncEntries() -> [UUID: Stamped<SyncTimeline>]? {
        loadStamped().map(Self.entries)
    }

    /// A merge's timeline entries laid in, each **only where it still wins over what the file
    /// holds for that id** (`SyncMerge.wins`): a new one goes at the end (order is not synced),
    /// a replaced one keeps its place, a removed one goes, a tombstone is kept. Written once and
    /// **no stamp made**; posts `kept` with no poster where anything was written. Nil where the
    /// file is unreadable, a body does not read, or the write fails (nothing written); true
    /// otherwise.
    ///
    /// `held` is what `loadStamped()` just read, where the caller read it already.
    func settle(
        arrived: [UUID: Stamped<SyncTimeline>], held: (timelines: [TimelineDefinition], stamps: Stamps)? = nil
    ) -> Bool? {
        guard let held = held ?? loadStamped() else { return nil }
        let entries = Self.entries(held)
        var timelines = held.timelines
        var stamps = held.stamps
        var moved = false
        for (id, entry) in arrived.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if let mine = entries[id], !SyncMerge.wins(entry, over: mine) { continue }
            moved = true
            if let value = entry.value {
                guard let timeline = Self.definition(from: value.body), timeline.id == id else { return nil }
                if let index = timelines.firstIndex(where: { $0.id == id }) {
                    timelines[index] = timeline
                } else {
                    timelines.append(timeline)
                }
                stamps.timelines[id] = entry.stamp
                stamps.gone[id] = nil
            } else {
                timelines.removeAll { $0.id == id }
                stamps.timelines[id] = nil
                stamps.gone[id] = entry.stamp
            }
        }
        guard moved else { return true }
        return write(timelines, stamps, poster: nil) ? true : nil
    }

    /// The row JSON of one timeline, keys sorted and no stamp: `SyncTimeline.body`. `encoder`
    /// is `bodyEncoder()`'s, made once for many.
    static func body(of timeline: TimelineDefinition, encoder: JSONEncoder = bodyEncoder()) -> Data {
        (try? encoder.encode(TimelineRow(timeline, stamp: nil))) ?? Data()
    }

    /// What writes a body: keys sorted.
    static func bodyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    /// The timeline a body holds, held to every rule `load` holds a row to; nil where it does
    /// not read.
    static func definition(from body: Data) -> TimelineDefinition? {
        guard let row = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              knowsEveryField(ofTimeline: row, stamped: false),
              let decoded = try? JSONDecoder().decode(TimelineRow.self, from: body)
        else { return nil }
        return decoded.definition
    }

    private static func entries(
        _ held: (timelines: [TimelineDefinition], stamps: Stamps)
    ) -> [UUID: Stamped<SyncTimeline>] {
        var entries = held.stamps.gone.mapValues { Stamped<SyncTimeline>(nil, at: $0) }
        let encoder = bodyEncoder()
        for timeline in held.timelines {
            entries[timeline.id] = Stamped(
                SyncTimeline(id: timeline.id, name: timeline.name, body: body(of: timeline, encoder: encoder)),
                at: held.stamps.timelines[timeline.id] ?? .zero
            )
        }
        return entries
    }

    /// Whether a stamp read is one the clock can carry on from (`SyncStamp.latestMs`).
    private static func holds(_ stamp: SyncStamp) -> Bool {
        (0...SyncStamp.latestMs).contains(stamp.ms)
    }

    private func write(_ timelines: [TimelineDefinition], _ stamps: Stamps, poster: ObjectIdentifier?) -> Bool {
        let kept = Kept(
            version: Self.version,
            timelines: timelines.map { TimelineRow($0, stamp: stamps.timelines[$0.id] ?? .zero) },
            gone: stamps.gone.sorted { $0.key.uuidString < $1.key.uuidString }.map { GoneRow(id: $0.key, stamp: $0.value) }
        )
        guard let data = try? JSONEncoder().encode(kept) else { return false }
        // At the act, whole and atomic: nothing of it waits for a save or for leaving.
        if let file {
            guard file.write(data) else { return false }
        } else {
            defaults.set(data, forKey: key)
        }
        if let place {
            var info: [String: Any] = ["place": place]
            if let poster { info["poster"] = poster }
            // As a load would read them back — each row held to the rules a read holds it to —
            // or not at all, and the other windows read the file.
            let read = kept.timelines.map(\.definition)
            if !read.contains(where: { $0 == nil }) { info["timelines"] = read.compactMap { $0 } }
            NotificationCenter.default.post(name: Self.kept, object: nil, userInfo: info)
        }
        return true
    }

    /// Whether every object holds only the fields its version writes. A field added by a later
    /// shape that forgot to bump `version` is still not read past. Version 4 holds a stamp on
    /// every timeline and a `gone` list; versions before it hold neither.
    private static func knowsEveryField(_ data: Data) -> Bool {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let timelines = top["timelines"] as? [[String: Any]]
        else { return false }
        let stamped = (top["version"] as? Int) == 4
        guard Set(top.keys) == (stamped ? ["version", "timelines", "gone"] : ["version", "timelines"]) else {
            return false
        }
        if stamped {
            guard let gone = top["gone"] as? [[String: Any]] else { return false }
            for row in gone {
                guard Set(row.keys) == ["id", "stamp"], knowsEveryField(ofStamp: row["stamp"]) else { return false }
            }
        }
        return timelines.allSatisfy { knowsEveryField(ofTimeline: $0, stamped: stamped) }
    }

    private static func knowsEveryField(ofTimeline timeline: [String: Any], stamped: Bool) -> Bool {
        guard Set(timeline.keys).isSubset(of: ["id", "name", "rules", "desc"] + (stamped ? ["stamp"] : [])),
              !stamped || knowsEveryField(ofStamp: timeline["stamp"]),
              let rules = timeline["rules"] as? [[String: Any]]
        else { return false }
        for rule in rules {
            guard Set(rule.keys).isSubset(of: ["id", "effect", "kind", "value", "category", "host", "field", "type"])
            else {
                return false
            }
            if let category = rule["category"] {
                guard let fields = category as? [String: Any],
                      Set(fields.keys).isSubset(of: ["kind", "id"])
                else { return false }
            }
        }
        return true
    }

    private static func knowsEveryField(ofStamp stamp: Any?) -> Bool {
        guard let fields = stamp as? [String: Any] else { return false }
        return Set(fields.keys) == ["ms", "n", "by"]
    }
}

private struct Kept: Codable {
    var version: Int
    var timelines: [TimelineRow]
    /// Version 4 on: each timeline removed, and when (D4).
    var gone: [GoneRow]?
}

private struct GoneRow: Codable {
    var id: UUID
    var stamp: SyncStamp
}

private struct TimelineRow: Codable {
    var id: UUID
    var name: String
    var rules: [RuleRow]
    var desc: String?
    /// When it was last written (version 4 on); nothing in a body (`WrittenTimelineStore.body`).
    var stamp: SyncStamp?

    init(_ timeline: TimelineDefinition, stamp: SyncStamp?) {
        id = timeline.id
        name = timeline.name
        rules = timeline.rules.map(RuleRow.init)
        desc = timeline.desc
        self.stamp = stamp
    }

    /// Nothing where any one rule cannot be read. A rule on what is trending is read and let go.
    var definition: TimelineDefinition? {
        var read: [Rule] = []
        for row in rules {
            guard let rule = row.rule else { return nil }
            if case .category(.trends, _) = rule.kind { continue }
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
    /// The name of the field a field rule is on (#287), and the type of its value — `option`,
    /// `flag`, `text`, `number` or `date` — whose own spelling is in `value`. All five types have
    /// a spelling so the shape does not change when a rule can ask the last three.
    var field: String?
    var type: String?

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
        case .field(let name, let asked, let scope):
            kind = "field"
            field = name
            (type, value) = Self.spelled(asked)
            host = Self.host(of: scope)
        }
    }

    /// A field's value as it is kept: its type's name, and the value in that type's spelling.
    private static func spelled(_ value: FieldValue) -> (type: String, value: String) {
        switch value {
        case .option(let option): ("option", option)
        case .flag(let yes): ("flag", yes ? "yes" : "no")
        case .text(let text): ("text", text)
        case .number(let number): ("number", String(number))
        case .date(let date): ("date", ISO8601DateFormatter().string(from: date))
        }
    }

    /// The value a kept type and spelling name, or nothing where either is not one this build
    /// writes.
    private static func value(type: String, spelled: String) -> FieldValue? {
        switch (type, spelled) {
        case ("option", _): .option(spelled)
        case ("flag", "yes"): .flag(true)
        case ("flag", "no"): .flag(false)
        case ("text", _): .text(spelled)
        case ("number", _): Double(spelled).map(FieldValue.number)
        case ("date", _): ISO8601DateFormatter().date(from: spelled).map(FieldValue.date)
        default: nil
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
        // Through the factory, which refuses a value no rule can be asked of yet, and a value
        // its field cannot hold — a language that is no language tag, an audience that is not
        // one — so neither is read here as a rule that matches nothing. **Refused, the whole
        // load fails closed**, this file's standing rule and for its reason: a hide dropped would
        // bring back what the reader hid, and a hide kept that can never match already has.
        case ("field", let spelled?, _):
            guard let field, let type, let asked = Self.value(type: type, spelled: spelled) else { return nil }
            return Rule.field(field, is: asked, in: scope, effect: effect, id: id)
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
        case .bookmarks: kind = "bookmarks"
        case .favourites: kind = "favourites"
        case .conversations: kind = "conversations"
        }
    }

    var category: FediqoCore.Category? {
        switch (kind, id) {
        case ("public", _): .public
        case ("trends", _): .trends
        case ("home", _): .home
        case ("list", let id?): .list(id: id)
        case ("board", let id?): .board(id: id)
        case ("bookmarks", _): .bookmarks
        case ("favourites", _): .favourites
        case ("conversations", _): .conversations
        default: nil
        }
    }
}
