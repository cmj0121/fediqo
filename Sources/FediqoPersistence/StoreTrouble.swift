import FediqoCore
import Foundation
import GRDB

extension StoreGlance {
    /// How long a glance waits on another connection.
    static let wait: TimeInterval = 1

    /// Asked of the file's own date and of a read-only connection, so asking changes nothing.
    static func of(indexAt url: URL, wait: TimeInterval = StoreGlance.wait) -> StoreGlance {
        let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var readOnly = Configuration()
        readOnly.readonly = true
        // A store another connection is just then writing is not one that cannot be read: it is
        // waited on for a moment before that is concluded.
        readOnly.busyMode = .timeout(wait)
        let posts = (try? DatabaseQueue(path: url.path, configuration: readOnly))
            .flatMap { try? $0.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note") } }
        return StoreGlance(written: written, posts: posts)
    }
}

extension StoreFile {
    /// What failing to open or read the store says about it.
    enum Cause: Equatable {
        /// The file's own contents: not a database, a page that does not add up, a table or a
        /// row this build's reading of it will not take. No later launch reads it differently.
        case damaged
        /// The moment: see `StoreTrouble.Unreachable`.
        case unreachable(StoreTrouble.Unreachable)
    }

    /// Which of the two `error` is, **by what was reported and never by its words**.
    ///
    /// - SQLite's own code, for an error it raised (`DatabaseError.resultCode`, its primary
    ///   code): `NOTADB` and `CORRUPT` are the file not being a database, or not a whole one.
    ///   `ERROR`, `CONSTRAINT` and `MISMATCH` are what a migration or a read gets from tables
    ///   that are not the ones this build wrote — a store whose migration fails. All five are
    ///   answers about the contents. `BUSY` and `LOCKED` are another connection; `FULL` is the
    ///   disk; every other code — `IOERR`, `CANTOPEN`, `PERM`, `READONLY`, `NOMEM`, `AUTH`,
    ///   `PROTOCOL`, `INTERRUPT`, and any this list does not name — is the moment.
    /// - A row that will not decode (`DecodingError`, GRDB's `RowDecodingError`): the contents.
    /// - Anything else — the file system refusing the folder, an error nobody here knows — is
    ///   the moment. **What is not known to be damage is not treated as damage**: being wrong
    ///   that way costs a launch with no store, and being wrong the other way costs the store.
    static func cause(of error: any Error) -> Cause {
        if let error = error as? DatabaseError {
            switch error.resultCode.primaryResultCode {
            case .SQLITE_NOTADB, .SQLITE_CORRUPT, .SQLITE_ERROR, .SQLITE_CONSTRAINT, .SQLITE_MISMATCH:
                return .damaged
            case .SQLITE_BUSY, .SQLITE_LOCKED:
                return .unreachable(.inUse)
            case .SQLITE_FULL:
                return .unreachable(.noRoom)
            default:
                return .unreachable(.outOfReach)
            }
        }
        if error is DecodingError || error is RowDecodingError { return .damaged }
        let said = error as NSError
        let noRoom = (said.domain == NSCocoaErrorDomain && said.code == CocoaError.fileWriteOutOfSpace.rawValue)
            || (said.domain == NSPOSIXErrorDomain && said.code == Int(ENOSPC))
        return .unreachable(noRoom ? .noRoom : .outOfReach)
    }

    /// How long opening waits on another connection before saying the store is in use: about
    /// what a save of the largest store this app is built for takes, so another copy of the app
    /// caught mid-save has finished by then, and a launch behind one that hangs is still a
    /// launch. Paid only where there is something to wait for.
    public static let busyWait: TimeInterval = 3

    // MARK: - A store put aside, and the person told

    /// What ends the name of the mark that the person has been told of a store put aside.
    static let toldSuffix = ".told"
    /// What ends the name of the mark that the other of two stores, and not an empty one, took a
    /// damaged store's place — so the notice of it says so.
    static let restoredSuffix = ".restored"

    /// The stores put aside in `directory` as unreadable, by the name each goes under without
    /// its ending — `index-unreadable-<time>-<random>` — and whether the person has been told.
    static func putAside(in directory: URL) -> [(base: String, told: Bool)] {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        return names.filter { $0.hasPrefix(unreadablePrefix) && $0.hasSuffix(".sqlite") }.sorted().map { name in
            let base = String(name.dropLast(".sqlite".count))
            return (base, names.contains(base + toldSuffix))
        }
    }

    /// The person has been told of every store put aside in `directory`: each is marked, and is
    /// deleted by the next save that succeeds (`dropWhatWasReplaced`).
    ///
    /// **A mark beside the store it is about, and not a preference.** It goes where the folder
    /// goes and is deleted with what it marks, so it cannot outlive its store and come to speak
    /// for another one. **Safe to lose**: without it the store put aside is simply kept, and the
    /// person is told again at the next launch — the mark only ever lets something go that they
    /// were told would go.
    public static func told(in directory: URL) {
        for aside in putAside(in: directory) where !aside.told {
            try? Data().write(to: directory.appendingPathComponent(aside.base + toldSuffix))
        }
    }
}

extension StoreSaver {
    /// What follows the person's answer to a store's trouble (#295), in the folder the store
    /// lives in.
    ///
    /// **Told of a store put aside**: it is marked, and what took its place is saved again —
    /// whether or not anything changed since the last save — because the store put aside goes
    /// only once both have happened, and a run in which nothing new arrives would otherwise
    /// never save. **Of two stores, one chosen**: the choice is written down, and takes effect
    /// when the app is next opened; the other goes after the chosen one has opened and saved.
    public func answered(_ answer: StoreTroubleAnswer, to trouble: StoreTrouble, in directory: URL) async {
        switch (trouble, answer) {
        case (.damaged, .told):
            StoreFile.told(in: directory)
            try? await resave()
        case (.twoStores, .keepInPlace):
            StorePackager.choose(.keepInPlace, in: directory)
        case (.twoStores, .putBack):
            StorePackager.choose(.putBack, in: directory)
        default:
            break
        }
    }
}
