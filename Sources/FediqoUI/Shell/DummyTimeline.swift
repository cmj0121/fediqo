/// A named query the dummy shell can tab between. Not a network's home page.
public struct DummyTimeline: Identifiable, Hashable, Sendable {
    public let id: String

    public var name: String { L10n.t("timeline.tab.\(id)") }

    public static let shipped: [DummyTimeline] = [
        DummyTimeline(id: "all"),
        DummyTimeline(id: "work"),
    ]

    /// Sources this query reads. All is the mix; Work is a configured subset.
    public var sources: [DummySource] {
        switch id {
        case "work": [.signedIn, .forum]
        default: [.unsignedPublic, .signedIn, .forum, .board]
        }
    }

    public var rule: String {
        switch id {
        case "work": L10n.t("timeline.rule.work")
        default: L10n.t("timeline.rule.all")
        }
    }

    /// This query's items, newest first. Source set, then the rule.
    public var items: [DummyItem] {
        DummyItem.stored
            .filter { sources.contains($0.source) }
            .filter { id != "work" || $0.workRelated }
            .sorted { $0.postedAt > $1.postedAt }
    }
}
