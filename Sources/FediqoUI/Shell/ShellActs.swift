import FediqoCore
import Foundation
import Observation

// What is on its way to a source, and what did not arrive — #53's vocabulary, for the acts a
// reader performs on one post (#54).
//
// **Nothing here remembers that a press happened.** A landed act leaves no entry at all: what the
// row then draws is `Note.boosted`, which is the source's own answer, written into the store by
// the same call that performed the act. That is the difference the acceptance turns on — a record
// kept here would survive a relaunch and be this device asserting something the server never
// confirmed. So this object holds exactly the two states that are *not* the source's answer, and
// lets go of both the moment there is one.

/// One act on one post. The row is `NoteKey.rowID`, so one post held from two servers is two
/// presses — the rule #10 sets everywhere else in this app.
struct ShellActKey: Hashable, Sendable {
    let row: String
    let act: PostAct
}

/// Where one act has got to.
///
/// **Two cases and no third.** Done is the absence of an entry, because done is a fact about the
/// post that the store already holds; an `.done` case here would be a second copy of it, free to
/// disagree, and it would have to be expired by somebody. Cancelled is `.failed` too: what the
/// reader sees is an act that did not arrive and a press that will try again, which is true of
/// both and is the only sentence either deserves.
enum ShellActStanding: Equatable, Sendable {
    /// On the wire.
    case onItsWay
    /// It did not arrive. Pressing again asks once more.
    case failed
}

/// Every act this run has in the air, and every one that did not land.
///
/// On the session for the reason the picture caches and `ShellConversations` are: what a row
/// draws and what a key presses have to be the same object, and a second one reached for at a
/// call site is an agreement a preview or a test breaks in silence.
@MainActor
@Observable
final class ShellActs {
    private(set) var standings: [ShellActKey: ShellActStanding] = [:]

    func standing(of row: String, _ act: PostAct) -> ShellActStanding? {
        standings[ShellActKey(row: row, act: act)]
    }

    /// Whether this act on this row is on the wire. **The one guard a second press reads**, so a
    /// reader pressing twice does not put two of the same act on the wire and leave whichever
    /// answers last to decide what the post looks like.
    func isOnItsWay(_ row: String, _ act: PostAct) -> Bool {
        standing(of: row, act) == .onItsWay
    }

    /// Marks the act as on its way, and says whether it may start: `false` is one already out.
    func begin(_ row: String, _ act: PostAct) -> Bool {
        guard !isOnItsWay(row, act) else { return false }
        standings[ShellActKey(row: row, act: act)] = .onItsWay
        return true
    }

    /// It arrived. The entry goes, and what the row draws from here is the source's own answer.
    func landed(_ row: String, _ act: PostAct) {
        standings[ShellActKey(row: row, act: act)] = nil
    }

    func failed(_ row: String, _ act: PostAct) {
        standings[ShellActKey(row: row, act: act)] = .failed
    }

    /// Lets go of one server's acts — Remove, and Clear. Keyed by the row id, whose first half is
    /// the host: `NoteKey.rowID` joins them on the record separator, which no hostname contains.
    func forget(host raw: String) {
        let prefix = raw.lowercased() + "\u{1e}"
        standings = standings.filter { !$0.key.row.hasPrefix(prefix) }
    }

    func clear() {
        standings = [:]
    }
}
