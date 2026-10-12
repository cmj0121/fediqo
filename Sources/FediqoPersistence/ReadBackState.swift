import FediqoCore
import Foundation
import os

/// How far a read back's commit got, as **a name in the aside** (#344) and not as something
/// written inside a file.
///
/// **Why a name.** What a marker says inside cannot be read on a locked device, and read as
/// "says nothing" it is acted on: an aside whose marker says replaced would have its old
/// index put back over the package's. A name is read by listing the folder, which a lock does
/// not refuse; it is moved on by one rename, whole or not at all; and there are no contents
/// to misread.
///
/// **Two files.** `.committing` is in every state, and empty: the anchor a build before this
/// one looks for. Such a build removes any `incoming-` folder without one, and reads an empty
/// one as "moved aside, not replaced" — so, meeting any state written here, it either puts the
/// old index back or keeps both stores and asks. It never deletes the old store. Beside the
/// anchor is the state, `.state-<name>`, made with it before anything moves.
///
/// **An earlier build's word still counts.** An anchor with no state name beside it is a
/// marker such a build wrote, and is read as it wrote it — by a reader that throws where the
/// contents will not be read, never one that takes them for empty. And where a state name is
/// present the anchor is still looked at: one with anything in it is an earlier build having
/// spoken since, and its word wins.
///
/// **Displaced is the one state said both ways**: the name, and the earlier build's own word
/// in the anchor — so that such a build knows a store chosen against for what it is, and can
/// make it the store again as it always could, by emptying the anchor. This build reads
/// displaced only where both say so; an anchor emptied since is that build's word, "moved
/// aside". **No date is compared anywhere**: what each file says, and whether it is there.
///
/// **Where these names are reached.** In the app as it ships, this build's own read back does
/// not move its index at all: a run with its store open commits through that connection
/// (`commitIndex`), and a run without one refuses a whole read back. So the names govern what
/// a build before this one left on disk, and what a choice between two stores makes
/// (`choose`); the aside-and-rename commit is reached by a device with no file open, which
/// today is a test's. What a lock can leave owed in the app is the other steps — the
/// sign-ins, the index saved back, the pictures, the settings, the limits (`finishOwed`).
extension StorePackager {
    ///
    /// **A build after this one must not add a name here without a way back.** A name this
    /// build does not know, or two at once, is not read as anything: it throws at every launch
    /// and everything is kept — so a person going back to this build from one that wrote a new
    /// name would be left with no store opened until they went forward again. A later build
    /// that needs another state takes its asides back to a name written here before it can be
    /// left for this one.
    enum AsideState: String, CaseIterable, Sendable {
        /// The old index is here, moved out of the way; nothing has taken its place.
        case aside
        /// The package's index is on its way in: one found in place is the package's.
        case replacing
        /// The package's index is in place, and the rest of the read back has not yet held.
        /// **Not "replaced"**: a run killed here leaves both stores, and the next launch asks
        /// which is the store.
        case landed
        /// The whole read back held: the old index here was replaced, and goes.
        case replaced
        /// A later step refused: the index in place is on its way out, and this is the store.
        case undoing
        /// A store the person chose against is being moved in here, its index first; what
        /// SQLite kept beside it may still be where it was. A launch finishes the move.
        case displacing
        /// A store the person chose against: kept until the one they chose has opened and saved.
        case displaced
    }

    static let statePrefix = ".state-"

    /// What an earlier build's marker says, by what it holds.
    private static func earlier(_ word: Data) -> AsideState {
        switch word {
        case replacingMark: .replacing
        case replacedMark: .replaced
        case undoingMark: .undoing
        case displacedMark: .displaced
        default: .aside
        }
    }

    /// A state name this build does not know: a build after this one wrote it, and what it
    /// means is not this one's to guess. Whoever asks keeps everything.
    struct UnknownState: Error {}

