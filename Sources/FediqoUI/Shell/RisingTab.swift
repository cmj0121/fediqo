import Foundation

/// The tabs of what is rising (F10), in the order they stand: the hashtags rising on the
/// sources, and the links.
///
/// **A tab is the step's own value** (`ShellStep.rising`): which one is in front is the walk's,
/// turned in place (`ShellWalk.turned(to:)`), so leaving never passes through the other tab and
/// turning adds no step. **Which tabs the page has is decided where the sources are asked**
/// (`ShellRising.tabs`): one for each kind of thing some source has a ranking of — a source
/// that says who people are, and has not answered this run that it has no such thing. Where
/// only one is left, the page is that one list, with no strip: absent, never grey.
extension RisingWhich: ShellTab {
    var id: String { rawValue }

    var titleKey: String { "rising.tab.\(rawValue)" }

    var symbol: String {
        switch self {
        case .tags: "number"
        case .links: "link"
        }
    }

    /// The tabs of a page whose sources have a ranking of `has` each. **The one place it is
    /// decided.**
    static func tabs(having has: (RisingWhich) -> Bool) -> [RisingWhich] {
        allCases.filter(has)
    }

    /// What Tab or ⇧Tab does on the page, as every page with tabs decides it.
    static func keyed(_ tabs: [RisingWhich], front: RisingWhich, by step: Int, covered: Bool) -> PageKeyed<RisingWhich> {
        PageFrame.keyed(tabs, front: front, by: step, covered: covered)
    }

    /// The tab drawn in front with the walk standing on `step`'s tab, among the `tabs` the page
    /// has: that one where the page still has it, the one left where no source ranks it any
    /// more — the walk is then turned to it, as a hashtag's page falls back to its posts — and
    /// nothing where no tab is left, when the stream is drawn. **The one place it is decided.**
    static func front(_ step: RisingWhich, among tabs: [RisingWhich]) -> RisingWhich? {
        tabs.contains(step) ? step : tabs.first
    }

    /// The tab `to` brought in front on the page `walk` stands on, among the `tabs` it has:
    /// the step in front turned in place, the lamp of the tab left kept in `lamps` and the one
    /// `to` was left with handed back where it is still on one of `rows`, the rows `to` walks
    /// — or no lamp, on a tab not in front before or a row it no longer has. Whether anything
    /// changed: a tab the page has not, the tab already in front, and a walk that is not
    /// standing on what is rising change nothing.
    static func turned(
        _ walk: inout ShellWalk, to: RisingWhich, among tabs: [RisingWhich], rows: [String],
        lamps: inout [RisingWhich: String], lamp: inout String?
    ) -> Bool {
        guard let from = walk.openedRising, tabs.contains(to), walk.turned(to: .rising(to)) else { return false }
        lamps[from] = lamp
        lamp = PageFrame.lamp(lamps[to], among: rows)
        return true
    }
}
