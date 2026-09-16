import FediqoCore

/// One board of one forum, as the timeline asks for it.
///
/// **The host is half the identity.** `fid` is unique on the forum that issued it and nowhere
/// else — `install-d.example` and `install-a.example` both have a board 2 — so a query named by the
/// number alone would put two strangers' boards behind one tab the moment a reader joins their
/// second forum.
///
/// The name is carried because it is what the pill draws and what the notes are matched on, and
/// it is **not** the identity: a moderator renaming a board does not move it, which is the rule
/// `BoardSubscription` states one layer down.
public struct BoardQuery: Hashable, Sendable {
    public let host: String
    public let fid: Int
    public let name: String

    public init(host: String, fid: Int, name: String) {
        self.host = host.lowercased()
        self.fid = fid
        self.name = name
    }

    /// The query id this board is known by, everywhere a timeline is named by a string.
    public var id: String { "board:\(host):\(fid)" }
}

/// A named query the shell can tab between. All, Trends where a source has any, and one per
/// subscribed board — D27: a board is a query in the rail the way `all` and `trends` are for a
/// microblog, which is why D26's one-source-per-host shape is the cheap one.
public struct DummyTimeline: Identifiable, Hashable, Sendable {
    public let id: String
    /// The board this query reads, where it reads one. Nothing for `all` and `trends`.
    ///
    /// **Carried rather than parsed back out of `id`.** The id holds the host and the number
    /// because those are the identity; the name is not in it and could not be, because a name is
    /// a thing the forum changes. A `DummyTimeline` rebuilt from an id alone therefore knows it
    /// is *a* board and not *which* — so the shell resolves a query out of `ShellSession.queries`
    /// rather than reconstructing one. See `ShellSession.timeline(for:)`.
    public let board: BoardQuery?

    public init(id: String) {
        self.id = id
        self.board = nil
    }

    /// The query one subscribed board is. Its id comes from the board, so nothing anywhere has to
    /// remember how one is spelled.
    public init(board: BoardQuery) {
        self.id = board.id
        self.board = board
    }

    public var name: String {
        if let board { return board.name }
        return L10n.t("timeline.tab.\(id)")
    }

    /// Empty until a source is joined. The dummy stream is not the live set.
    public static let shipped: [DummyTimeline] = []

    public var rule: String {
        if let board {
            return String(format: L10n.t("timeline.rule.board"), board.name, board.host)
        }
        switch id {
        case "trends": return L10n.t("timeline.rule.trends")
        default: return L10n.t("timeline.rule.all")
        }
    }

    public var emptyKey: String {
        if board != nil { return "timeline.empty.board" }
        return id == "trends" ? "timeline.empty.trends" : "timeline.empty"
    }

    /// Newest first. `notes` is already store order; Trends is origin, not rank.
    ///
    /// **A board is matched by host and by the name the page called itself.** `Note.board` is the
    /// heading the board's own page carried, and the subscription is what the index called it —
    /// two reads of the same forum minutes apart, and on all twenty-two boards measured live
    /// across the four installs they are the same string. They are not guaranteed to be, and a
    /// board whose page renames itself between the index read and the thread read would draw an
    /// empty tab rather than the wrong threads. Of the two, empty is the one a reader can see is
    /// wrong; matching loosely would put another board's threads under this board's name. See
    /// `PLAN.md`, "Found, not fixed here" — a note carrying its `fid` is the real answer and it
    /// belongs in Core.
    public func items(from notes: [Note]) -> [DummyItem] {
        if let board {
            let id = String(board.fid)
            return notes
                .filter {
                    guard $0.source.host == board.host else { return false }
                    // **The number where the page gave one, the name only where it did not.** A
                    // board's heading and its name in the index are two hand-written strings and
                    // are free to differ; matching on the name alone turned any difference into a
                    // tab that drew nothing, with no error anywhere to say why. The fallback is
                    // for a cross-board listing, whose rows name a section but carry no id.
                    if let carried = $0.boardID { return carried == id }
                    return $0.board == board.name
                }
                .map(DummyItem.init)
        }
        switch id {
        case "trends":
            return notes.filter { $0.origins.contains(.trending) }.map(DummyItem.init)
        case "all":
            return notes.map(DummyItem.init)
        default:
            return []
        }
    }
}
