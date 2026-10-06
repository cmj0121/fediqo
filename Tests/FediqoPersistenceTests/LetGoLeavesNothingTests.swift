import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// What this device lets go is not left readable on disk (#292).
///
/// **Asked of the bytes, not of the tables.** Every test here reads each file in the store's
/// folder whole — the index and whatever lies beside it — and looks for a phrase a post said,
/// as the bytes a row is written in. A query cannot see a free page; a reader of the file can.
///
/// What a test can reach: the folder's files while the store is open and after it has closed,
/// right after the save that followed the letting go, with nothing else done. What it cannot:
/// what the file system keeps of a file deleted or cut short, which is beneath this app's files.
@Suite("What is let go is not left readable on disk")
struct LetGoLeavesNothingTests {
    private static let mastodon = PackagerFixture.mastodon
    private static let origin = PackagerFixture.origin

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Words long enough that a few hundred posts fill many pages, so letting most of them go
    /// frees whole pages rather than room inside one.
    private static let padding = String(repeating: "ordinary words about the day, and more of them. ", count: 12)

    /// Post `id`, minutes after the origin, saying `phrase`.
    private static func post(_ id: Int, _ phrase: String, earlier: [Wording] = [], host: Source = mastodon) -> Note {
        Note(
            id: "https://\(host.host)/users/ada/statuses/\(id)", source: host, author: "Ada", handle: "@ada",
            body: "\(phrase) \(padding)", postedAt: origin.addingTimeInterval(Double(id) * 60),
            categories: [.public], spoiler: "", statusID: "\(id)",
            editedAt: earlier.isEmpty ? nil : origin.addingTimeInterval(Double(id) * 60 + 30), earlier: earlier
        )
    }

