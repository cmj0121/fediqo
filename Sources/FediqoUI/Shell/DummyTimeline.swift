/// A named query the dummy shell can tab between. Not a network's home page.
public struct DummyTimeline: Identifiable, Hashable, Sendable {
    public let id: String

    public var name: String { L10n.t("timeline.tab.\(id)") }

    public static let shipped: [DummyTimeline] = [
        DummyTimeline(id: "all"),
        DummyTimeline(id: "work"),
    ]
}
