import FediqoCore
import Foundation
import GRDB

extension StoreGlance {
    /// How long a glance waits on another connection.
    static let wait: TimeInterval = 1

    /// Asked of the file's own date and of a read-only connection, so asking changes nothing.
    static func of(indexAt url: URL, wait: TimeInterval = StoreGlance.wait) -> StoreGlance {
        let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // A store another connection is just then writing is not one that cannot be read: it is
        // waited on for a moment before that is concluded.
        let posts = (try? DatabaseQueue(path: url.path, configuration: StoreFile.configuration(readOnly: true, busyWait: wait)))
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
            try? Guarded.write(Data(), to: directory.appendingPathComponent(aside.base + toldSuffix), atomic: false)
        }
    }
}

// MARK: - A store put aside is not kept for ever

extension StoreFile {
    /// How long a store put aside is kept where nobody answers the notice of it (#344): thirty
    /// days from when it was put aside.
    public static let asideKept: TimeInterval = 30 * 24 * 60 * 60

    /// What comes between an aside's name and the time in the mark that says since when its
    /// thirty days are counted, where that is not the time in its name (`dropExpired`).
    static let sinceInfix = ".since-"

    /// One store put aside and everything that goes under its name.
    struct Aside {
        /// `index-unreadable-<time>…`, without any ending.
        let base: String
        /// Every file of it in the folder: the index, what SQLite kept beside it, the limits'
        /// account, the marks.
        let names: [String]
        /// The time in its name, where its name is one a build wrote.
        let named: Date?

        var index: String? { names.first { $0 == base + ".sqlite" } }

        /// Its files in the order they are removed in (`remove`): the index last, and just
        /// before it the marks the notice of it is read from — that the other store took its
        /// place, then that the person was told.
        var removal: [String] {
            let last = [base + StoreFile.restoredSuffix, base + StoreFile.toldSuffix, base + ".sqlite"]
            return names.filter { !last.contains($0) } + last.filter(names.contains)
        }

        /// The times its `.since` marks carry, where it has any.
        var since: [Date] {
            names.compactMap { name in
                guard name.hasPrefix(base + StoreFile.sinceInfix) else { return nil }
                return StoreFile.stamp.date(from: String(name.dropFirst(base.count + StoreFile.sinceInfix.count)))
            }
        }
    }

