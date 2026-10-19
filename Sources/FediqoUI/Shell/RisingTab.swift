import Foundation

/// The kinds of thing rising (F10), in the order they stand on Trends: the hashtags rising on
/// the sources, and the links — each a tab of Trends (`TrendsTab`).
///
/// **Which of them Trends has is decided where the sources are asked** (`ShellRising.tabs`):
/// one for each kind of thing some source has a ranking of — a source that says who people
/// are, and has not answered this run that it has no such thing. Absent, never grey.
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
}
