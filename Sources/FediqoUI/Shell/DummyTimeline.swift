/// A named query the shell can tab between. All and Trends are created on join.
public struct DummyTimeline: Identifiable, Hashable, Sendable {
    public let id: String

    public var name: String { L10n.t("timeline.tab.\(id)") }

    /// Empty until a source is joined. The dummy stream is not the live set.
    public static let shipped: [DummyTimeline] = []

    public var sources: [DummySource] { [] }

    public var rule: String {
        switch id {
        case "trends": L10n.t("timeline.rule.trends")
        default: L10n.t("timeline.rule.all")
        }
    }

    /// Newest first. Empty until the store is wired; dummy stored items do not feed this.
    public var items: [DummyItem] { [] }
}
