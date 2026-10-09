import FediqoCore
import Foundation
import GRDB
import Synchronization
import Testing
@testable import FediqoPersistence

/// What the person pressed to send is written down beside the posts, as a part of its own.
///
/// What a test can reach: the table and the bytes of the file, a store as the build before this
/// one left it, a build that knows no `v13-unsent`, the saver's own order, and a package taken
/// away and read back. What it cannot: a process killed between two of these writes.
@Suite("A text pressed to send is on disk until it lands or is discarded")
struct UnsentStoreTests {
    private static let mastodon = PackagerFixture.mastodon
    private static let origin = PackagerFixture.origin

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func text(
        _ words: String, minutes: Double = 0, standing: Unsent.Standing = .fresh, answers: NoteKey? = nil
    ) -> Unsent {
        Unsent(
            host: mastodon.host, text: words, audience: answers == nil ? .everyone : .followers,
            answers: answers, root: answers.map { NoteKey(host: "other.example", id: $0.id + "-root") },
            pressedAt: origin.addingTimeInterval(minutes * 60), standing: standing,
            writerID: answers == nil ? nil : "4711", writer: answers == nil ? nil : "@me@one.example",
            askedAt: standing == .asked ? origin.addingTimeInterval(minutes * 60 + 5) : nil
        )
    }

    private func migrations(_ index: URL) throws -> [String] {
        try DatabaseQueue(path: index.path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    /// Every file under `folder` holding `phrase`, by name — the index, a journal, anything.
    private func files(in folder: URL, holding phrase: String) throws -> [String] {
        let needle = Data(phrase.utf8)
        return try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted().filter { name in
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                return false
            }
            return try Data(contentsOf: url).range(of: needle) != nil
        }
    }

    // MARK: - Let go, and not put back

    @Test("A text let go is not held again by a write made of a copy from before the letting go — held at the time or not — while another text is, and a later run holds what its file reads back")
    func notHeldAgainOnceLetGo() async throws {
        let store = ItemStore()
        let text = Self.text("let go, and written late")
        let other = Self.text("another", minutes: 1)
        #expect(await store.hold(text))
        await store.letGo(unsent: text.id)
        let revision = await store.unsentRevision

        var late = text
        late.standing = .asked
        #expect(await !store.hold(late), "a copy from before the letting go")
        #expect(await store.unsentHeld().isEmpty)
        #expect(await store.unsentRevision == revision, "and nothing for a save to write")

        // Let go before its own first write arrived.
        await store.letGo(unsent: other.id)
        #expect(await !store.hold(other))
        let third = Self.text("a third", minutes: 2)
        #expect(await store.hold(third))
        #expect(await store.unsentHeld() == [third])
        #expect(await ItemStore(sources: [], notes: [], unsent: [text]).unsentHeld() == [text], "for the run, and no longer")
    }

    // MARK: - Written and read back

    @Test("Texts are read back by a relaunch in the order pressed, with every character, who each reaches, what it answers and where it stood — and writing them touches no post")
    func writtenAndReadBack() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        let note = PackagerFixture.note("1")
        try await file.save(sources: [Self.mastodon], notes: [note])
        let words = "  two lines\nand «marks» — 100% 🙂 "
        let answer = Self.text(words, minutes: 1, standing: .asked, answers: note.key)
        let post = Self.text("first", standing: .refused)

        try await file.save(unsent: [answer, post])

        let opened = StoreFile.open(at: dir)
        #expect(opened.unsent == [post, answer], "in the order pressed, whatever order they were written in")
        #expect(opened.unsent.last?.text == words)
        #expect(opened.unsent.last?.root == NoteKey(host: "other.example", id: "1-root"))
        #expect(opened.unsent.last?.writerID == "4711" && opened.unsent.last?.writer == "@me@one.example", "who wrote it")
        #expect(opened.unsent.last?.askedAt == Self.origin.addingTimeInterval(65), "and when its source was first asked")
        #expect(opened.unsent.first?.writerID == nil && opened.unsent.first?.askedAt == nil)
        #expect(opened.notes.map(\.id) == ["1"], "the posts are as they were")
        #expect(opened.sources == [Self.mastodon])

        try await #require(opened.file).save(unsent: [])
        #expect(StoreFile.open(at: dir).unsent.isEmpty)
    }

    @Test("A standing this build does not know is read as asked, and a reach it does not know as the narrowest")
    func theCarefulWord() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(unsent: [Self.text("waiting")])
        try await file.db.write { db in
            try db.execute(sql: "UPDATE unsent SET standing = 'queued-somewhere', audience = 'circle'")
        }

