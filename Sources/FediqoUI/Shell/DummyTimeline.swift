import FediqoCore

/// A named query the shell can tab between. All and Trends are created on join.
public struct DummyTimeline: Identifiable, Hashable, Sendable {
    public let id: String

    public var name: String { L10n.t("timeline.tab.\(id)") }

    /// Empty until a source is joined. The dummy stream is not the live set.
    public static let shipped: [DummyTimeline] = []

    public var rule: String {
        switch id {
        case "trends": L10n.t("timeline.rule.trends")
        default: L10n.t("timeline.rule.all")
        }
    }

    public var emptyKey: String {
        id == "trends" ? "timeline.empty.trends" : "timeline.empty"
    }

    /// Newest first. `notes` is already store order; Trends is origin, not rank.
    public func items(from notes: [Note]) -> [DummyItem] {
        switch id {
        case "trends":
            notes.filter { $0.origins.contains(.trending) }.map(DummyItem.init)
        case "all":
            notes.map(DummyItem.init)
        default:
            []
        }
    }
}