    /// The anchor and the state names of `aside` as a listing finds them: nil where there is
    /// no anchor. Throws where the folder cannot be listed, the anchor cannot be asked about,
    /// or a state name is one this build does not know.
    private static func marks(of aside: URL) throws -> (anchor: URL, size: Int, states: [(state: AsideState, file: URL)])? {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: aside.path).sorted()
        guard names.contains(committingMarker) else { return nil }
        let anchor = aside.appendingPathComponent(committingMarker)
        let size = (try manager.attributesOfItem(atPath: anchor.path)[.size] as? NSNumber)?.intValue ?? 0
        let states = try names.filter { $0.hasPrefix(statePrefix) }.map { name -> (state: AsideState, file: URL) in
            guard let state = AsideState(rawValue: String(name.dropFirst(statePrefix.count))) else { throw UnknownState() }
            return (state, aside.appendingPathComponent(name))
        }
        return (anchor, size, states)
    }

    /// The state of `aside`, or nil where it has no anchor and so is no commit's aside.
    ///
    /// **A listing and the anchor's size — nothing is opened** unless the anchor holds
    /// something, and then it is read by a reader that throws: what a locked device will not
    /// let be read is not "moved aside". More than one state name — a move from one to the
    /// next cut short by something other than a rename — is not a state at all, and throws.
    static func state(of aside: URL) throws -> AsideState? {
        guard let marks = try marks(of: aside) else { return nil }
        let word = marks.size == 0 ? Data() : try Data(contentsOf: marks.anchor)
        guard let named = marks.states.first else { return earlier(word) }
        guard marks.states.count == 1 else { throw UnknownState() }
        // Chosen against only where both say so; an anchor emptied since is an earlier build
        // having made this the store to put back again.
        if named.state == .displaced { return earlier(word) }
        // Anything in the anchor is an earlier build having spoken since: its word wins.
        return word.isEmpty ? named.state : earlier(word)
    }

    /// Makes `aside` an aside in `state`: the anchor, then the state beside it — before
    /// anything is moved into it.
    static func begin(_ aside: URL, as state: AsideState) throws {
        try Guarded.makeFolder(aside)
        try Guarded.write(Data(), to: aside.appendingPathComponent(committingMarker), atomic: false)
        try Guarded.write(Data(), to: aside.appendingPathComponent(statePrefix + state.rawValue), atomic: false)
    }

    /// Moves `aside` on to `state`. **One rename**, where this build's own word stands: whole
    /// or not at all, and nothing a lock refuses for want of a key. Where an earlier build's
    /// word stands instead — a marker with no state name, or one it wrote into since — the
    /// word is taken back: the anchor emptied, then the name made.
    ///
    /// Displaced is said in the anchor too, and first: from that write on it reads as chosen
    /// against, by this build and by one before it, whether or not the rename follows.
    static func say(_ state: AsideState, of aside: URL) throws {
        // Unknown names are not this build's to move: the throw is the caller's answer.
        guard let marks = try marks(of: aside) else { throw CocoaError(.fileNoSuchFile) }
        let manager = FileManager.default
        let named = aside.appendingPathComponent(statePrefix + state.rawValue)
        if state == .displaced {
            try Guarded.write(displacedMark, to: marks.anchor)
        } else if marks.size > 0 {
            try Guarded.write(Data(), to: marks.anchor)
        }
        guard let current = marks.states.first else {
            return try Guarded.write(Data(), to: named, atomic: false)
        }
        // Nothing left from a move cut short may stand where the name is going, or beside it.
        for stale in marks.states.dropFirst() { try manager.removeItem(at: stale.file) }
        if current.state != state { try manager.moveItem(at: current.file, to: named) }
    }
}

// MARK: - A commit's own name