        let read = try #require(try file.loadUnsent().first)
        #expect(read.standing == .asked, "it may have landed: never sent again by itself")
        #expect(read.audience == .mentioned)
        #expect(read.text == "waiting")
    }

    // MARK: - The store's format

    /// The twelve steps the last build before texts and notices knew.
    private static let before = [
        "v1-index", "v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked", "v8-revisions",
        "v9-language", "v10-references", "v11-one-holding", "v12-references-only",
    ]

    @Test("A store as the last build before texts and notices left it — every step up to v12-references-only and neither after — opens through both new steps with every source, post and kept mark it held, no text and no notice; it is then this build's")
    func aStoreFromBefore() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        var kept = PackagerFixture.note("2")
        kept.kept = true
        let notes = [PackagerFixture.note("1"), kept, PackagerFixture.note("3", source: PackagerFixture.forum)]
        let sources = [Self.mastodon, PackagerFixture.forum]
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: sources, notes: notes)
            // As that build left it: the two steps since made three tables and changed no other,
            // so without the tables and the word of either step this is its file.
            try await file.db.write { db in
                for table in ["unsent", "notice", "notice_reach"] { try db.execute(sql: "DROP TABLE \(table)") }
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v13-unsent', 'v14-notices')")
            }
        }
        #expect(try migrations(index) == Self.before, "the premise: a store no step after v12-references-only has touched")
        #expect(try tables(index).isDisjoint(with: ["unsent", "notice", "notice_reach"]))

        let opened = StoreFile.open(at: dir)

        #expect(opened.file != nil && opened.setAside == nil && !opened.storeIsNewer && opened.trouble == nil)
        #expect(opened.sources == sources)
        #expect(opened.notes == notes)
        #expect(opened.notes.map(\.kept) == [false, true, false])
        #expect(opened.unsent.isEmpty)
        #expect(opened.notices.isEmpty)
        #expect(try migrations(index) == Self.before + ["v13-unsent", "v14-notices"])
        #expect(try tables(index).isSuperset(of: ["unsent", "notice", "notice_reach"]))

        // And it is this build's from here: a text and a notice are held in it, beside what it held.
        let waiting = Self.text("written since")
        try await #require(opened.file).save(unsent: [waiting])
        let again = StoreFile.open(at: dir)
        #expect(again.unsent == [waiting] && again.notes == notes && again.sources == sources)
    }

    private func tables(_ index: URL) throws -> Set<String> {
        try DatabaseQueue(path: index.path).read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    @Test("A build that knows no v13-unsent sees this build's store as newer, and the store is unchanged for being asked")
    func anOlderBuildRefusesIt() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        try await StoreFile(at: dir).save(unsent: [Self.text("the person believes this is waiting")])
        let before = try Data(contentsOf: index)

        let superseded = try supersededForTheBuildBefore(index)

        #expect(superseded, "an older build would open this store and never show, send or let go of the text")
        #expect(try Data(contentsOf: index) == before)
    }

    /// Asked as `StoreFile` asks: read-only, of a migrator — here one that knows every step this
    /// store records but the last, by name.
    private func supersededForTheBuildBefore(_ index: URL) throws -> Bool {
        var older = DatabaseMigrator()
        for id in try migrations(index) where id != "v13-unsent" { older.registerMigration(id) { _ in } }
        var readOnly = Configuration()
        readOnly.readonly = true
        return try DatabaseQueue(path: index.path, configuration: readOnly).read(older.hasBeenSuperseded)
    }

    @Test("An index that holds only a text waiting to be sent does not hold nothing")
    func aTextIsSomething() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index.sqlite").path
        let file = try StoreFile(at: dir)
        #expect(StoreFile.holdsNothing(indexAt: path) == true)
        try await file.save(unsent: [Self.text("mine")])
        #expect(StoreFile.holdsNothing(indexAt: path) == false)
    }

    // MARK: - Let go

    @Test("A text sent or discarded is not left readable in the file, with nothing else done")
    func letGoLeavesNothing() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let phrase = "persimmon-lantern-unsent"
        let staying = "quince-harbour-unsent"
        // Long enough to fill pages of their own, so letting one go frees whole pages.
        let padding = String(repeating: " ordinary words about the day, and more of them.", count: 120)
        let going = Self.text(phrase + padding)
        let kept = Self.text(staying + padding, minutes: 1)
        let store = ItemStore(sources: [Self.mastodon], notes: [PackagerFixture.note("1")])
        let file = try StoreFile(at: dir)
        let saver = StoreSaver(store: store, file: file)
        await store.hold(going)
        await store.hold(kept)
        try await saver.saveUnsent()
        #expect(try files(in: dir, holding: phrase) == ["index.sqlite"], "the premise: it was written")

        await store.letGo(unsent: going.id)
        try await saver.saveUnsent()

        #expect(try files(in: dir, holding: phrase).isEmpty)
        #expect(try files(in: dir, holding: staying) == ["index.sqlite"])
        #expect(try file.loadUnsent() == [kept])
    }

    // MARK: - The saver

    /// What the saver wrote, in order.
    private final class Wrote: Sendable {
        private let all = Mutex<[String]>([])
        func add(_ what: String) { all.withLock { $0.append(what) } }
        var list: [String] { all.withLock { $0 } }
    }

    @Test("Saving the texts writes them and no post; a save writes them first where they moved, and not again where they did not")
    func aPartOfItsOwn() async throws {
        let store = ItemStore(sources: [Self.mastodon], notes: [PackagerFixture.note("1")])
        let wrote = Wrote()
        let saver = StoreSaver(
            store: store,
            write: { _, notes, _ in wrote.add("posts:\(notes.count)") },
            writeUnsent: { wrote.add("texts:" + $0.map(\.text).joined(separator: ",")) }
        )

        #expect(try await saver.saveUnsent(), "on disk as held, with nothing to write")
        #expect(wrote.list.isEmpty, "nothing moved: a relaunched store holds what the file does")

        await store.hold(Self.text("one"))
        #expect(try await saver.saveUnsent())
        #expect(wrote.list == ["texts:one"], "no post was written for a text")
        try await saver.saveUnsent()
        #expect(wrote.list == ["texts:one"])

        await store.hold(Self.text("two", minutes: 1))
        await store.ingest([PackagerFixture.note("2")])
        try await saver.save()
        #expect(wrote.list == ["texts:one", "texts:one,two", "posts:2"], "the texts go first")
        await store.ingest([PackagerFixture.note("3")])
        try await saver.save()
        #expect(wrote.list.last == "posts:3" && wrote.list.count == 4, "texts that did not move are not written again")
    }

    @Test("A write of the texts that fails throws, and the next one writes them")
    func aFailureIsTriedAgain() async throws {
        struct Full: Error {}
        let store = ItemStore()
        let wrote = Wrote()
        let saver = StoreSaver(store: store, write: nil, writeUnsent: { texts in
            wrote.add("try")
            if wrote.list.count == 1 { throw Full() }
            wrote.add(texts.map(\.text).joined())
        })
        await store.hold(Self.text("kept"))
        await #expect(throws: Full.self) { try await saver.saveUnsent() }
        #expect(try await saver.saveUnsent())
        #expect(wrote.list == ["try", "try", "kept"])
    }

    @Test("A run with no store to write says the texts are not on disk, rather than nothing")
    func nowhereToWrite() async throws {
        let store = ItemStore()
        let saver = StoreSaver(store: store, file: nil)
        await store.hold(Self.text("held in memory only"))
        #expect(try await saver.saveUnsent() == false)
        #expect(try await saver.saveUnsent() == false, "and goes on saying so")
    }

    // MARK: - Carried

    @Test("A take-away carries no text waiting to be sent, and a read back leaves the ones this device holds where they are")
    func notCarried() async throws {
        let from = try await PackagerFixture.PackagerDevice(sources: [Self.mastodon], notes: [PackagerFixture.note("1")])
        let onto = try await PackagerFixture.PackagerDevice(sources: [Self.mastodon], notes: [PackagerFixture.note("9")])
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        let theirs = Self.text("written on the first device")
        let mine = Self.text("written on the second device")
        await from.store.hold(theirs)
        try await #require(from.file).save(unsent: [theirs])
        await onto.store.hold(mine)
        try await #require(onto.file).save(unsent: [mine])

        try await from.packager().takeAway(to: url, key: .password("open sesame"), pictures: false) { _ in }
        try await onto.packager().readBack(url, key: .password("open sesame"), replacing: true) { _ in }

        #expect(await onto.store.snapshot().notes.map(\.id) == ["1"], "the premise: the store was replaced")
        #expect(await onto.store.unsentHeld() == [mine])
        #expect(try StoreFile(at: onto.directory).loadUnsent() == [mine], "two devices would each send it")
        #expect(try #require(from.file).loadUnsent() == [theirs], "and taking away let nothing go")
    }

    @Test("What a read back does to a staged store that carries a text all the same: every text goes, unreadable, and the posts stay")
    func aStagedStoreIsEmptiedOfTexts() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try StoreFile(at: dir)
        try await staged.save(sources: [Self.mastodon], notes: [PackagerFixture.note("1")])
        try await staged.save(unsent: [Self.text("from-somewhere-else-entirely")])

        try staged.dropUnsent()

        #expect(try staged.loadUnsent().isEmpty)
        #expect(try staged.load().notes.map(\.id) == ["1"])
        #expect(try files(in: dir, holding: "from-somewhere-else-entirely").isEmpty)
    }
}
