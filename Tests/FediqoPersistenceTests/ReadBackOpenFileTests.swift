@testable import FediqoCore
import Foundation
import GRDB
import os
import Testing
@testable import FediqoPersistence

/// #360, K8: a read back into a run that has its file open copies the package's file into it
/// page by page, sets what it held aside by `VACUUM INTO` for the undo, and reads no row into
/// memory — giving the file the whole-store path gave it, and leaving nothing of what it
/// replaced in the folder.
@Suite("A read back into an open file")
struct ReadBackOpenFileTests {
    typealias Device = PackagerFixture.PackagerDevice
    static let mastodon = PackagerFixture.mastodon
    static let forum = PackagerFixture.forum
    static let key = PackageKey.password("password")

    static func note(_ id: String, source: Source = mastodon, body: String? = nil) -> Note {
        PackagerFixture.note(id, source: source, body: body)
    }

    /// A store held in part over `device`'s file, with a saver of its own, as the app runs one —
    /// a text waiting to be sent and a notice held, both written — and a packager over the two.
    struct Run {
        let store: ItemStore
        let saver: StoreSaver
        let file: StoreFile
        let packager: StorePackager
    }

    static func run(on device: Device) async throws -> Run {
        let file = try #require(device.file)
        let (sources, said) = try file.loadSources()
        let store = ItemStore(sources: sources, said: said, rows: file)
        await store.hold(Unsent(host: mastodon.host, text: "a text of this device's", audience: .everyone))
        await store.hold(NoticeReach(host: mastodon.host, before: "9", gathered: true))
        let saver = StoreSaver(store: store, file: file)
        try await saver.save()
        let packager = StorePackager(
            directory: device.directory, file: file, store: store, media: device.media, tokens: device.tokens,
            credentials: device.credentials, defaults: device.defaults, device: "a test", appVersion: "0.7.0",
            saver: saver, freeSpace: { _ in .max }, rounds: 1000
        )
        return Run(store: store, saver: saver, file: file, packager: packager)
    }

    /// A device whose store has every kind of row a package carries: a kept one, a bookmarked
    /// one, one still owing a load, a reblog and what it reblogs, a forum's, and what a source
    /// said of itself.
    static func source() async throws -> Device {
        let owing = Note(
            id: "1", source: mastodon, author: "Ada", handle: "@ada", body: "a reply still owed",
            postedAt: PackagerFixture.origin, categories: [.home],
            refs: [Reference(kind: .answers, statusID: "41", handle: "@bob")], refsDue: true
        )
        var kept = note("2", body: "kept")
        kept.kept = true
        let marked = Note(
            id: "3", source: mastodon, author: "Ada", handle: "@ada", body: "bookmarked",
            postedAt: PackagerFixture.origin, categories: [.home], bookmarked: true
        )
        let reblog = Note(
            id: "4", source: mastodon, author: "Bob", handle: "@bob", body: "", postedAt: PackagerFixture.origin,
            categories: [.home], refs: [Reference(kind: .reblogs, id: "3")]
        )
        let device = try await Device(
            sources: [mastodon, forum], notes: [owing, kept, marked, reblog, note("5", source: forum, body: "a forum's")]
        )
        await device.store.said(PackagerFixture.said, at: PackagerFixture.origin)
        return device
    }

    /// Every row of `table` as the file holds it, `rowid` first, in `order`.
    static func rows(_ file: StoreFile, _ table: String, order: String = "rowid") throws -> [[DatabaseValue]] {
        try file.db.read { db in
            try Row.fetchAll(db, sql: "SELECT rowid, * FROM \(table) ORDER BY \(order)").map { Array($0.databaseValues) }
        }
    }

    /// The read back as it was before (#247, #357): the staged file read whole, written into the
    /// open file in place of every row, and laid into the store — reconstructed here, the path
    /// itself having gone.
    static func readBackWhole(_ url: URL, onto run: Run, in folder: URL) async throws {
        let (staged, said) = try await stage(url, in: folder)
        let loaded = try staged.load()
        try staged.db.close()
        let contents = (sources: loaded.sources, notes: loaded.notes, said: said.isEmpty ? loaded.said : said)
        try await run.saver.exclusively {
            try await run.file.save(sources: contents.sources, notes: contents.notes, said: contents.said, replacingNotices: [])
            await run.store.replace(sources: contents.sources, notes: contents.notes, said: contents.said)
        }
        try await run.saver.save()
    }