extension StorePackager {
    /// **A read back's commit, said by a name of its own beside the index** (#344), from before
    /// its first step until its last has been settled or put back.
    ///
    /// The steps' own names (`.owed-<step>`) are made before each step runs — while the device
    /// can still be written — so a run that ends midway, or with an undo a lock refused, leaves
    /// them for the next. This name is what says whether they are to be believed:
    ///
    /// - **`.reading-back-<id>`, held open and locked by the process that made it** — a commit
    ///   is running, or its undo is still owed, in a run that lives. Nothing of it is anybody
    ///   else's to settle or to say. The lock is the system's own (`flock`), which goes with
    ///   the process however it ends: **a name nobody holds is a run that ended**, and that is
    ///   how a name left by a killed process is told from a live one — never by its age.
    /// - **The same name with nobody holding it** — the run ended midway. The steps named
    ///   beside it were not put back, and are said.
    /// - **`.read-back-held-<id>`** — every step held, said by one rename before anything of
    ///   the commit is cleared away. Steps still named beside it are only names that run did
    ///   not live to remove: they go, and nothing is said.
    ///
    /// Nothing is ever read out of the file: a listing, and whether the lock can be had.
    final class Flight: @unchecked Sendable {
        static let prefix = ".reading-back-"
        static let heldPrefix = ".read-back-held-"

        private let lock = NSLock()
        private var url: URL
        private var handle: FileHandle?

        /// Makes the name in `directory` and holds it. Throws where it cannot be made or
        /// held: the commit then does not begin.
        init(in directory: URL) throws {
            let id = UUID().uuidString
            url = directory.appendingPathComponent(Self.prefix + id)
            let made = try Guarded.makeFile(at: url)
            guard flock(made.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                let refusal = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                try? made.close()
                try? FileManager.default.removeItem(at: url)
                throw refusal
            }
            handle = made
        }

        deinit { try? handle?.close() }

        /// Every step held: said by one rename, which keeps the file and the hold on it.
        /// Whether it could be said.
        @discardableResult
        func sayHeld() -> Bool {
            lock.withLock {
                let name = url.lastPathComponent
                guard name.hasPrefix(Self.prefix) else { return true }
                let held = url.deletingLastPathComponent()
                    .appendingPathComponent(Self.heldPrefix + String(name.dropFirst(Self.prefix.count)))
                guard (try? FileManager.default.moveItem(at: url, to: held)) != nil else { return false }
                url = held
                return true
            }
        }

        /// The commit is over and nothing of it is owed: the hold is let go, and the name
        /// with it — unless `keepingName`, where a step's name would not go and this one
        /// must stay to say what that is.
        func end(keepingName: Bool = false) {
            lock.withLock {
                if !keepingName { try? FileManager.default.removeItem(at: url) }
                try? handle?.close()
                handle = nil
            }
        }

        /// What stands in a folder: whether a commit there is held by a run that lives, and
        /// the names nobody holds.
        struct Standing {
            var live = false
            var cutShort: [URL] = []
            var held: [URL] = []

            /// Whether the steps named in the folder are to be believed: nobody is still
            /// at them, and no commit left its word that every step held — or one that
            /// ended midway is there as well, and what it left is said.
            var believed: Bool { !live && (!cutShort.isEmpty || held.isEmpty) }
        }

        static func standing(in directory: URL) -> Standing {
            var found = Standing()
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
            for name in names where name.hasPrefix(prefix) || name.hasPrefix(heldPrefix) {
                let url = directory.appendingPathComponent(name)
                switch isHeld(url) {
                case nil: continue
                case true?: found.live = true
                case false?: if name.hasPrefix(prefix) { found.cutShort.append(url) } else { found.held.append(url) }
                }
            }
            return found
        }

        /// Whether a process holds `url`; nil where it has gone meanwhile. **One that will
        /// not be opened is not known to be let go**, and is taken for held: nothing is
        /// settled or said on a guess.
        private static func isHeld(_ url: URL) -> Bool? {
            guard let asked = try? FileHandle(forReadingFrom: url) else {
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                // Said, because nothing else would: while it will not open, nothing in
                // this folder is settled and no step named in it is said.
                NetLog.protection.error("A read back's own name would not be opened and is taken for held; nothing beside it is settled")
                return true
            }
            defer { try? asked.close() }
            guard flock(asked.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else { return true }
            flock(asked.fileDescriptor, LOCK_UN)
            return false
        }
    }
}
