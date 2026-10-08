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

    /// The source and what was asked of it: the same thing failing again replaces its line.
    let id: String
    /// The folded host.
    let host: String
    let what: What
    let why: WriteWhy

    init(_ what: What, _ why: WriteWhy, host: String) {
        self.host = host.lowercased()
        self.what = what
        self.why = why
        id = Self.id(what, host: host)
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
            let key: String
            switch why {
            case .locked: key = "notices.source.locked"
            case .refused: key = "said.act.\(act).refused"
            case .unreachable: key = "said.act.\(act).failed"
            case .declined: key = "said.act.\(act).declined"
            case .unconfirmed: key = "said.act.\(act).unconfirmed"
            }
            return String(format: L10n.t(key, language: language), host)
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

    /// Takes one line down: its `×`, or the same act having since succeeded (`Said.id`).
    func takeDown(_ id: String) {
        lines.removeAll { $0.id == id }
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