    /// The package's store staged in `folder` as a read back stages it, and what its profile
    /// entries said.
    static func stage(_ url: URL, in folder: URL) async throws -> (StoreFile, [SourceProfile]) {
        let reader = try PackageReader(at: url)
        _ = try reader.open(with: key)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var said: [SourceProfile] = []
        for try await entry in reader.entries() {
            switch entry.kind {
            case .store:
                let handle = try Guarded.makeFile(at: folder.appendingPathComponent(StoreFile.indexName))
                for try await chunk in entry.chunks { try handle.write(contentsOf: chunk) }
                try handle.close()
            case .profile:
                var data = Data()
                for try await chunk in entry.chunks { data.append(chunk) }
                let wire = try JSONDecoder().decode(StorePackager.ProfileWire.self, from: data)
                if let profile = wire.profile(host: entry.name) { said.append(profile) }
            default:
                for try await _ in entry.chunks {}
            }
        }
        let staged = try StoreFile(at: folder)
        try staged.settleReferences()
        try staged.dropUnsent()
        try staged.dropNotices()
        return (staged, said)
    }

    @Test("The same package read back by copying its file in, and by the whole-store path it replaces, leaves the same file row by row")
    func sameAsTheWholeStorePath() async throws {
        let from = try await Self.source()
        let byCopy = try await Device(sources: [Self.mastodon], notes: (1...6).map { Self.note("old-\($0)") })
        let byRows = try await Device(sources: [Self.mastodon], notes: (1...6).map { Self.note("old-\($0)") })
        let url = PackagerFixture.package()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            from.remove()
            byCopy.remove()
            byRows.remove()
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: scratch)
        }
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        let copying = try await Self.run(on: byCopy)
        let whole = try await Self.run(on: byRows)

        try await copying.packager.readBack(url, key: Self.key, replacing: true) { _ in }
        try await copying.saver.save()
        try await Self.readBackWhole(url, onto: whole, in: scratch)

        let note = try Self.rows(whole.file, "note")
        #expect(note.count == 5, "the premise: every row of the package")
        #expect(try Self.rows(copying.file, "note") == note)
        #expect(try Self.rows(copying.file, "source", order: "host") == Self.rows(whole.file, "source", order: "host"))
        for table in ["notice", "notice_reach"] {
            #expect(try Self.rows(copying.file, table) == Self.rows(whole.file, table), "\(table)")
        }
        // Each device's own text, under a name of its own: the same text, kept as it was.
        #expect(try copying.file.loadUnsent().map(\.text) == ["a text of this device's"], "the texts waiting stay the file's")
        #expect(try copying.file.loadUnsent().map(\.text) == whole.file.loadUnsent().map(\.text))
        #expect(try copying.file.loadUnsent().map(\.id) == (await copying.store.unsentHeld()).map(\.id))
        #expect(try await copying.file.db.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM note WHERE refs_due") } == 0)
        // And the store over it holds the same as the one given every row, once each is read.
        #expect(await copying.store.sources() == whole.store.sources())
        let keys = note.compactMap { row -> NoteKey? in
            guard let host = String.fromDatabaseValue(row[1]), let id = String.fromDatabaseValue(row[2]) else { return nil }
            return NoteKey(host: host, id: id)
        }
        #expect(keys.count == 5)
        #expect(await copying.store.notes(keys) == whole.store.notes(keys))
    }

    @Test("A store held in part is given no row by a read back: its pool and what it answered for go, pages read the file it copied in, and what a launch makes beside the tables is made")
    func noRowLaidIn() async throws {
        let from = try await Self.source()
        let onto = try await Device(sources: [Self.mastodon], notes: (1...40).map { Self.note("old-\($0)") })
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        let run = try await Self.run(on: onto)
        _ = await run.store.notes((1...40).map { Self.note("old-\($0)").key })
        #expect(await run.store.pooled == 40, "the premise: the pool holds rows of the store replaced")
        let told = OSAllocatedUnfairLock(initialState: 0)
        run.file.onWordsLeftDue { told.withLock { $0 += 1 } }

        try await run.packager.readBack(url, key: Self.key, replacing: true) { _ in }
        #expect(await run.store.pooled == 0)
        #expect(await run.store.lookedCount == 0)
        #expect(await run.store.sources().map(\.host) == [Self.mastodon.host, Self.forum.host])
        #expect(await run.store.unsentHeld().map(\.text) == ["a text of this device's"])
        #expect(try await run.file.db.read(StoreFile.hasPageIndex), "the pages' index made again")
        #expect(told.withLock { $0 } == 1, "the words builder set going")
        // A page reads the package's rows, and lays them in.
        let definition = TimelineDefinition(name: "All", rules: [])
        let sources = await run.store.sources()
        let all = PageQuery(timeline: definition.id, generation: 1, compiled: CompiledTimeline(definition, sources: sources))
        let page = try await run.store.paged { try await run.file.page(all, .newest) }
        #expect(Set(page.rows.map(\.note.id)) == ["1", "2", "3", "4", "5"])
        #expect(await run.store.pooled >= 5)
        // Nothing of the store replaced is owed or answered for: the next save writes no row.
        let (changes, _) = await run.store.takeChanges()
        #expect(changes.upserts.isEmpty && changes.deletes.isEmpty)
        // Nothing is left beside the index but the index.
        let left = try FileManager.default.contentsOfDirectory(atPath: onto.directory.path)
        #expect(!left.contains { $0.hasPrefix("incoming-") || $0.hasPrefix(StorePackager.undoAsidePrefix) || $0.hasSuffix("-journal") })
    }

    /// Every file under `folder` that holds `phrase`, by name.
    static func files(in folder: URL, holding phrase: String) throws -> [String] {
        let needle = Data(phrase.utf8)
        return try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted().filter { name in
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return false }
            return try Data(contentsOf: url).range(of: needle) != nil
        }
    }

    @Test("No word of a row a read back replaced is left in the folder once it commits, nor of a row it brought once it is undone (#292)", arguments: [true, false])
    func nothingLeft(undone: Bool) async throws {
        let from = try await Device(sources: [Self.mastodon], notes: (1...30).map { Self.note("new-\($0)", body: "zqxbrought \($0)") })
        let onto = try await Device(sources: [Self.mastodon], notes: (1...300).map { Self.note("old-\($0)", body: "zqxreplaced \($0)") })
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        let run = try await Self.run(on: onto)
        #expect(try Self.files(in: onto.root, holding: "zqxreplaced") == ["Fediqo/index.sqlite"], "the premise")
        if undone {
            // The step after the index refuses: the index is put back.
            let blocking = onto.directory.appendingPathComponent(LimitAccountFile.name, isDirectory: true)
            try FileManager.default.createDirectory(at: blocking, withIntermediateDirectories: true)
            try Data().write(to: blocking.appendingPathComponent("in the way"))
            await #expect(throws: (any Error).self) {
                try await run.packager.readBack(url, key: Self.key, replacing: true) { _ in }
            }
            #expect(!run.packager.owesUndo)
            try await run.saver.save()
            #expect(try run.file.rowCount() == 300)
            #expect(try Self.files(in: onto.root, holding: "zqxbrought").isEmpty)
            #expect(try run.file.loadUnsent().map(\.text) == ["a text of this device's"])
        } else {
            try await run.packager.readBack(url, key: Self.key, replacing: true) { _ in }
            try await run.saver.save()
            #expect(try run.file.rowCount() == 30)
            #expect(try Self.files(in: onto.root, holding: "zqxreplaced").isEmpty)
            #expect(try Self.files(in: onto.root, holding: "zqxbrought") == ["Fediqo/index.sqlite"])
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: onto.directory.path)
        #expect(!left.contains { $0.hasPrefix("incoming-") || $0.hasPrefix(StorePackager.undoAsidePrefix) })
    }
}