    /// Every file under `folder` holding `phrase`, by name — the index, a journal, anything.
    private func files(in folder: URL, holding phrase: String) throws -> [String] {
        let needle = Data(phrase.utf8)
        let names = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
        return try names.sorted().filter { name in
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                return false
            }
            return try Data(contentsOf: url).range(of: needle) != nil
        }
    }

    private func save(_ store: ItemStore, to file: StoreFile) async throws {
        let snapshot = await store.snapshot()
        try await file.save(sources: snapshot.sources, notes: snapshot.notes, said: snapshot.said)
    }

    /// A store of `count` posts, the first `marked` of them saying `phrase` and the rest
    /// `staying`, saved to a fresh index in `dir`.
    private func held(
        _ count: Int = 400, marked: Int = 360, phrase: String, staying: String = "stays-put-phrase", in dir: URL
    ) async throws -> (ItemStore, StoreFile) {
        let store = ItemStore()
        await store.add(Self.mastodon)
        await store.ingest((1...count).map { Self.post($0, $0 <= marked ? phrase : staying) })
        let file = try StoreFile(at: dir)
        try await save(store, to: file)
        return (store, file)
    }

    // MARK: - How the index is kept

    @Test("The index zeroes what it frees, keeps a rollback journal, and leaves nothing beside itself after a save or a close")
    func howTheIndexIsKept() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let (_, file) = try await held(phrase: "anything", in: dir)
            let (secure, journal) = try await file.db.read { db in
                (try Int.fetchOne(db, sql: "PRAGMA secure_delete"), try String.fetchOne(db, sql: "PRAGMA journal_mode"))
            }
            #expect(secure == 1, "ON, not the system's FAST (2), which leaves the free pages as they were")
            #expect(journal == "delete", "a journal deleted as each save commits")
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["index.sqlite"], "while open")
            try file.db.close()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["index.sqlite"], "after it closed")
        let given = try StoreFile(database: DatabaseQueue())
        #expect(try await given.db.read { try Int.fetchOne($0, sql: "PRAGMA secure_delete") } == 1, "and one handed a queue")
    }

    // MARK: - Let go, saved, and nothing else

    @Test(
        "After posts are let go and what is held is saved, no file of the store holds their words — while it is open, and after it has closed",
        arguments: ["let-go-phrase-7f3a", "放手之後不留下的話"]
    )
    func letGoThenSaved(phrase: String) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, file) = try await held(phrase: phrase, in: dir)
        #expect(try files(in: dir, holding: phrase) == ["index.sqlite"], "the premise: the words are in the file while held")

        let gone = await store.letGo(span: Self.origin..<Self.origin.addingTimeInterval(360 * 60 + 30))
        #expect(gone == 360)
        try await save(store, to: file)

        #expect(try files(in: dir, holding: phrase).isEmpty, "let go and saved, and still readable in the file")
        #expect(try files(in: dir, holding: "stays-put-phrase") == ["index.sqlite"], "what is held is still there to find")
        try file.db.close()
        #expect(try files(in: dir, holding: phrase).isEmpty, "closed, and readable beside or in the file")
        #expect(StoreFile.open(at: dir).notes.count == 40)
    }

    @Test("The same when everything is let go: an index holding nothing holds nothing")
    func everythingLetGo() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, file) = try await held(marked: 400, phrase: "all-of-it-phrase", in: dir)
        await store.letGo(span: Self.origin..<Self.origin.addingTimeInterval(1_000 * 60))
        try await save(store, to: file)
        #expect(try files(in: dir, holding: "all-of-it-phrase").isEmpty)
        #expect(try files(in: dir, holding: "ordinary words about the day").isEmpty, "not its padding either")
    }

    // MARK: - An earlier wording

    @Test("An earlier wording goes with the post that is let go, and one the row itself drops goes while the post stays")
    func anEarlierWording() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let was = Wording(body: "taken-away-wording \(Self.padding)", spoiler: "", until: Self.origin.addingTimeInterval(90))
        let store = ItemStore()
        await store.add(Self.mastodon)
        await store.ingest((1...300).map { Self.post($0, "as-it-reads-now", earlier: [was]) })
        let file = try StoreFile(at: dir)
        try await save(store, to: file)
        #expect(try files(in: dir, holding: "taken-away-wording") == ["index.sqlite"], "the premise")

        // Most of the posts let go, wordings and all.
        await store.letGo(span: Self.origin..<Self.origin.addingTimeInterval(280 * 60 + 30))
        try await save(store, to: file)
        let rest = await store.all()
        #expect(rest.count == 20 && rest.allSatisfy { $0.earlier == [was] }, "the premise: twenty still hold it")
        try await file.save(sources: [Self.mastodon], notes: rest.map { note in
            Self.post(Int(note.statusID!)!, "as-it-reads-now")
        })
        #expect(try files(in: dir, holding: "taken-away-wording").isEmpty, "a wording no row holds is still in the file")
        #expect(try files(in: dir, holding: "as-it-reads-now") == ["index.sqlite"])
    }

    // MARK: - Words too long for one page

    /// A phrase said over and over, through more than twenty thousand bytes: several pages'
    /// worth, so a row holding it spills onto pages of its own.
    private static func long(_ phrase: String) -> String {
        String(repeating: "\(phrase) and more words between each saying of it. ", count: 400)
    }

    @Test("A post several pages long leaves no saying of its words behind, on the pages it spilled onto or anywhere")
    func aLongPost() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.long("spilled-over-phrase").utf8.count > 20_000)
        let store = ItemStore()
        await store.add(Self.mastodon)
        await store.ingest((1...60).map { Self.post($0, $0 <= 50 ? Self.long("spilled-over-phrase") : "stays-put-phrase") })
        let file = try StoreFile(at: dir)
        try await save(store, to: file)
        let pageSize = try await file.db.read { try Int.fetchOne($0, sql: "PRAGMA page_size") ?? 0 }
        #expect(file.bytesOnDisk() > 50 * 20_000 && pageSize < 20_000, "the premise: each long post is more than a page")
        #expect(try files(in: dir, holding: "spilled-over-phrase") == ["index.sqlite"], "the premise")

        await store.letGo(span: Self.origin..<Self.origin.addingTimeInterval(50 * 60 + 30))
        try await save(store, to: file)
        #expect(try files(in: dir, holding: "spilled-over-phrase").isEmpty, "a long post's words are still in the file")
        #expect(try files(in: dir, holding: "stays-put-phrase") == ["index.sqlite"])
    }

    @Test("A long earlier wording dropped from a row that stays leaves no saying of it behind")
    func aLongEarlierWordingDropped() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let was = Wording(body: Self.long("long-gone-wording"), spoiler: "", until: Self.origin.addingTimeInterval(90))
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: (1...40).map { Self.post($0, "as-it-reads-now", earlier: [was]) })
        #expect(try files(in: dir, holding: "long-gone-wording") == ["index.sqlite"], "the premise")
        let full = file.bytesOnDisk()

        try await file.save(sources: [Self.mastodon], notes: (1...40).map { Self.post($0, "as-it-reads-now") })
        #expect(try file.load().notes.count == 40, "every row stays")
        #expect(file.bytesOnDisk() == full, "the premise: the file still has the pages the wordings were on")
        #expect(try files(in: dir, holding: "long-gone-wording").isEmpty, "a wording no row holds is still in the file")
        #expect(try files(in: dir, holding: "as-it-reads-now") == ["index.sqlite"])
    }

    // MARK: - A post its author took back

    enum Gone: String, CaseIterable, Sendable { case withdrawnHere, goneAtItsSource, sourceRemoved }

    @Test(
        "A post its author took back, one gone from its source and let go, and the posts of a source removed leave no word in the file",
        arguments: Gone.allCases
    )
    func takenBack(_ way: Gone) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, file) = try await held(phrase: "taken-back-phrase", in: dir)
        let marked = await store.all().filter { $0.body.hasPrefix("taken-back-phrase") }
        #expect(marked.count == 360)

        switch way {
        case .withdrawnHere:
            for note in marked { await store.forget(note.key) }
        case .goneAtItsSource:
            for note in marked { await store.markGone(note.key) }
            #expect(await store.letGoneGo() == 360)
        case .sourceRemoved:
            let other = Source(host: "other.example", kind: .mastodon)
            await store.add(other)
            await store.ingest([Self.post(900, "stays-put-phrase", host: other)])
            await store.remove(host: Self.mastodon.host)
        }
        try await save(store, to: file)
        #expect(try files(in: dir, holding: "taken-back-phrase").isEmpty, "\(way): its words are still in the file")
        #expect(try files(in: dir, holding: "stays-put-phrase") == ["index.sqlite"])
    }

    // MARK: - A store written before this

    /// How a build before this one freed what it let go.
    enum Older: String, CaseIterable, Sendable {
        /// Rows deleted where nothing at all is zeroed.
        case zeroingNothing
        /// The save such a build made — every row deleted and the ones held written again, in one
        /// transaction — on a connection left at the system's own setting.
        case asTheSystemLeavesIt
    }

    /// An index a build before this one last wrote, having let most of its posts go: opened
    /// first by `open` where `marked`, as this build would have had it before the person went
    /// back a version; with its header saying it was never rebuilt where not.
    private func olderStore(
        phrase: String, in dir: URL, freed way: Older = .zeroingNothing, marked: Bool = false
    ) async throws {
        do {
            let (_, file) = try await held(phrase: phrase, in: dir)
            try file.db.close()
        }
        if marked {
            let opened = StoreFile.open(at: dir)
            #expect(try await opened.file?.db.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == StoreFile.scrubbed)
            try opened.file?.db.close()
        }
        var plain = Configuration()
        plain.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = \(way == .zeroingNothing ? "OFF" : "FAST")")
        }
        let raw = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path, configuration: plain)
        switch way {
        case .zeroingNothing:
            try await raw.write { db in
                try db.execute(sql: "DELETE FROM note WHERE facts LIKE ?", arguments: ["%\(phrase)%"])
            }
        case .asTheSystemLeavesIt:
            try await raw.write { db in
                try db.execute(
                    sql: "CREATE TEMP TABLE staying AS SELECT * FROM note WHERE facts NOT LIKE ?", arguments: ["%\(phrase)%"]
                )
                try db.execute(sql: "DELETE FROM note")
                try db.execute(sql: "INSERT INTO note SELECT * FROM staying")
                try db.execute(sql: "DROP TABLE staying")
            }
        }
        if !marked {
            try await raw.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 0") }
        }
        try raw.close()
    }

    @Test("A store an earlier build left words in is rid of them the first time this build opens it, before anything is saved, and holds what it held")
    func anOlderStoreIsScrubbed() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await olderStore(phrase: "left-behind-phrase", in: dir)
        #expect(try files(in: dir, holding: "left-behind-phrase") == ["index.sqlite"], "the premise: let go, and still in the file")

        let opened = StoreFile.open(at: dir)
        let file = try #require(opened.file)
        #expect(opened.notes.count == 40 && opened.setAside == nil, "what was held is held")
        #expect(try files(in: dir, holding: "left-behind-phrase").isEmpty, "opened by this build, and still in the file")
        #expect(try await file.db.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == StoreFile.scrubbed)
        #expect(try await file.db.read { try Int.fetchOne($0, sql: "PRAGMA freelist_count") } == 0)

        try await file.save(sources: opened.sources, notes: opened.notes, said: opened.said)
        #expect(try files(in: dir, holding: "left-behind-phrase").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["index.sqlite"])
    }

    @Test("An older store with no page free is still rebuilt the first time: what was left inside its pages is gone")
    func anOlderStoreWithNoPageFree() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        do {
            let (_, file) = try await held(marked: 1, phrase: "inside-a-page-phrase", in: dir)
            try file.db.close()
        }
        var plain = Configuration()
        plain.prepareDatabase { db in try db.execute(sql: "PRAGMA secure_delete = OFF") }
        let raw = try DatabaseQueue(path: index.path, configuration: plain)
        try await raw.write { db in try db.execute(sql: "DELETE FROM note WHERE facts LIKE '%inside-a-page-phrase%'") }
        try await raw.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 0") }
        #expect(try await raw.read { try Int.fetchOne($0, sql: "PRAGMA freelist_count") } == 0, "the premise: no page was freed")
        try raw.close()
        #expect(try files(in: dir, holding: "inside-a-page-phrase") == ["index.sqlite"], "the premise: still in the file")

        let opened = StoreFile.open(at: dir)
        #expect(opened.notes.count == 399)
        #expect(try files(in: dir, holding: "inside-a-page-phrase").isEmpty)
    }

    @Test("A store with nothing freed is rebuilt once and not again: a second open changes no byte of it")
    func rebuiltOnce() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        do {
            let (_, file) = try await held(phrase: "anything", in: dir)
            try file.db.close()
        }
        let first = StoreFile.open(at: dir)
        #expect(first.notes.count == 400)
        try first.file?.db.close()
        let before = try Data(contentsOf: index)

        let again = StoreFile.open(at: dir)
        #expect(again.notes.count == 400)
        try again.file?.db.close()
        #expect(try Data(contentsOf: index) == before)
    }

    @Test(
        "Back a version and forward again: what the older build freed after this one had the store is gone at the next open, whatever the header says",
        arguments: Older.allCases
    )
    func aRoundTripThroughAnOlderBuild(freed way: Older) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await olderStore(phrase: "round-trip-phrase", in: dir, freed: way, marked: true)
        #expect(try files(in: dir, holding: "round-trip-phrase") == ["index.sqlite"], "the premise: freed, and still in the file")
        let raw = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        #expect(try await raw.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == StoreFile.scrubbed, "the premise: marked as rebuilt")
        try raw.close()

        let opened = StoreFile.open(at: dir)
        #expect(opened.notes.count == 40 && opened.setAside == nil)
        #expect(try files(in: dir, holding: "round-trip-phrase").isEmpty, "the mark was taken for the file being clean")
        #expect(try files(in: dir, holding: "stays-put-phrase") == ["index.sqlite"])
    }

    @Test("A save that lets posts go leaves the file its size until it is rebuilt; the next open gives the room back, and what is held is held")
    func theRoomComesBackAtTheNextOpen() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, file) = try await held(phrase: "room-phrase", in: dir)
        let full = file.bytesOnDisk()
        await store.letGo(span: Self.origin..<Self.origin.addingTimeInterval(360 * 60 + 30))
        try await save(store, to: file)
        #expect(file.bytesOnDisk() == full, "the file moved under a run that had measured it")
        let heldBytes = file.bytesHeld()
        try file.db.close()

        let opened = StoreFile.open(at: dir)
        let again = try #require(opened.file)
        #expect(opened.notes.count == 40)
        #expect(again.bytesOnDisk() < full / 4, "an open with pages free did not rebuild")
        #expect(again.bytesHeld() <= heldBytes, "and what the rows weigh did not grow")
    }

    @Test("A store that cannot be read is set aside byte for byte as it was found: nothing rebuilds it first")
    func anUnreadableStoreIsNotRewritten() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Free pages and no mark: everything that would have it rebuilt, were it readable.
        try await olderStore(phrase: "unreadable-stores-phrase", in: dir)
        let index = dir.appendingPathComponent("index.sqlite")
        let raw = try DatabaseQueue(path: index.path)
        try await raw.write { db in try db.execute(sql: "UPDATE note SET facts = 'not what a row is'") }
        try raw.close()
        let before = try Data(contentsOf: index)

        let opened = StoreFile.open(at: dir)
        let aside = try #require(opened.setAside, "the premise: it could not be read")
        #expect(try Data(contentsOf: aside) == before, "an index about to be set aside was written first")
        #expect(opened.notes.isEmpty && opened.file != nil)
    }

    @Test("A newer build's store is left byte for byte as found: nothing of this is done to it")
    func aNewerStoreIsUntouched() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await olderStore(phrase: "newer-builds-phrase", in: dir)
        let index = dir.appendingPathComponent("index.sqlite")
        let raw = try DatabaseQueue(path: index.path)
        try await raw.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-the-future')")
        }
        try raw.close()
        let before = try Data(contentsOf: index)

        let opened = StoreFile.open(at: dir)
        #expect(opened.storeIsNewer && opened.file == nil)
        #expect(try Data(contentsOf: index) == before)
    }

    // MARK: - A whole earlier store

    /// What earlier runs left beside the index, each saying `phrase`: the index a read back
    /// replaced and was killed before clearing away, its marker saying so; and a store set aside
    /// because it could not be opened, with its journal and its limits' account. And two things
    /// that are nobody's to drop.
    private func leftovers(saying phrase: String, in dir: URL) throws -> (replaced: String, unreadable: [String]) {
        let manager = FileManager.default
        try manager.createDirectory(at: dir, withIntermediateDirectories: true)
        let words = Data("a whole store, saying \(phrase)".utf8)
        let unreadable = ["index-unreadable-old-limits.json", "index-unreadable-old.sqlite", "index-unreadable-old.sqlite-journal"]
        for name in unreadable { try words.write(to: dir.appendingPathComponent(name)) }
        let aside = dir.appendingPathComponent("incoming-aside-half", isDirectory: true)
        try manager.createDirectory(at: aside, withIntermediateDirectories: true)
        try words.write(to: aside.appendingPathComponent("index.sqlite"))
        try StorePackager.replacedMark.write(to: aside.appendingPathComponent(StorePackager.committingMarker))
        try Data("the person's own".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("[]".utf8).write(to: dir.appendingPathComponent("limits.json"))
        return ("incoming-aside-half", unreadable)
    }

    private func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test("A store a read back replaced goes at the first save that succeeds: not at the open, and nothing else in the folder with it — a store set aside as unreadable least of all")
    func aReplacedStoreGoesAtTheFirstSave() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, first) = try await held(phrase: "anything", in: dir)
        try first.db.close()
        let left = try leftovers(saying: "earlier-runs-phrase", in: dir)
        let rest = (left.unreadable + ["index.sqlite", "limits.json", "notes.txt"]).sorted()
        #expect(try names(in: dir) == ([left.replaced] + rest).sorted())

        let opened = StoreFile.open(at: dir)
        let file = try #require(opened.file)
        #expect(opened.notes.count == 400 && opened.setAside == nil)
        #expect(try names(in: dir) == ([left.replaced] + rest).sorted(), "an open dropped something")

        try await save(store, to: file)
        #expect(try names(in: dir) == rest, "the replaced store, and nothing else")
        #expect(try files(in: dir, holding: "earlier-runs-phrase") == left.unreadable, "the unreadable store is kept, as it was")
    }

    @Test("A save that fails drops nothing")
    func aFailedSaveDropsNothing() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, file) = try await held(phrase: "anything", in: dir)
        _ = try leftovers(saying: "earlier-runs-phrase", in: dir)
        let before = try names(in: dir)

        try file.db.close()
        await #expect(throws: (any Error).self) { try await save(store, to: file) }
        #expect(try names(in: dir) == before, "a save that wrote nothing dropped a store")
        #expect(try files(in: dir, holding: "earlier-runs-phrase").count == 4)
    }

    @Test("Only the store's own save drops it: a take-away, which saves a copy somewhere else, leaves the folder as it is")
    func aTakeAwayDropsNothing() async throws {
        let device = try await PackagerFixture.PackagerDevice(sources: [Self.mastodon], notes: [Self.post(1, "stays-put-phrase")])
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fediqo")
        defer { device.remove(); try? FileManager.default.removeItem(at: package) }
        let left = try leftovers(saying: "earlier-runs-phrase", in: device.directory)
        try await device.packager().takeAway(to: package, key: .password("password"), pictures: false) { _ in }
        #expect(try names(in: device.directory).contains(left.replaced))
    }

    /// The one exception that remains, pinned so that it is a decision and not an accident.
    @Test("A store set aside because it could not be opened is kept byte for byte, through every save: nothing let go afterwards reaches it")
    func anUnopenableStoreIsKept() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let (_, file) = try await held(phrase: "old-stores-phrase", in: dir)
            try file.db.close()
        }
        let raw = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        try await raw.write { db in
            try db.execute(sql: "UPDATE note SET facts = 'not what a row is' WHERE rowid = (SELECT max(rowid) FROM note)")
        }
        try raw.close()
        let before = try Data(contentsOf: dir.appendingPathComponent("index.sqlite"))

        let opened = StoreFile.open(at: dir)
        let aside = try #require(opened.setAside, "the premise: it could not be read")
        let file = try #require(opened.file)
        try await file.save(sources: [Self.mastodon], notes: [Self.post(1, "stays-put-phrase")])
        try await file.save(sources: [Self.mastodon], notes: [])
        #expect(try Data(contentsOf: aside) == before)
        #expect(try files(in: dir, holding: "old-stores-phrase") == [aside.lastPathComponent])
    }

    // MARK: - What it costs

    /// A post of the size a timeline brings: a few sentences, a handle, an address.
    private static func ordinary(_ id: Int) -> Note {
        Note(
            id: "https://\(mastodon.host)/users/user\(id % 500)/statuses/\(id)", source: mastodon,
            author: "User \(id % 500)", handle: "@user\(id % 500)@\(mastodon.host)",
            body: "post-number-\(id)-ends " + String(repeating: "Some ordinary words about the day and what came of it. ", count: 5),
            postedAt: origin.addingTimeInterval(Double(id)), categories: [.public], spoiler: "",
            url: URL(string: "https://\(mastodon.host)/@user\(id % 500)/\(id)"), statusID: "\(id)"
        )
    }

    private static func fastest(of runs: Int = 3, _ work: () async throws -> Void) async rethrows -> Duration {
        var best = Duration.seconds(3_600)
        for _ in 0 ..< runs {
            let clock = ContinuousClock()
            let start = clock.now
            try await work()
            best = min(best, clock.now - start)
        }
        return best
    }

    /// **Measured against itself, not against the clock.** The same store saved on the same
    /// connection with what it frees zeroed (`ON`) and as the system would have left it (`FAST`),
    /// turn about, the faster of three each — so a busy machine slows both, and the line is
    /// drawn on how many times dearer the one is than the other. The figures are printed for a
    /// runner's log; the hand-back for #292 records what they were when it was written.
    ///
    /// 50,000 posts are measured only where `FEDIQO_MEASURE` is set: the figure is worth having
    /// and not worth every run's time.
    @Test(
        "Saving, shrinking and opening a store of the size this app is built for cost little more for zeroing what is freed",
        arguments: ProcessInfo.processInfo.environment["FEDIQO_MEASURE"] == nil ? [10_000] : [10_000, 50_000]
    )
    func whatItCosts(count: Int) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = (1...count).map(Self.ordinary)
        let few = Array(notes.suffix(count / 10))
        let file = try StoreFile(at: dir)
        func mode(_ name: String) async throws {
            try await file.db.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA secure_delete = \(name)") }
        }
        func save(_ rows: [Note]) async throws {
            try await file.save(sources: [Self.mastodon], notes: rows)
        }
        try await save(notes)

        var took: [String: (same: Duration, shrink: Duration)] = [:]
        for name in ["FAST", "ON"] {
            try await mode(name)
            // The ordinary save: the same rows again. And the save after a limit let most go.
            let same = try await Self.fastest { try await save(notes) }
            let shrink = try await Self.fastest {
                try await save(notes)
                try await save(few)
            }
            took[name] = (same, shrink)
            try await save(notes)
        }
        try await mode("ON")
        let size = file.bytesOnDisk()
        let reading = try await Self.fastest { _ = try file.load() }
        // What an older store pays once, at the first open by this build: one rebuild.
        let rebuilding = try await Self.fastest(of: 1) { try await file.compact() }
        let fast = try #require(took["FAST"])
        let on = try #require(took["ON"])
        print("""
        Store of \(count) posts, \(size / 1024) KiB on disk. \
        Save: \(fast.same) as the system leaves it, \(on.same) zeroing what is freed. \
        Save, then save a tenth: \(fast.shrink) and \(on.shrink). Read whole: \(reading). Rebuilt once: \(rebuilding).
        """)
        #expect(on.same / fast.same < 4, "an ordinary save became \(on.same) from \(fast.same)")
        #expect(on.shrink / fast.shrink < 4, "a save after letting go became \(on.shrink) from \(fast.shrink)")

        // And the property, at this size: a tenth held, and nothing of the rest in the file.
        #expect(try files(in: dir, holding: "post-number-1-ends") == ["index.sqlite"], "the premise: held, and in the file")
        try await save(few)
        #expect(try files(in: dir, holding: "post-number-1-ends").isEmpty, "the first post's words are still in the file")
        #expect(try files(in: dir, holding: "post-number-\(count)-ends") == ["index.sqlite"], "and the last, held, is there")
    }
}
