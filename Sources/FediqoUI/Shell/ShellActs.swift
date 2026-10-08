import FediqoCore
import Foundation
import Observation

// What the reader pressed that its source has not answered yet, and what did not arrive — #53's
// vocabulary, for the acts a reader performs on one post (#54).
//
// **Nothing here remembers that a press happened.** A landed act leaves no entry at all: what the
// row then draws is `Note.boosted`, which is the source's own answer, written into the store by
// the same call that performed the act. That is the difference the acceptance turns on — a record
// kept here would survive a relaunch and be this device asserting something the server never
// confirmed. So this object holds exactly the two states that are *not* the source's answer — a
// press not yet answered, with which way it was pressed, and one that did not arrive — and lets
// go of both the moment there is one. Neither is written down.
//
// **A press is drawn over the store, never in it.** The row shows the press at once, read off
// the entry here before the store; the store moves only on the source's word, so a read landing
// meanwhile changes what lies under the press and nothing on screen, and a failure puts the mark
// back by dropping one entry.

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
    /// Pressed, and not yet answered: `to` is what the mark is drawn as meanwhile — done, or
    /// taken back. Taking a post back and answering are only ever pressed to `true`.
    case pressed(to: Bool)
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

    /// The rows whose taking back is pressed and not yet answered — every copy of each — which
    /// are left out of what is drawn until the source answers. Back the moment it fails.
    private(set) var leaving: Set<String> = []
    /// Which rows each taking back took out, so its answer puts back exactly those.
    @ObservationIgnored private var taken: [ShellActKey: Set<String>] = [:]

    func standing(of row: String, _ act: PostAct) -> ShellActStanding? {
        standings[ShellActKey(row: row, act: act)]
    }

    /// Whether this act on this row is pressed and not yet answered. **What a second press
    /// reads**, so pressing twice never puts two of the same act on the wire: a mark pressed
    /// again is turned (`turn`), and a taking back is not asked twice.
    func isOnItsWay(_ row: String, _ act: PostAct) -> Bool {
        if case .pressed = standing(of: row, act) { return true }
        return false
    }

    /// A press on a mark whose last press is still out: **the last press wins.** What is drawn
    /// turns at once, nothing is sent now, and whoever is waiting on the source reads what is
    /// wanted when its answer lands (`wanted`) — so any number of presses meanwhile come to
    /// the last, and one request at a time is on the wire for a mark. `false` where no press
    /// is out, and then the press is a first one.
    func turn(_ row: String, _ act: PostAct) -> Bool {
        let key = ShellActKey(row: row, act: act)
        guard case .pressed(let to) = standings[key] else { return false }
        standings[key] = .pressed(to: !to)
        return true
    }

    /// What the mark is wanted as, while a press on it is out; nothing otherwise.
    func wanted(_ row: String, _ act: PostAct) -> Bool? {
        guard case .pressed(let to) = standing(of: row, act) else { return nil }
        return to
    }

    /// Which press an entry is, counted as presses begin. What a request reads when its answer
    /// lands, to know the entry is still its own: a sign-out or a Clear lets go of the entry
    /// while the request is out, and a later press may have begun another under the same key.
    func flight(_ row: String, _ act: PostAct) -> Int? {
        flights[ShellActKey(row: row, act: act)]
    }

    @ObservationIgnored private var flights: [ShellActKey: Int] = [:]
    @ObservationIgnored private var begun = 0
    /// What each press that did not arrive wanted its mark to be, and when it failed in the
    /// run's order of reads (`ReadMoment`), so a read asked afterwards that shows the mark that
    /// way — the write had landed after all — lets the failure go (`ShellSession.settleMisses`).
    @ObservationIgnored private var missed: [ShellActKey: (wanted: Bool, at: UInt64)] = [:]

    /// Every press that did not arrive, with what it wanted its mark to be and when it failed.
    var misses: [(key: ShellActKey, wanted: Bool, at: UInt64)] {
        missed.map { ($0.key, $0.value.wanted, $0.value.at) }
    }

    /// Marks the act as pressed, drawn as `to` until the source answers, and says whether it
    /// may start: `false` is one already out, which a mark turns instead (`turn`).
    /// `taking` is every row a taking back leaves out meanwhile (`leaving`).
    func begin(_ row: String, _ act: PostAct, to: Bool = true, taking rows: Set<String> = []) -> Bool {
        guard !isOnItsWay(row, act) else { return false }
        let key = ShellActKey(row: row, act: act)
        standings[key] = .pressed(to: to)
        begun += 1
        flights[key] = begun
        missed[key] = nil
        if !rows.isEmpty {
            taken[key] = rows
            leaving.formUnion(rows)
        }
        return true
    }

    /// It arrived. The entry goes, and what the row draws from here is the source's own answer.
    func landed(_ row: String, _ act: PostAct) {
        let key = ShellActKey(row: row, act: act)
        standings[key] = nil
        flights[key] = nil
        missed[key] = nil
        stay(key)
    }

    /// It did not arrive. What the row draws is what the source last said, as it was.
    func failed(_ row: String, _ act: PostAct) {
        let key = ShellActKey(row: row, act: act)
        if case .pressed(let to) = standings[key], let at = ReadMoment.now().place { missed[key] = (to, at) }
        standings[key] = .failed
        flights[key] = nil
        stay(key)
    }

    /// The rows one taking back left out are drawn again, less any another one still has out.
    private func stay(_ key: ShellActKey) {
        guard taken.removeValue(forKey: key) != nil else { return }
        let still = taken.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        if leaving != still { leaving = still }
    }

    /// Lets go of one server's acts — Remove, and Clear. Keyed by the row id, whose first half is
    /// the host: `NoteKey.rowID` joins them on the record separator, which no hostname contains.
    func forget(host raw: String) {
        let prefix = raw.lowercased() + "\u{1e}"
        standings = standings.filter { !$0.key.row.hasPrefix(prefix) }
        flights = flights.filter { !$0.key.row.hasPrefix(prefix) }
        missed = missed.filter { !$0.key.row.hasPrefix(prefix) }
        for key in taken.keys where key.row.hasPrefix(prefix) { stay(key) }
    }

    func clear() {
        standings = [:]
        flights = [:]
        missed = [:]
        taken = [:]
        leaving = []
    }
}
