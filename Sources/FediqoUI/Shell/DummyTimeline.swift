import FediqoCore

/// A named query the shell can tab between: All, and Trends where a source has any.
///
/// **Those two are the only queries of the store.** A forum's boards are not tabs; they are a
/// property of the source that decides what this device fetches next (`BoardPicker`), and what
/// they fetch lands under All like everything else.
public struct DummyTimeline: Identifiable, Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public var name: String {
        L10n.t("timeline.tab.\(id)")
    }

    /// Empty until a source is joined. The dummy stream is not the live set.
    public static let shipped: [DummyTimeline] = []

    public var rule: String {
        switch id {
        case "trends": return L10n.t("timeline.rule.trends")
        default: return L10n.t("timeline.rule.all")
        }
    }

    public var emptyKey: String {
        id == "trends" ? "timeline.empty.trends" : "timeline.empty"
    }

    /// Newest first. `notes` is already store order; Trends is origin, not rank.
    ///
    /// `among` is `DummyItem.init`'s own argument, passed down, and like it is read by nothing
    /// since two sources became two rows (#10).
    public func items(from notes: [Note], among sources: [Source]) -> [DummyItem] {
        switch id {
        case "trends":
            return notes.filter { $0.origins.contains(.trending) }.map { DummyItem($0, among: sources) }
        case "all":
            return notes.map { DummyItem($0, among: sources) }
        default:
            return []
        }
    }
}
