import FediqoCore
import Observation
import SwiftUI

/// One thing the person asked of a source that changed nothing: which act, at which source,
/// and why. What `SaidStrip` draws a line for.
struct Said: Identifiable, Equatable, Sendable {
    enum What: Equatable, Sendable {
        /// An act on one post, by the row it was pressed on.
        case act(PostAct, row: String)
        case notice(ShellNoticeActs.Act)
    }

    /// Whose post an act was on, as a line names it: a line read on another page, or beside
    /// four like it, has only this to say which post "it" is.
    enum Whose: Equatable, Sendable {
        /// The person's own.
        case yours
        /// Somebody's, by their name — their handle where they have none.
        case by(String)
    }

    /// The source and what was asked of it: the same thing failing again replaces its line.
    let id: String
    /// The folded host.
    let host: String
    let what: What
    let why: WriteWhy
    /// Whose post it was, for an act on one; nothing for a notice, or where nobody said.
    let whose: Whose?
    /// How many lines this one stands for: one, or — for a line `ShellSaid.folded` made —
    /// every line about one act at one source.
    let many: Int

    init(_ what: What, _ why: WriteWhy, host: String, of whose: Whose? = nil) {
        self.host = host.lowercased()
        self.what = what
        self.why = why
        self.whose = whose
        many = 1
        id = Self.id(what, host: host)
    }

    /// The one line that stands for `many` about `act` at `host` (`ShellSaid.folded`), under
    /// the name they are all taken down by.
    fileprivate init(folding act: PostAct, host: String, many: Int, newest: Said) {
        self.host = host
        what = newest.what
        why = newest.why
        whose = nil
        self.many = many
        id = Self.foldID(act, host: host)
    }

    /// The name every line about `act` at `host` folds under.
    static func foldID(_ act: PostAct, host: String) -> String {
        "\(host.lowercased())\u{1e}acts\u{1e}\(act)"
    }

    /// The name this line folds under with the others like it: an act's, never a notice's.
    var foldID: String? {
        guard case .act(let act, _) = what else { return nil }
        return Self.foldID(act, host: host)
    }

    /// The name a line about `what` at `host` stands under, for the act that later succeeds
    /// to take it down by (`ShellSaid.takeDown`).
    static func id(_ what: What, host: String) -> String {
        let host = host.lowercased()
        switch what {
        case .act(let act, let row): return "\(host)\u{1e}act\u{1e}\(act)\u{1e}\(row)"
        case .notice(let act): return "\(host)\u{1e}notice\u{1e}\(act)"
        }
    }

    /// The line, in one sentence. A notice's is the sentence the notices page says of it
    /// (`NoticeActs.words`), so the two cannot differ.
    @MainActor
    func words(language: DummyLanguage? = nil) -> String {
        switch what {
        case .notice(let act):
            return NoticeActs.words(ShellNoticeActs.Said(act: act, why: why), host: host, language: language)
        case .act(let act, _):
            if many > 1 {
                return String(format: L10n.t("said.act.\(act).many", language: language), host, many)
            }
            let key: String
            switch why {
            case .locked: return String(format: L10n.t("notices.source.locked", language: language), host)
            case .refused: key = "said.act.\(act).refused"
            case .unreachable: key = "said.act.\(act).failed"
            case .declined: key = "said.act.\(act).declined"
            case .unconfirmed: key = "said.act.\(act).unconfirmed"
            }
            // Whose post, where it is known and the act is one on a post that is drawn.
            guard let whose, act != .answer else { return String(format: L10n.t(key, language: language), host) }
            return String(format: L10n.t(key + ".of", language: language), host, Self.named(whose, language: language))
        }
    }

    /// A post as a line names it: "your post", or its author's — the name made fit to stand
    /// in a line of ours (`LineText.oneLine`).
    ///
    /// **As it stands inside a sentence**, so each language's phrase brings the space its own
    /// script sets before a name, and none before "your": the sentences put nothing there.
    @MainActor
    static func named(_ whose: Whose, language: DummyLanguage? = nil) -> String {
        switch whose {
        case .yours: L10n.t("said.post.yours", language: language)
        case .by(let name): String(format: L10n.t("said.post.by", language: language), LineText.oneLine(name))
        }
    }
}

/// What this run has to say of the writes that changed nothing, where no sheet and no row is
/// in front of the person to say it: the lines `SaidStrip` draws at the foot of every page.
///
/// **A line stays until it is answered.** Nothing here is timed: a line goes at its own `×`,
/// when the same act at the same source later succeeds (`takeDown`), when the same act fails
/// again (its line is replaced, and comes to the front), and with its source — a sign-out, a
/// Clear, a Remove, a server ending the sign-in (`forget`). `TimelineToast.stays`' rule: a miss
/// stays, because the reader has to act on it.
///
/// **And a burst cannot fill the page.** No more than `kept` are held — the oldest goes — and
/// a page draws three of them at most (`SaidStrip.shown`), the rest behind a count.
///
/// Held for the run only: a line is about a press, and a press is never written down.
@MainActor
@Observable
final class ShellSaid {
    /// The most lines held at once.
    static let kept = 20

    /// Newest first.
    private(set) var lines: [Said] = []

    /// More lines than this about one act at one source are drawn as one that says how many.
    static let unfolded = 3

    /// What a page draws of `lines`: each as it is, but where more than `unfolded` are about
    /// one act at one source — a burst of presses while it could not be reached — one line in
    /// the place of the newest, saying how many. Taken down, it takes them all (`takeDown`).
    var folded: [Said] {
        var counts: [String: Int] = [:]
        for line in lines { if let fold = line.foldID { counts[fold, default: 0] += 1 } }
        guard counts.values.contains(where: { $0 > Self.unfolded }) else { return lines }
        var done: Set<String> = []
        return lines.compactMap { line in
            guard case .act(let act, _) = line.what, let fold = line.foldID,
                  let many = counts[fold], many > Self.unfolded
            else { return line }
            guard done.insert(fold).inserted else { return nil }
            return Said(folding: act, host: line.host, many: many, newest: line)
        }
    }

    /// Says a new line aloud. A seam, so a test counts what was announced.
    @ObservationIgnored var announce: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

    /// Says one thing, in front of the others, and aloud once. The same act at the same
    /// source said before is replaced, not said twice.
    func say(_ said: Said) {
        lines.removeAll { $0.id == said.id }
        lines.insert(said, at: 0)
        if lines.count > Self.kept { lines.removeLast(lines.count - Self.kept) }
        announce(said.words())
    }

    /// Takes one line down: its `×`, or the same act having since succeeded (`Said.id`). A
    /// line that stands for several (`folded`) takes them all.
    func takeDown(_ id: String) {
        lines.removeAll { $0.id == id || $0.foldID == id }
    }

    /// Lets go of every line about one source, as it leaves.
    func forget(host raw: String) {
        let host = raw.lowercased()
        lines.removeAll { $0.host == host }
    }

    func clear() {
        lines = []
    }
}

extension ShellSession {
    /// Whether one of the root's presenters this session drives is up — the answer, the
    /// sign-in, the timeline editor, or a question about taking back, bookmarks, notices,
    /// signing out or a sign-in a source ended. What a page reads before it raises anything
    /// of its own (`SaidStrip.held`); the composer and the join are the root's own state, and
    /// it adds them.
    var raisesOverPages: Bool {
        answering != nil || signingIn != nil || editing != nil || withdrawing != nil || rowAsk != nil
            || bookmarkAsk != nil || noticeAsk != nil || signOutAsk != nil || !mastodon.ended.isEmpty
    }
}
