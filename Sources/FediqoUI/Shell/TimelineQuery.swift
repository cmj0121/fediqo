import FediqoCore
import Foundation

/// A query the shell can tab between: All, Trends where a source has one, and a timeline the
/// reader wrote.
///
/// **Every one is a `TimelineDefinition` evaluated by the same rules** (Decision 17): All is no
/// rules, Trends is one category rule. A forum's boards are not tabs; they are a property of the
/// source that decides what this device fetches next (`BoardPicker`), and what they fetch lands
/// under All like everything else.
///
/// A written timeline's name and rule line are its definition's, which the session holds; see
/// `ShellSession.name(of:)`.
public enum TimelineQuery: Hashable, Identifiable, Sendable {
    case all
    case trends
    case written(TimelineID)

    private static let writtenPrefix = "written:"

    public var id: String {
        switch self {
        case .all: "all"
        case .trends: "trends"
        case .written(let id): Self.writtenPrefix + id.uuidString
        }
    }

    /// The query an id names, and All for any id this build does not know — a board tab from
    /// before boards stopped being tabs, say. All is the one query every store has.
    public init(id: String) {
        switch id {
        case "all": self = .all
        case "trends": self = .trends
        default:
            if id.hasPrefix(Self.writtenPrefix),
               let uuid = UUID(uuidString: String(id.dropFirst(Self.writtenPrefix.count))) {
                self = .written(uuid)
            } else {
                self = .all
            }
        }
    }

    /// The rules this query is: a built-in's own, or the written timeline with this id. One
    /// that has since been deleted is All.
    public func definition(among written: [TimelineDefinition]) -> TimelineDefinition {
        switch self {
        case .all: .all
        case .trends: .trends
        case .written(let id): written.first { $0.id == id } ?? .all
        }
    }

    // A written timeline's own name and rule line are the session's to give (it holds the
    // definitions); these are the built-ins'.
    public var name: String {
        switch self {
        case .all, .written: L10n.t("timeline.tab.all")
        case .trends: L10n.t("timeline.tab.trends")
        }
    }

    public var rule: String {
        switch self {
        case .all, .written: L10n.t("timeline.rule.all")
        case .trends: L10n.t("timeline.rule.trends")
        }
    }

    public var emptyKey: String {
        switch self {
        case .all, .written: "timeline.empty"
        case .trends: "timeline.empty.trends"
        }
    }

    /// Newest first. `notes` is already store order; Trends is origin, not rank.
    ///
    /// `index` is the session's, built where its notes are set, so a written timeline's keyword
    /// and author rules do not fold every note on each redraw. All and Trends read no text.
    ///
    /// `latest` is the reader's latest date (#22), cut after the rules so every query stops at
    /// the same day. It has no default, so a list drawn without asking about it does not compile.
    public func items(
        from notes: [Note],
        among written: [TimelineDefinition] = [],
        index: TextIndex = TextIndex([]),
        latest: LatestDate?
    ) -> [DummyItem] {
        let shown = CompiledTimeline(definition(among: written), sources: []).shown(notes, index)
        return (latest?.shown(shown) ?? shown).map { DummyItem($0) }
    }
}