    /// The time as the first builds wrote it in a name, and as a mark carries it: to the second.
    static var stamp: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return formatter
    }

    /// The time as a name carries it today: to the millisecond.
    static var fineStamp: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withFractionalSeconds, .withTimeZone]
        return formatter
    }

    /// The base a file's name begins with, and the time in it — by **the three shapes a build
    /// has ever written**, and never by where the first dot falls (today's has one in its time):
    ///
    /// - `index-unreadable-<time>` — the first, to the second;
    /// - `index-unreadable-<time>-<attempt>` — the same build, a second failure in one second;
    /// - `index-unreadable-<time to the millisecond>-<eight of 0-9a-f>` — every build since.
    ///
    /// A base is taken only where what follows it is what follows a base: a dot and an ending,
    /// or the limits' account's own ending. So the first shape is never read out of the second —
    /// `…<time>` is the beginning of `…<time>-2` — and one aside's files are never another's.
    static func named(_ name: String) -> (base: String, at: Date)? {
        let time = #"\d{8}T\d{6}"#
        let shapes: [(String, ISO8601DateFormatter)] = [
            (#"^index-unreadable-(\#(time)\.\d{3}Z)-[0-9a-f]{8}"#, fineStamp),
            (#"^index-unreadable-(\#(time)Z)-\d+"#, stamp),
            (#"^index-unreadable-(\#(time)Z)"#, stamp),
        ]
        for (pattern, formatter) in shapes {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let whole = Range(match.range, in: name), let timed = Range(match.range(at: 1), in: name)
            else { continue }
            let rest = name[whole.upperBound...]
            guard rest.hasPrefix(".") || rest == "-" + LimitAccountFile.name else { continue }
            guard let at = formatter.date(from: String(name[timed])) else { continue }
            return (String(name[whole]), at)
        }
        return nil
    }

    /// Every store put aside in `directory`, each with all that goes under its name — one whose
    /// index is already gone among them, where a removal was cut short. A name no build wrote
    /// is an aside only by an index of that name (`….sqlite`), and has no time in it.
    ///
    /// **A file is one aside's and no other's.** By the shapes where its name has one — so
    /// `…<time>` is not `…<time>-2`'s; else the longest name it goes under, so that of two
    /// names no build wrote, one beginning the other, neither takes the other's.
    static func asides(in directory: URL) -> [Aside] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(unreadablePrefix) }.sorted()
        var bases: Set<String> = []
        var times: [String: Date] = [:]
        for name in names {
            if let known = named(name) {
                bases.insert(known.base)
                times[known.base] = known.at
            } else if name.hasSuffix(".sqlite") {
                bases.insert(String(name.dropLast(".sqlite".count)))
            }
        }
        var own: [String: [String]] = [:]
        for name in names {
            let base = named(name)?.base ?? bases
                .filter { name.hasPrefix($0 + ".") || name == $0 + "-" + LimitAccountFile.name }
                .max { $0.count < $1.count }
            if let base { own[base, default: []].append(name) }
        }
        return bases.sorted().map { Aside(base: $0, names: own[$0] ?? [], named: times[$0]) }
    }

    /// Removes everything under `aside`'s name: **what lies beside the index first, the index
    /// last**. An aside is found by its index, so one whose removal is cut short is found
    /// again and finished; taken first, the index would leave the rest with nothing to find
    /// them by, for ever. **The mark that the person was told goes just before the index**:
    /// cut short anywhere ahead of it, the next save still knows they were, and finishes
    /// (`dropWhatWasReplaced`). **And the mark of what took its place just before that**: cut
    /// short between the last two, it is said once more, and in the sentence that is true.
    static func remove(_ aside: Aside, in directory: URL) {
        for name in aside.removal {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// **A store put aside is gone thirty days after it was** (#344), whether or not the person
    /// ever answered the notice of it: what could not be read is every post that store held,
    /// and nothing let go since reaches it. Asked as a launch begins, before any index is
    /// opened and in a run with or without one — **and only where the canary reads**
    /// (`open`): this deletes, and nothing is deleted on a device that may be locked.
    ///
    /// It is the person's only copy of that store, and it must not go early:
    ///
    /// - **Each has one time its days are counted from**: the mark beside it where there is
    ///   one (`<base>.since-<time>`), else the time in its name, in any shape a build has
    ///   written. A name no build wrote, with no mark, has neither, and then it is when
    ///   its index was last written — its modification date. **A mark never counts for less than the name
    ///   once the clock has reached the name's time**: such a mark was made by a launch whose
    ///   clock was behind, and the later of the two is taken.
    /// - **And never, whichever of those it is, from before its index was last written**, where that is not ahead of the
    ///   clock: a store written then was not put aside before then, whatever a name or a mark
    ///   made under a clock that was behind says — a device come back from a dead battery,
    ///   whose launch put the store aside under a name a quarter of a century old.
    /// - **A time ahead of the clock counts as now, and is written down as now**: a mark is
    ///   made — in place of one that lay ahead — and the thirty days run from this launch. A
    ///   clock that was wrong when the store was put aside does not keep it for ever.
    /// - **Nothing goes in a launch that made such a mark.** The clock was behind one of
    ///   them, and is not one to delete by; the marks being made first, a name years ahead
    ///   holds everything back for this one launch and no longer. **One whose mark could not
    ///   be written is itself kept, and holds nothing else back**: a folder that refuses the
    ///   mark at every launch would otherwise keep every other for ever.
    ///
    /// A save never does this: what a save lets go is what the person was told of
    /// (`dropWhatWasReplaced`). Answers how many went, which is also said in the log.
    @discardableResult
    static func dropExpired(
        in directory: URL, now: Date, kept: TimeInterval = StoreFile.asideKept, on device: Guarded.Device = .this
    ) -> Int {
        var times: [(aside: Aside, since: Date)] = []
        var ahead = false
        for aside in asides(in: directory) {
            // Of several marks — a replacing cut short — the latest that is not ahead of the
            // clock: the later, the longer kept.
            let marks = aside.since
            let mark = marks.filter { $0 <= now }.max() ?? marks.min()
            let written = aside.index.flatMap {
                try? directory.appendingPathComponent($0)
                    .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            var since: Date
            if let mark, let inName = aside.named, inName <= now {
                // The clock has reached the time in the name, so that time was never ahead of
                // a true clock: the mark was made by a launch whose own clock was behind, and
                // counting from it would take the store years early. The later of the two.
                since = max(mark, inName)
            } else if let mark {
                since = mark
            } else if let inName = aside.named {
                since = inName
            } else if let written {
                since = written
            } else {
                // Nothing says when: counted from now, this launch and every one, and so kept.
                since = now
            }
            // Not from before its index was last written: only ever the longer kept.
            if let written, written <= now { since = max(since, written) }
            if since > now {
                // Counted from now — and said so beside it, or the next launch counts from
                // the same wrong time again. Not said, it is not counted at all this launch.
                let stamped = aside.base + sinceInfix + stamp.string(from: now)
                guard (try? Guarded.write(Data(), to: directory.appendingPathComponent(stamped), atomic: false, on: device)) != nil
                else { continue }
                ahead = true
                for name in aside.names where name.hasPrefix(aside.base + sinceInfix) && name != stamped {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                }
                continue
            }
            times.append((aside, since))
        }
        // A clock that was behind any of them as this launch began is a clock not to delete
        // by: the marks are made, and it is the next launch — which finds nothing ahead of it,
        // where the clock is right — that lets anything go.
        guard !ahead else { return 0 }
        let gone = times.filter { now.timeIntervalSince($0.since) >= kept }
        for (aside, _) in gone { remove(aside, in: directory) }
        StoreSaver.reportExpired(gone.count)
        return gone.count
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
