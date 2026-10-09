import FediqoCore
import Observation
import SwiftUI

/// One thing the person asked of a source that changed nothing: which act, at which source,
/// and why. What `SaidStrip` draws a line for.
struct Said: Identifiable, Equatable, Sendable {
    enum What: Equatable, Sendable {
        /// An act on one post, by the row it was pressed on. Never an answer: a text that did
        /// not arrive is the outbox's own line (`ShellOutbox`), and has no words here.
        case act(PostAct, row: String)
        case notice(ShellNoticeActs.Act)
        /// A text nobody had confirmed, found posted at its source and let go (`ShellOutbox`):
        /// nothing to do about it, said once so that its line does not simply vanish.
        case found(UUID, answer: Bool)
        /// Something the person asked to be gone that could not be taken off this device's
        /// disk yet (`ShellSession.saveNow`): no source's, and nothing to press — it is tried
        /// again by itself.
        case unwritten(Unwritten)
    }

    /// What the person asked to be gone from this device, as its line names it.
    enum Unwritten: String, CaseIterable, Sendable {
        /// A notice, or every notice of a source, dismissed.
        case notice
        /// A post taken back.
        case post
        /// Posts let go: by dates, by what is marked gone, by the months kept.
        case posts
        /// A source removed, and what went with it.
        case source
        /// A source cleared.
        case cleared
        /// What a source said of somebody who has signed out of it.
        case reader
    }

    /// Whose post an act was on, as a line names it: a line read on another page, or beside
    /// four like it, has only this to say which post "it" is.
    enum Whose: Equatable, Sendable {
        /// The person's own.
        case yours
        /// Somebody's, by their name — their handle where they have none.
        case by(String)
    }

    /// What an act on notices that changed nothing was about, where its line stands for one
    /// thing: the notice, or the person whose held-back notices they are. Kept as it is and
    /// worded at the draw, in the language of the draw.
    enum About: Equatable, Sendable {
        case notice(Notice)
        case person(NoticePerson)
    }

    /// The source and what was asked of it: the same thing failing again replaces its line.
    let id: String
    /// The folded host.
    let host: String
    let what: What
    let why: WriteWhy
    /// Whose post it was, for an act on one; nothing for a notice, or where nobody said.
    let whose: Whose?
    /// How many things this line stands for: one, or — for a line `ShellSaid.folded` made —
    /// every line about one act at one source, or — for an act on notices — every notice or
    /// request of that source the act did not take (`ShellNoticeActs.missed`).
    let many: Int
    /// Which notice, or whose, an act on notices was about; nothing where the line stands
    /// for several, or for all a source has.
    let about: About?

    init(
        _ what: What, _ why: WriteWhy, host: String, of whose: Whose? = nil, about: About? = nil, many: Int = 1
    ) {
        self.host = host.lowercased()
        self.what = what
        self.why = why
        self.whose = whose
        self.about = about
        self.many = many
        id = Self.id(what, host: host)
    }

    /// The one line that stands for `many` about `act` at `host` (`ShellSaid.folded`), under
    /// the name they are all taken down by.
    fileprivate init(folding act: PostAct, host: String, many: Int, newest: Said) {
        self.host = host
        what = newest.what
        why = newest.why
        whose = nil
        about = nil
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

    /// Whether this is a line about this device's own file, and no source's.
    var isUnwritten: Bool {
        if case .unwritten = what { return true }
        return false
    }

    /// The name a line about `what` at `host` stands under, for the act that later succeeds
    /// to take it down by (`ShellSaid.takeDown`).
    static func id(_ what: What, host: String) -> String {
        let host = host.lowercased()
        switch what {
        case .act(let act, let row): return "\(host)\u{1e}act\u{1e}\(act)\u{1e}\(row)"
        case .notice(let act): return "\(host)\u{1e}notice\u{1e}\(act)"
        case .found(let text, _): return "\(host)\u{1e}found\u{1e}\(text.uuidString)"
        case .unwritten(let gone): return "\u{1e}unwritten\u{1e}\(gone.rawValue)"
        }
    }

    /// The line, in one sentence. A notice's is the sentence the notices page says of it
    /// (`NoticeActs.words`), so the two cannot differ.
    @MainActor
    func words(language: DummyLanguage? = nil) -> String {
        switch what {
        case .found(_, let answer):
            return String(format: L10n.t(answer ? "outbox.found.answer" : "outbox.found.post", language: language), host)
        case .unwritten(let gone):
            return L10n.t("said.unwritten.\(gone.rawValue)", language: language)
        case .notice(let act):
            return NoticeActs.words(
                ShellNoticeActs.Said(act: act, why: why), host: host, about: about, many: many, language: language
            )
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
            // Whose post, where it is known.
            guard let whose else { return String(format: L10n.t(key, language: language), host) }
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

    /// Puts a line in the place of the one standing under its name, where one stands: the
    /// same act at the same source, now about fewer things. **Not said aloud and not moved
    /// to the front** — nothing new happened; what the line counts did.
    func amend(_ said: Said) {
        guard let at = lines.firstIndex(where: { $0.id == said.id }) else { return }
        lines[at] = said
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

    /// A write to this device landed: whatever was said not to be off it yet now is.
    func written() {
        guard lines.contains(where: { $0.isUnwritten }) else { return }
        lines.removeAll { $0.isUnwritten }
    }

    func clear() {
        lines = []
    }
}

extension ShellSession {
    /// Whether one of the root's presenters this session drives is up — the answer, a text
    /// that waits to be sent, the sign-in, the timeline editor, or a question about taking
    /// back, discarding, bookmarks, notices, signing out or a sign-in a source ended. What a page reads before it raises anything
    /// of its own (`SaidStrip.held`); the composer and the join are the root's own state, and
    /// it adds them.
    var raisesOverPages: Bool {
        answering != nil || signingIn != nil || editing != nil || withdrawing != nil || rowAsk != nil
            || editingUnsent != nil || discardingUnsent != nil || resendingUnsent != nil
            || bookmarkAsk != nil || noticeAsk != nil || signOutAsk != nil || !mastodon.ended.isEmpty
    }
}
