import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// #344: a store put aside because it could not be read is gone thirty days after it was,
/// whether or not anybody answered the notice of it — and not a day before: it is the only
/// copy of that store there is. Every date here is one the check names; nothing waits.
@Suite("A store put aside is gone after thirty days, and not before")
struct AsideExpiryTests {
    private static let mastodon = PackagerFixture.mastodon
    private static let day: TimeInterval = 24 * 60 * 60
    /// When the store here was put aside.
    private static let then = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func names(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    /// Says `name` was last written at `time`.
    private func touch(_ name: String, at time: Date, in dir: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: dir.appendingPathComponent(name).path)
    }

    private func asideFiles(_ dir: URL) throws -> [String] {
        try names(dir).filter { $0.hasPrefix("index-unreadable-") }
    }

    /// A damaged store put aside by a launch at `then`, with everything a build leaves beside
    /// one: what SQLite kept, the limits' account. The store that took its place is open.
    private func putAside(in dir: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: dir.appendingPathComponent("index.sqlite"))
        try Data("[]".utf8).write(to: dir.appendingPathComponent("limits.json"))
        // Last written the day before, whatever the day this check is run on.
        try touch("index.sqlite", at: Self.then.addingTimeInterval(-Self.day), in: dir)
        let opened = StoreFile.open(at: dir, now: Self.then)
        let aside = try #require(opened.setAside)
        try #require(opened.trouble == .damaged(replacedBy: .empty))
        try opened.file?.db.close()
        // And something SQLite kept beside it, as a store put aside mid-write has.
        try Data("beside it".utf8).write(to: URL(fileURLWithPath: aside.path + "-wal"))
        let files = try asideFiles(dir)
        try #require(files.count == 3, "the premise: the index, what was beside it and the limits' account: \(files)")
        return files
    }

    /// A launch at `now`: what is on disk afterwards.
    private func launch(_ dir: URL, at now: Date, canary: ProtectedData = .always) throws -> [String] {
        try StoreFile.open(at: dir, now: now, protected: canary).file?.db.close()
        return try asideFiles(dir)
    }

    // MARK: - The names

    @Test("Each of the three shapes a build has written is read for its base and its time, and one is never read out of another")
    func theShapes() throws {
        let first = "index-unreadable-20270115T080000Z"
        let named: [(String, String?)] = [
            ("\(first).sqlite", first), ("\(first).sqlite-journal", first), ("\(first)-limits.json", first),
            ("\(first).told", first), ("\(first).since-20270301T000000Z", first),
            // The same build, a second failure in the same second: another aside altogether.
            ("\(first)-2.sqlite", "\(first)-2"), ("\(first)-2-limits.json", "\(first)-2"), ("\(first)-12.restored", "\(first)-12"),
            // Every build since: a time with a dot in it, and eight of 0-9a-f.
            ("index-unreadable-20270115T080000.123Z-0a1b2c3d.sqlite", "index-unreadable-20270115T080000.123Z-0a1b2c3d"),
            ("index-unreadable-20270115T080000.123Z-0a1b2c3d.sqlite-wal", "index-unreadable-20270115T080000.123Z-0a1b2c3d"),
            ("index-unreadable-20270115T080000.123Z-0a1b2c3d-limits.json", "index-unreadable-20270115T080000.123Z-0a1b2c3d"),
            // No build wrote these.
            ("index-unreadable-yesterday.sqlite", nil), ("index-unreadable-20270115T080000Z-two.sqlite", nil),
            ("index-unreadable-20270115T080000Zextra.sqlite", nil), ("index-unreadable-20279915T080000Z.sqlite", nil),
        ]
        for (name, base) in named {
            #expect(StoreFile.named(name)?.base == base, "\(name)")
        }
        #expect(StoreFile.named("\(first).sqlite")?.at == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(StoreFile.named("index-unreadable-20270115T080000.123Z-0a1b2c3d.sqlite")?.at == Date(timeIntervalSince1970: 1_800_000_000.123))
        // Today's own name is one of them.
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in try putAside(in: dir) {
            #expect(StoreFile.named(name)?.at == Self.then, "\(name)")
        }
    }

    // MARK: - Thirty days

    @Test("Kept for thirty days and gone at the next launch after — everything under its name, whether or not the notice was ever answered")
    func thirtyDays() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try putAside(in: dir)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(29 * Self.day + 86_399)) == files, "a second short of thirty days")
        // Nobody pressed anything: it is still said, right up to the launch that removes it.
        #expect(StoreFile.open(at: dir, now: Self.then.addingTimeInterval(29 * Self.day)).trouble == .damaged(replacedBy: .empty))
        #expect(try launch(dir, at: Self.then.addingTimeInterval(30 * Self.day)).isEmpty)
        #expect(try names(dir) == [Guarded.canaryName, "index.sqlite"].filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) })
        #expect(StoreFile.open(at: dir, now: Self.then.addingTimeInterval(31 * Self.day)).trouble == nil, "nothing left to tell of")
    }

    @Test("In a run with no store at all it goes just the same")
    func withNoStore() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try putAside(in: dir)
        // A read back left unsettled: no index is opened in this run.
        let aside = dir.appendingPathComponent("incoming-aside-\(UUID().uuidString)", isDirectory: true)
        try StorePackager.begin(aside, as: .landed)
        try FileManager.default.copyItem(at: dir.appendingPathComponent("index.sqlite"), to: aside.appendingPathComponent("index.sqlite"))
        let opened = StoreFile.open(at: dir, now: Self.then.addingTimeInterval(30 * Self.day))
        #expect(opened.file == nil)
        #expect(try asideFiles(dir).isEmpty)
        // And nothing else: the store the read back moved out of the way is where it was.
        #expect(try StorePackager.unsettledReadBack(in: dir) != nil)
        #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent("index.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.sqlite").path))
    }

    @Test("Nothing goes where the canary does not read: a deletion is not made on a device that may be locked, or cannot say — nor on one a person unlocked whose canary still refuses",
          arguments: [ProtectedData.Canary.refused, .none, .closed], [false, true])
    func notBehindALock(canary: ProtectedData.Canary, unlocked: Bool) throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try putAside(in: dir)
        let opened = StoreFile.open(at: dir, now: Self.then.addingTimeInterval(400 * Self.day), protected: CanaryByHand(canary).protected, unlocked: unlocked)
        try opened.file?.db.close()
        #expect(try asideFiles(dir) == files)
    }

    @Test("A save never does this, however many and however late: only a launch")
    func notASave() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try putAside(in: dir)
        let file = try StoreFile(at: dir)
        for _ in 0..<3 { try await file.save(sources: [Self.mastodon], notes: []) }
        try file.db.close()
        #expect(try asideFiles(dir) == files)
    }

    // MARK: - A clock that is wrong

    /// An aside under a name of the first shape, at `time`, with its files.
    private func anAside(at time: Date, attempt: Int? = nil, in dir: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = "index-unreadable-" + StoreFile.stamp.string(from: time) + (attempt.map { "-\($0)" } ?? "")
        let files = [base + ".sqlite", base + ".sqlite-journal", base + "-limits.json", base + ".told"]
        for name in files { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        // Last written when it was put aside, whatever the day this check is run on.
        try touch(base + ".sqlite", at: time, in: dir)
        return files.sorted()
    }

    @Test("A name years ahead of the clock counts from this launch, said in a mark; it holds the others back for this one launch, and is gone thirty days on")
    func aNameAhead() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Self.then
        let old = try anAside(at: now.addingTimeInterval(-40 * Self.day), in: dir)
        let ahead = try anAside(at: now.addingTimeInterval(3_650 * Self.day), in: dir)
        let aheadBase = String(ahead.first { $0.hasSuffix(".sqlite") }!.dropLast(".sqlite".count))
        // This launch: the one ahead is marked as counted from now, and nothing goes — the
        // clock was behind one of them when it was asked.
        let after = try launch(dir, at: now)
        let mark = try #require(after.first { $0.contains(".since-") })
        #expect(mark.hasPrefix(aheadBase) && mark.hasSuffix(StoreFile.stamp.string(from: now)))
        #expect(Set(after) == Set(old + ahead + [mark]))
        // The next: nothing is ahead any more, and the old one goes. The marked one stays.
        #expect(Set(try launch(dir, at: now.addingTimeInterval(1))) == Set(ahead + [mark]))
        #expect(Set(try launch(dir, at: now.addingTimeInterval(29 * Self.day))) == Set(ahead + [mark]))
        #expect(try launch(dir, at: now.addingTimeInterval(30 * Self.day)).isEmpty, "its mark goes with it")
    }

    @Test("A mark that lies ahead of the clock is replaced by one that says now")
    func aMarkAhead() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Self.then
        let files = try anAside(at: now.addingTimeInterval(3_650 * Self.day), in: dir)
        let base = String(files.first { $0.hasSuffix(".sqlite") }!.dropLast(".sqlite".count))
        try Data().write(to: dir.appendingPathComponent(base + ".since-" + StoreFile.stamp.string(from: now.addingTimeInterval(500 * Self.day))))
        let after = try launch(dir, at: now)
        #expect(after.filter { $0.contains(".since-") } == [base + ".since-" + StoreFile.stamp.string(from: now)])
        #expect(try launch(dir, at: now.addingTimeInterval(30 * Self.day)).isEmpty)
    }

    @Test("A clock that was years behind at one launch does not take the store early: once the clock has reached the name's time, the name's time counts")
    func aClockThatWasBehind() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try putAside(in: dir)
        // A launch after a dead battery: the clock says a quarter of a century ago.
        let behind = Self.then.addingTimeInterval(-9_000 * Self.day)
        let marked = try launch(dir, at: behind)
        #expect(marked.count == files.count + 1, "counted from that launch, and said so")
        // The clock is right again, a day after the store was put aside: by the mark it is
        // decades old. It is kept — and goes thirty days after it was really put aside.
        #expect(try launch(dir, at: Self.then.addingTimeInterval(Self.day)) == marked)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(29 * Self.day)) == marked)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(30 * Self.day)).isEmpty)
    }

    @Test("A launch whose clock is behind any of them removes nothing, whatever else is old enough: the next one, with nothing ahead of it, does")
    func aClockSetBack() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recent = try putAside(in: dir)
        let old = try anAside(at: Self.then.addingTimeInterval(-400 * Self.day), in: dir)
        // The clock a day behind when the recent one was put aside.
        let behind = Self.then.addingTimeInterval(-Self.day)
        let after = try launch(dir, at: behind)
        let mark = try #require(after.first { $0.contains(".since-") })
        #expect(Set(after) == Set(old + recent + [mark]), "the old one went by a clock that was behind another")
        #expect(Set(try launch(dir, at: behind.addingTimeInterval(1))) == Set(recent + [mark]))
    }

    @Test("A store put aside by a launch whose clock was years behind is named from when it was last written, and is kept its thirty days once the clock is right")
    func putAsideUnderAClockBehind() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: dir.appendingPathComponent("index.sqlite"))
        try touch("index.sqlite", at: Self.then, in: dir)
        // A dead battery: the launch that finds it damaged says a quarter of a century ago.
        let opened = StoreFile.open(at: dir, now: Self.then.addingTimeInterval(-9_000 * Self.day))
        try opened.file?.db.close()
        let files = try asideFiles(dir)
        #expect(StoreFile.named(try #require(opened.setAside).lastPathComponent)?.at == Self.then)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(Self.day)) == files)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(29 * Self.day)) == files)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(30 * Self.day)).isEmpty)
    }

    @Test("Where the open that fails itself writes the index under the clock that is behind — a journal rolled back — the name is still from when it was last written before that launch")
    func writtenByTheLaunchThatPutsItAside() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: dir.appendingPathComponent("index.sqlite"))
        try touch("index.sqlite", at: Self.then, in: dir)
        let behind = Self.then.addingTimeInterval(-9_000 * Self.day)
        let opened = StoreFile.open(at: dir, now: behind) { folder in
            try touch("index.sqlite", at: behind, in: folder)
            throw DatabaseError(resultCode: .SQLITE_NOTADB)
        }
        #expect(StoreFile.named(try #require(opened.setAside).lastPathComponent)?.at == Self.then)
    }

    @Test("A name older than its own index — put aside by a build that named it by a clock that was behind — counts from when the index was last written", arguments: [false, true])
    func aNameOlderThanItsIndex(marked: Bool) throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files: [String]
        if marked {
            // No time in its name, and a mark from the same wrong clock.
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            files = ["index-unreadable-by-hand.since-" + StoreFile.stamp.string(from: Self.then.addingTimeInterval(-9_000 * Self.day)), "index-unreadable-by-hand.sqlite"]
            for name in files { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        } else {
            files = try anAside(at: Self.then.addingTimeInterval(-9_000 * Self.day), in: dir)
        }
        try touch(try #require(files.first { $0.hasSuffix(".sqlite") }), at: Self.then, in: dir)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(Self.day)) == files)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(29 * Self.day)) == files)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(30 * Self.day)).isEmpty)
    }

    @Test("An index that says it was last written years ahead says nothing: the time in the name counts, and no mark is made")
    func anIndexWrittenAhead() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try anAside(at: Self.then.addingTimeInterval(-29 * Self.day), in: dir)
        try touch(try #require(files.first { $0.hasSuffix(".sqlite") }), at: Self.then.addingTimeInterval(3_650 * Self.day), in: dir)
        #expect(try launch(dir, at: Self.then) == files)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(Self.day)).isEmpty)
    }

    @Test("One whose mark cannot be written is kept this launch and holds nothing else back; where it can, it holds the rest back this once")
    func aMarkThatCannotBeWritten() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try anAside(at: Self.then.addingTimeInterval(-40 * Self.day), in: dir)
        let ahead = try anAside(at: Self.then.addingTimeInterval(3_650 * Self.day), in: dir)
        let other = scratch()
        defer { try? FileManager.default.removeItem(at: other) }
        for name in old + ahead {
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: dir.appendingPathComponent(name), to: other.appendingPathComponent(name))
        }
        try touch(try #require(old.first { $0.hasSuffix(".sqlite") }), at: Self.then.addingTimeInterval(-40 * Self.day), in: other)
        // A folder that takes no file at the class, on a volume that takes the class.
        let refusing = Guarded.Device(
            asks: .complete, held: { _ in nil }, canaryTook: { true }, count: {},
            asking: { throw CocoaError(.fileWriteNoPermission) }
        )
        #expect(StoreFile.dropExpired(in: dir, now: Self.then, on: refusing) == 1)
        #expect(try asideFiles(dir) == ahead, "no mark, the one ahead whole, the old one gone")
        // Where the mark is written: nothing goes in that launch.
        #expect(StoreFile.dropExpired(in: other, now: Self.then) == 0)
        #expect(try asideFiles(other).count == old.count + ahead.count + 1)
    }

    @Test("Of two marks the later that is not ahead counts; a mark that says no time is no mark; a mark beside a name still ahead is what counts")
    func whichMark() throws {
        let stamp = StoreFile.stamp
        // Two marks.
        var dir = scratch()
        var files = try anAside(at: Self.then.addingTimeInterval(-100 * Self.day), in: dir)
        var base = String(try #require(files.first { $0.hasSuffix(".sqlite") }).dropLast(".sqlite".count))
        for days in [-50.0, -10.0] {
            files.append(base + ".since-" + stamp.string(from: Self.then.addingTimeInterval(days * Self.day)))
            try Data().write(to: dir.appendingPathComponent(files[files.count - 1]))
        }
        #expect(Set(try launch(dir, at: Self.then.addingTimeInterval(19 * Self.day))) == Set(files))
        #expect(try launch(dir, at: Self.then.addingTimeInterval(20 * Self.day)).isEmpty)
        try? FileManager.default.removeItem(at: dir)
        // A mark that says no time: the name's time counts, and the mark goes with the rest.
        dir = scratch()
        files = try anAside(at: Self.then.addingTimeInterval(-29 * Self.day), in: dir)
        base = String(try #require(files.first { $0.hasSuffix(".sqlite") }).dropLast(".sqlite".count))
        files.append(base + ".since-whenever")
        try Data().write(to: dir.appendingPathComponent(files[files.count - 1]))
        #expect(Set(try launch(dir, at: Self.then)) == Set(files))
        #expect(try launch(dir, at: Self.then.addingTimeInterval(Self.day)).isEmpty)
        try? FileManager.default.removeItem(at: dir)
        // A name still ahead, and a mark that is not: the mark, and no new one.
        dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        files = try anAside(at: Self.then.addingTimeInterval(3_650 * Self.day), in: dir)
        base = String(try #require(files.first { $0.hasSuffix(".sqlite") }).dropLast(".sqlite".count))
        files.append(base + ".since-" + stamp.string(from: Self.then.addingTimeInterval(-10 * Self.day)))
        try Data().write(to: dir.appendingPathComponent(files[files.count - 1]))
        #expect(Set(try launch(dir, at: Self.then.addingTimeInterval(19 * Self.day))) == Set(files))
        #expect(try launch(dir, at: Self.then.addingTimeInterval(20 * Self.day)).isEmpty)
    }

    // MARK: - Whose files

    @Test("Only its own files go: a second aside of the same second, and one whose name it begins, keep every one of theirs")
    func neverAnothers() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let time = Self.then.addingTimeInterval(-40 * Self.day)
        let first = try anAside(at: time, in: dir)
        let second = try anAside(at: time, attempt: 2, in: dir)
        // The second is counted from later, by its mark: the first goes alone.
        let secondBase = String(second.first { $0.hasSuffix(".sqlite") }!.dropLast(".sqlite".count))
        let mark = secondBase + ".since-" + StoreFile.stamp.string(from: Self.then.addingTimeInterval(-Self.day))
        try Data().write(to: dir.appendingPathComponent(mark))
        #expect(Set(try launch(dir, at: Self.then)) == Set(second + [mark]), "the first took the second's with it: \(first)")
        #expect(StoreFile.asides(in: dir).map(\.base) == [secondBase])
    }

    @Test("One whose index is already gone — a removal cut short — is finished, by what is left under its name")
    func cutShort() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try anAside(at: Self.then.addingTimeInterval(-40 * Self.day), in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(files.first { $0.hasSuffix(".sqlite") }!))
        #expect(try asideFiles(dir).count == 3)
        #expect(try launch(dir, at: Self.then).isEmpty)
    }

    @Test("Of two names no build wrote, one beginning the other, the older goes and takes nothing of the other's")
    func aNameBeginningAnother() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let short = ["index-unreadable-kept.sqlite", "index-unreadable-kept.sqlite-wal"]
        let long = ["index-unreadable-kept.again.sqlite", "index-unreadable-kept.again.sqlite-wal", "index-unreadable-kept.again-limits.json"]
        for name in short + long { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        try FileManager.default.setAttributes([.modificationDate: Self.then.addingTimeInterval(-40 * Self.day)], ofItemAtPath: dir.appendingPathComponent(short[0]).path)
        try FileManager.default.setAttributes([.modificationDate: Self.then], ofItemAtPath: dir.appendingPathComponent(long[0]).path)
        #expect(Set(try launch(dir, at: Self.then.addingTimeInterval(Self.day))) == Set(long))
    }

    @Test("A name no build wrote has no time in it: its thirty days count from when its index was last written")
    func aNameNoBuildWrote() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = dir.appendingPathComponent("index-unreadable-by-hand.sqlite")
        try Data("x".utf8).write(to: index)
        try Data("x".utf8).write(to: dir.appendingPathComponent("index-unreadable-by-hand.sqlite-wal"))
        try FileManager.default.setAttributes([.modificationDate: Self.then], ofItemAtPath: index.path)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(29 * Self.day)).count == 2)
        #expect(try launch(dir, at: Self.then.addingTimeInterval(30 * Self.day)).isEmpty)
    }

    // MARK: - Told

    @Test("Told of it and the store saved, everything under its name goes — the mark of when its days were counted from too")
    func toldTakesTheMark() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try putAside(in: dir)
        let base = String(files.first { $0.hasSuffix(".sqlite") }!.dropLast(".sqlite".count))
        try Data().write(to: dir.appendingPathComponent(base + ".since-" + StoreFile.stamp.string(from: Self.then)))
        StoreFile.told(in: dir)
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: [])
        try file.db.close()
        #expect(try asideFiles(dir).isEmpty)
    }

    @Test("What an earlier build left of one it was told of and cut short on — its index gone, its mark still there — is finished by the next save; one nobody was told of is not")
    func toldAndCutShort() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let told = try anAside(at: Self.then, in: dir)
        let untold = try anAside(at: Self.then, attempt: 2, in: dir).filter { !$0.hasSuffix(".told") }
        try FileManager.default.removeItem(at: dir.appendingPathComponent(told.first { $0.hasSuffix(".sqlite") }!))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(try #require(told.first { $0.hasSuffix(".told") }).replacingOccurrences(of: "Z.told", with: "Z-2.told")))
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: [])
        try file.db.close()
        #expect(try asideFiles(dir) == untold)
    }

    @Test("Removing one takes what lies beside the index first, the mark that the person was told next, and the index last — so one cut short is still found, and finished")
    func theOrder() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var files = try anAside(at: Self.then, in: dir)
        files.append(try #require(files.first { $0.hasSuffix(".told") }).replacingOccurrences(of: ".told", with: ".restored"))
        try Data().write(to: dir.appendingPathComponent(files[files.count - 1]))
        let one = try #require(StoreFile.asides(in: dir).first)
        let order = one.removal
        #expect(Set(order) == Set(files) && order.count == files.count)
        // Which store took its place is known for as long as the person being told is.
        let last: [String] = [".restored", ".told", ".sqlite"].map { one.base + $0 }
        #expect(Array(order.suffix(3)) == last)
        // Cut short just before the index: the index alone is left, and it is still an aside.
        for name in order.dropLast() { try FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        #expect(StoreFile.asides(in: dir).map(\.names) == [[one.base + ".sqlite"]])
        StoreFile.remove(try #require(StoreFile.asides(in: dir).first), in: dir)
        #expect(try asideFiles(dir).isEmpty)
    }
}
