import FediqoCore

/// A query the shell can tab between: All, and Trends where a source has one.
///
/// **Those two are the only queries of the store.** A forum's boards are not tabs; they are a
/// property of the source that decides what this device fetches next (`BoardPicker`), and what
/// they fetch lands under All like everything else.
public enum TimelineQuery: String, CaseIterable, Identifiable, Sendable {
    case all
    case trends

    public var id: String { rawValue }

    /// The query an id names, and All for any id this build does not know — a board tab from
    /// before boards stopped being tabs, say. All is the one query every store has.
    public init(id: String) {
        self = Self(rawValue: id) ?? .all
    }

    public var name: String {
        switch self {
        case .all: L10n.t("timeline.tab.all")
        case .trends: L10n.t("timeline.tab.trends")
        }
    }

    public var rule: String {
        switch self {
        case .all: L10n.t("timeline.rule.all")
        case .trends: L10n.t("timeline.rule.trends")
        }
    }

    public var emptyKey: String {
        switch self {
        case .all: "timeline.empty"
        case .trends: "timeline.empty.trends"
        }
    }

    /// Newest first. `notes` is already store order; Trends is origin, not rank.
    public func items(from notes: [Note]) -> [DummyItem] {
        switch self {
        case .all: notes.map { DummyItem($0) }
        case .trends: notes.filter { $0.categories.contains(.trends) }.map { DummyItem($0) }
        }
    }
}
