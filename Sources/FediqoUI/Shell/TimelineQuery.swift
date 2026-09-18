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
/// Written timelines have no tab and no store yet (#27); `written` is here so an id that names
/// one already has somewhere to go.
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

    // A written timeline's name and rule line come from its definition, which #27 draws; until
    // then nothing offers one as a tab, so these answer as All does.
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
    /// Evaluated against no text index: All and Trends read no text, and the session that draws
    /// written timelines (#27) is the one that will hold an index to hand in.
    public func items(from notes: [Note], among written: [TimelineDefinition] = []) -> [DummyItem] {
        CompiledTimeline(definition(among: written), sources: [])
            .shown(notes, TextIndex([]))
            .map { DummyItem($0) }
    }
}
