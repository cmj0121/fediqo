import Foundation

/// The tabs of Trends (decision 2), in the order they stand: the posts trending on the sources,
/// the hashtags rising on them, and the links.
///
/// **Posts is the old Trends timeline, moved and not changed** (decision 3): the stream of the
/// `.trends` query, held by the store and read on as any timeline is. Hashtags and Links are what
/// the rising page was (F10), asked of the sources as that page asked them (`ShellRising`).
///
/// **A tab no source has is absent, never grey**, as on every page with tabs: the rule is
/// `RisingWhich.tabs(having:)`'s. Where one is left, the page is that one list, with no strip;
/// where none is, there is no Trends at all (`ShellAvailability.railPlaces`).
///
/// **Which is in front is the root's, for the run** (decision 20): it starts on Posts and is not
/// written down, as `ShellSession.timelineID` is not.
enum TrendsTab: String, ShellTab, CaseIterable, Sendable {
    case posts, tags, links

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .posts: "trends.tab.posts"
        case .tags, .links: rising.map(\.titleKey) ?? ""
        }
    }

    var symbol: String {
        switch self {
        case .posts: "text.bubble"
        case .tags, .links: rising.map(\.symbol) ?? ""
        }
    }

    /// The kind of thing rising this tab lists, or nothing for Posts, which is a stream.
    var rising: RisingWhich? {
        switch self {
        case .posts: nil
        case .tags: .tags
        case .links: .links
        }
    }

    init(_ which: RisingWhich) {
        switch which {
        case .tags: self = .tags
        case .links: self = .links
        }
    }

    /// The tabs of Trends in `session`: Posts where a source has a trending timeline — the
    /// rule the timeline's Trends tab was offered by (`ProtocolKind.hasTrends`) — then each kind
    /// of thing some source ranks (`ShellRising.tabs(in:)`). **The one place it is decided.**
    @MainActor
    static func tabs(in session: ShellSession) -> [TrendsTab] {
        let posts = session.sources.contains { ShellSession.hasTrends($0.kind) }
        let rising = session.personPages?.rising.tabs(in: session) ?? []
        return tabs(posts: posts, rising: rising)
    }

    /// The same, of what the sources were found to have.
    static func tabs(posts: Bool, rising: [RisingWhich]) -> [TrendsTab] {
        allCases.filter { tab in tab.rising.map(rising.contains) ?? posts }
    }

    /// The tab drawn in front with `kept` the one the reader left in front, among the `tabs`
    /// Trends has: that one where it still has it, and the first left where no source has it
    /// any more — nothing where there is no tab at all.
    static func front(_ kept: TrendsTab, among tabs: [TrendsTab]) -> TrendsTab? {
        tabs.contains(kept) ? kept : tabs.first
    }

    /// What Tab or ⇧Tab does on Trends, as every page with tabs decides it.
    static func keyed(_ tabs: [TrendsTab], front: TrendsTab, by step: Int, covered: Bool) -> PageKeyed<TrendsTab> {
        PageFrame.keyed(tabs, front: front, by: step, covered: covered)
    }

    /// `to` brought in front of Trends, among the `tabs` it has: the lamp of the tab left kept
    /// in `lamps`, and the one `to` was left with handed back where it is still on one of
    /// `rows`, the rows `to` walks — or no lamp, on a tab not in front before or a row it no
    /// longer has. Whether anything changed: a tab Trends has not, and the tab already in
    /// front, change nothing.
    static func turned(
        _ front: inout TrendsTab, to: TrendsTab, among tabs: [TrendsTab], rows: [String],
        lamps: inout [TrendsTab: String], lamp: inout String?
    ) -> Bool {
        guard tabs.contains(to), to != front else { return false }
        lamps[front] = lamp
        front = to
        lamp = PageFrame.lamp(lamps[to], among: rows)
        return true
    }
}

/// Which tab of Trends is in front, and where the lamp stood on each tab when it was left: the
/// root's, for the run (decision 20).
struct TrendsFront: Hashable, Sendable {
    var tab: TrendsTab = .posts
    var lamps: [TrendsTab: String] = [:]

    /// The tab in front gone from the `tabs` Trends has — no source has it any more: the one
    /// left (`TrendsTab.front`) brought in front as a turn would bring it, the gone tab's lamp
    /// kept and the lamp handed the one it was left with where it is still on `rows` of it —
    /// or kept as it was, where those rows are not to be had (`rows` nil). Whether it fell.
    mutating func fell(among tabs: [TrendsTab], lamp: inout String?, rows: (TrendsTab) -> [String]?) -> Bool {
        guard let left = TrendsTab.front(tab, among: tabs), left != tab else { return false }
        lamps[tab] = lamp
        tab = left
        lamp = rows(left).map { PageFrame.lamp(lamps[left], among: $0) } ?? lamps[left]
        return true
    }
}

/// What the Trends page hands the pane over its head (DESIGN-trends, Pane): its tabs, the one
/// in front, and a tab pressed or swiped to.
struct TrendsHead {
    let tabs: [TrendsTab]
    let front: TrendsTab
    var onTurn: (TrendsTab) -> Void = { _ in }
}
