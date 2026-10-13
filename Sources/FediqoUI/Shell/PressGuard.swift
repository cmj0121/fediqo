import Foundation

// The one guard of a press (#347): what the person pressed that its source has not answered
// yet, kept so that nothing already on its way undoes it.
//
// **Three things are pressed under it, and it is the same thing each time.** A mark on a post
// (`ShellActs`), a notice dismissed or a held-back request answered (`ShellNoticeActs`), and a
// hashtag followed (`ShellTagFollow`) each hold one of these and nothing of their own beside
// it for the purpose. Each used to keep its own table of what was out and its own count of
// presses, and the three agreed only for as long as nobody changed one of them.
//
// **What it guards, in three sentences.** One request at a time is out for a name (`begin`
// hands nothing back while one is). What is drawn while it is out is read here, before
// whatever the source last said (`shown`), so a read that set out earlier and lands meanwhile
// changes what lies under the press and nothing on screen. And an answer is taken only by the
// press that began it (`isStill`): a sign-out, a Clear or a page left lets go of the entry
// while the request is out, another press may begin under the same name, and the answer that
// then comes back finds an entry that is not its own and does nothing.
//
// **Nothing here remembers that a press happened**, and nothing here is written down. A
// press that landed leaves no entry, and so does one that did not arrive: what is said of a
// failure — on the strip, under a line — is its owner's to keep, since each of the three says
// it differently. What is sent, to whom, and what an answer then changes are its owner's too.

/// Which press an entry is, counted as presses begin: no two share one. What a request holds
/// while it is out, to ask when its answer lands whether the entry is still its own.
struct PressNumber: Equatable, Sendable {
    fileprivate let count: Int
}

/// The presses out, by name: each with what is drawn for it meanwhile.
///
/// A value, kept as a stored property of whoever presses under it, so that it is observed as
/// the rest of what that object draws from is. `Name` is what one press is known by — a row
/// and its act, a line's id, a hashtag at a source — and `Shown` what its owner draws while it
/// is out: which way a mark was pressed, or which act is on its way to which source.
struct PressGuard<Name: Hashable, Shown> {
    private struct Entry {
        var shown: Shown
        let press: PressNumber
    }

    private var out: [Name: Entry] = [:]
    private var begun = 0

    /// Whether nothing at all is out.
    var isEmpty: Bool { out.isEmpty }

    /// Every name that has a press out.
    var names: Set<Name> { Set(out.keys) }

    /// Every press out, with what is drawn for it.
    var all: [Name: Shown] { out.mapValues(\.shown) }

    /// Whether a press is out under `name`. **What a second press reads**, so pressing twice
    /// never puts two of the same thing on the wire.
    func isOut(_ name: Name) -> Bool {
        out[name] != nil
    }

    /// What is drawn for `name` while its press is out; nothing where none is. **Read before
    /// what the source last said**, which is what keeps a read landing meanwhile off screen.
    func shown(_ name: Name) -> Shown? {
        out[name]?.shown
    }

    /// A press begins under `name`, drawn as `shown` until its source answers, and is handed
    /// the number it is known by. Nothing where one is out already, and then nothing is sent.
    mutating func begin(_ name: Name, showing shown: Shown) -> PressNumber? {
        guard out[name] == nil else { return nil }
        begun += 1
        let press = PressNumber(count: begun)
        out[name] = Entry(shown: shown, press: press)
        return press
    }

    /// What is drawn for a press still out is changed, and the press stays the one it was: a
    /// mark pressed again turns, with nothing sent. `false` where no press is out.
    mutating func change(_ name: Name, _ turn: (Shown) -> Shown) -> Bool {
        guard let entry = out[name] else { return false }
        out[name]?.shown = turn(entry.shown)
        return true
    }

    /// The number of the press out under `name`, or nothing.
    func press(_ name: Name) -> PressNumber? {
        out[name]?.press
    }

    /// Whether the entry under `name` is still the press that began as `press`. **Asked after
    /// every wait**, and an answer that hears no is told to nobody: the entry was let go of
    /// meanwhile, and whatever stands under the name now is another press's.
    func isStill(_ press: PressNumber?, _ name: Name) -> Bool {
        guard let press else { return false }
        return out[name]?.press == press
    }

    /// The press under `name` is answered, or did not arrive: the entry goes, and what is
    /// drawn from here is what the source last said.
    mutating func settle(_ name: Name) {
        out[name] = nil
    }

    /// Lets go of every press `goes` says yes to — a source's, with its sign-in. A request
    /// still out comes back to no entry of its own.
    mutating func letGo(where goes: (Name, Shown) -> Bool) {
        out = out.filter { !goes($0.key, $0.value.shown) }
    }

    /// Lets go of everything. The count of presses goes on, so a press begun afterwards is
    /// never taken for one that was out before.
    mutating func clear() {
        out = [:]
    }
}
