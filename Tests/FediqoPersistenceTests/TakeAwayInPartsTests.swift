import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// #360, K7: a store held in part is taken away from its file — copied at one moment beside the
/// store, every owed save written first — and the package is what the whole store's take-away
/// would have been.
@Suite("Taking away a store held in part")
struct TakeAwayInPartsTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let sources = [one, two]
    private static let origin = PackagerFixture.origin
    private static let cap = 20
    private static let count = 300
    /// What the rows let go of say, and nothing else does.
    private static let goneWords = "let-go-words-of-a-row"
    private static let unsentWords = "pressed-and-never-sent-words"
    private static let noticeWords = "said-to-whoever-was-signed-in"

    private static func post(_ n: Int, gone: Bool = false) -> Note {
        let source = n % 3 == 0 ? two : one
        var note = Note(
            id: "https://\(source.host)/statuses/\(n)", source: source, author: "Ada", handle: "@ada@\(source.host)",
            body: gone ? "\(goneWords) \(n)" : "a post, number \(n), as it stays",
            postedAt: origin.addingTimeInterval(Double(n) * 60), categories: n % 4 == 0 ? [.home] : [.public],
            statusID: "\(n)", kept: n % 50 == 45
        )
        note.refsDue = n % 7 == 0
        return note
    }

    private static let said = SourceProfile(
        host: one.host, kind: .mastodon, title: "One", summary: "A small place", thumbnail: nil,
        activeMonth: 12, statusLimit: 500, people: nil, posts: nil, registration: .open,
        readsWithoutAccount: true, rules: ["be kind"], asOf: origin
    )

    private static let unsent = Unsent(
        host: one.host, text: unsentWords, audience: .everyone, answers: nil, root: nil,
        pressedAt: origin, standing: .fresh, writerID: nil, writer: nil, askedAt: nil
    )

    private static let reach = NoticeReach(
        host: one.host,
        notices: [Notice(
            source: one, handle: .one(id: "1"), kind: .mention,
            people: [NoticePerson(handle: "@bo@elsewhere.example", name: noticeWords)], post: nil,
            at: origin, newestID: "1", oldestID: "1"
        )],
        before: nil, reached: origin, gathered: false
    )

    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-\(UUID().uuidString)", isDirectory: true)
    }

    /// A file of `count` rows — the first forty of them to be let go — with what each source
    /// said, a text waiting to be sent, a notice, the pages' indexes and the words index built.
    private static func seeded(in dir: URL) async throws -> StoreFile {
        let file = try StoreFile(at: dir)
        try await file.save(
            sources: sources, notes: (0..<count).map { post($0, gone: $0 < 40) },
            said: [said.said(at: origin)]
        )
        try await file.save(unsent: [unsent])
        try await file.save(notices: [reach])
        try await file.makeIndexes()
        try await file.buildWords(chunk: 100, capable: StoreFile.wordsCapable)
        return file
    }

    private static func packager(
        _ dir: URL, file: StoreFile?, store: ItemStore, saver: StoreSaver?, device: PackagerFixture.PackagerDevice,
        free: Int = .max, scratch: URL? = nil
    ) -> StorePackager {
        var packager = StorePackager(
            directory: dir, file: file, store: store, media: device.media, tokens: device.tokens,
            credentials: device.credentials, defaults: device.defaults, device: "a test", appVersion: "0.7.0",
            saver: saver, freeSpace: { _ in free }, rounds: 1000
        )
        if let scratch { packager.scratchRoot = scratch }
        return packager
    }

    /// A folder of the test's own for a take-away's scratch, made, so what is left in it shows.
    private static func scratchRoot() throws -> URL {
        let root = folder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func leftIn(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
    }

    /// Every entry of the package at `url`, and its store written out to `dir` to be opened.
    private static func opened(_ url: URL, into dir: URL) async throws -> (PackageSummary, [String: Data], DatabaseQueue, Data) {
        let reader = try PackageReader(at: url)
        let summary = try reader.open(with: .password("password"))
        var others: [String: Data] = [:]
        var index = Data()
        for try await entry in reader.entries() {
            var whole = Data()
            for try await chunk in entry.chunks { whole.append(chunk) }
            if entry.kind == .store { index = whole } else { others["\(entry.kind)/\(entry.name)"] = whole }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(StoreFile.indexName)
        try index.write(to: path)
        return (summary, others, try DatabaseQueue(path: path.path), index)
    }

    /// Every row `sql` reads, each as its columns' names and values.
    private static func rows(_ db: Database, _ sql: String) throws -> [[String: DatabaseValue]] {
        try Row.fetchAll(db, sql: sql).map { row in
            Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, row[$0] as DatabaseValue) })
        }
    }

    @Test("the package of a store held in part is the whole store's take-away of it: rows, sources, said, kept, and the order they arrived in; with nothing derived, nothing let go, nothing unsent and no notice")
    func sameAsTheWhole() async throws {
        let device = try await PackagerFixture.PackagerDevice(noFile: true)
        let dir = Self.folder()
        let oracleDir = Self.folder()
        let unpacked = Self.folder()
        let scratch = try Self.scratchRoot()
        let url = PackagerFixture.package()
        let oracleURL = PackagerFixture.package()
        defer {
            device.remove()
            for each in [dir, oracleDir, unpacked, scratch, url, oracleURL] { try? FileManager.default.removeItem(at: each) }
        }
        let file = try await Self.seeded(in: dir)
        let opened = try file.loadSources()
        let store = ItemStore(
            sources: opened.sources, said: opened.said, notices: [Self.reach], unsent: [Self.unsent], rows: file, cap: Self.cap
        )
        #expect(store.heldInPart)
        let saver = StoreSaver(store: store, file: file)
        // Owed and not yet saved: forty rows let go, and five new ones arrived.
        let span = Self.origin.addingTimeInterval(-1)..<Self.origin.addingTimeInterval(40 * 60 - 1)
        #expect(await store.letGo(span: span) == 40)
        await store.ingest((Self.count..<Self.count + 5).map { Self.post($0) })

        try await Self.packager(dir, file: file, store: store, saver: saver, device: device, scratch: scratch)
            .takeAway(to: url, key: .password("password"), pictures: false) { _ in }

        // What was owed landed first; the file still holds its texts and notices.
        let landed = try file.load()
        #expect(landed.notes.count == Self.count - 40 + 5)
        #expect(try file.loadUnsent() == [Self.unsent])
        #expect(try file.loadNotices(of: Self.sources).count == 1)
        #expect(try file.keptCount() > 0)

        // The whole store's take-away of the same store: every row in memory, in the file's order.
        let whole = ItemStore(sources: landed.sources, notes: landed.notes, said: landed.said)
        #expect(!whole.heldInPart)
        try await Self.packager(oracleDir, file: nil, store: whole, saver: nil, device: device)
            .takeAway(to: oracleURL, key: .password("password"), pictures: false) { _ in }

        let (summary, entries, copy, bytes) = try await Self.opened(url, into: unpacked.appendingPathComponent("new"))
        let (oracleSummary, oracleEntries, oracle, _) = try await Self.opened(oracleURL, into: unpacked.appendingPathComponent("old"))
        defer { try? copy.close(); try? oracle.close() }
        // A read back settles what is owed a load; the copy has, already.
        try await oracle.write { db in try db.execute(sql: "UPDATE note SET refs_due = 0") }

        #expect(summary.posts == oracleSummary.posts && summary.posts == Self.count - 40 + 5)
        #expect(summary.kept == oracleSummary.kept && (summary.kept ?? 0) > 0)
        #expect(summary.sources == oracleSummary.sources)
        #expect(summary.entryCount == oracleSummary.entryCount)
        // Settings, secrets, the limits' account, and what each source said — a JSON object,
        // whose keys an encoder writes in no fixed order.
        #expect(entries.keys.sorted() == oracleEntries.keys.sorted())
        for (name, data) in entries {
            let other = try #require(oracleEntries[name])
            if name.hasPrefix("profile/") {
                let read = { (data: Data) in try JSONSerialization.jsonObject(with: data) as? NSDictionary }
                #expect(try read(data) == read(other), "\(name)")
            } else {
                #expect(data == other, "\(name)")
            }
        }
        let notes = "SELECT * FROM note ORDER BY rowid"
        let ours = try await copy.read { db in try Self.rows(db, notes) }
        let theirs = try await oracle.read { db in try Self.rows(db, notes) }
        #expect(ours.count == theirs.count)
        #expect(ours == theirs, "row for row, in the order they arrived")
        let sourceRows = "SELECT * FROM source ORDER BY host"
        #expect(try await copy.read { db in try Self.rows(db, sourceRows) } == oracle.read { db in try Self.rows(db, sourceRows) })

        // Nothing derived, nothing waiting, nothing owed, no page free.
        try await copy.read { db in
            let derived = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE name LIKE 'note_words%' OR type = 'trigger'
                OR (type = 'index' AND name NOT LIKE 'sqlite_autoindex%')
                """)
            #expect(derived.isEmpty, "\(derived)")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM unsent") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notice") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notice_reach") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM note WHERE refs_due") == 0)
            #expect(try Int.fetchOne(db, sql: "PRAGMA freelist_count") == 0)
            #expect(try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") == 0)
        }
        // No byte of what was let go, or of what is this device's alone (#292).
        for words in [Self.goneWords, Self.unsentWords, Self.noticeWords] {
            #expect(bytes.range(of: Data(words.utf8)) == nil, "\(words)")
        }
        #expect(try Self.leftIn(scratch).isEmpty, "the copy goes with its scratch")
    }

    @Test("a package taken from a store held in part reads back on a fresh device, every row in its place")
    func readsBack() async throws {
        let device = try await PackagerFixture.PackagerDevice(noFile: true)
        let onto = try await PackagerFixture.PackagerDevice()
        let dir = Self.folder()
        let url = PackagerFixture.package()
        defer { device.remove(); onto.remove(); try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: url) }
        let file = try await Self.seeded(in: dir)
        let opened = try file.loadSources()
        let store = ItemStore(sources: opened.sources, said: opened.said, unsent: [Self.unsent], rows: file, cap: Self.cap)
        let saver = StoreSaver(store: store, file: file)
        try await Self.packager(dir, file: file, store: store, saver: saver, device: device)
            .takeAway(to: url, key: .password("password"), pictures: false) { _ in }

        try await onto.packager().readBack(url, key: .password("password"), replacing: false) { _ in }
        let held = try file.load()
        let reopened = try StoreFile(at: onto.directory).load()
        #expect(reopened.notes.map(\.key) == held.notes.map(\.key))
        #expect(reopened.notes.filter(\.kept).count == held.notes.filter(\.kept).count)
        #expect(reopened.sources == held.sources)
        #expect(reopened.said == held.said)
        #expect(await onto.store.snapshot().notes.count == Self.count)
        #expect(try StoreFile(at: onto.directory).loadUnsent().isEmpty)
    }

    @Test("a take-away of a store held in part is refused for want of room against twice the file, and writes nothing")
    func room() async throws {
        let device = try await PackagerFixture.PackagerDevice(noFile: true)
        let dir = Self.folder()
        let url = PackagerFixture.package()
        defer { device.remove(); try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: url) }
        let file = try await Self.seeded(in: dir)
        let store = ItemStore(sources: Self.sources, rows: file, cap: Self.cap)
        let bytes = file.bytesOnDisk()
        let short = Self.packager(dir, file: file, store: store, saver: nil, device: device, free: bytes * 2 - 1)
        do {
            try await short.takeAway(to: url, key: .password("password"), pictures: false) { _ in }
            Issue.record("taken away with no room")
        } catch PackageFault.noRoom(let needed, let free) {
            #expect(needed >= bytes * 2 && free == bytes * 2 - 1)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let roomy = Self.packager(dir, file: file, store: store, saver: nil, device: device, free: bytes * 3)
        try await roomy.takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a save that cannot be written stops the take-away before anything is copied")
    func owedSaveFails() async throws {
        let device = try await PackagerFixture.PackagerDevice(noFile: true)
        let dir = Self.folder()
        let url = PackagerFixture.package()
        defer { device.remove(); try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: url) }
        let file = try await Self.seeded(in: dir)
        let store = ItemStore(sources: Self.sources, rows: file, cap: Self.cap)
        struct Full: Error {}
        let saver = StoreSaver(store: store, write: { _ in throw Full() })
        await store.ingest([Self.post(Self.count)])
        await #expect(throws: Full.self) {
            try await Self.packager(dir, file: file, store: store, saver: saver, device: device)
                .takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Holds a turn of the saver until it is opened.
    private actor Gate {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            open = true
            for each in waiting { each.resume() }
            waiting = []
        }
    }

    @Test("a take-away cancelled while it waits its turn copies nothing, writes no package, leaves no scratch, and the saver goes on")
    func cancelled() async throws {
        let device = try await PackagerFixture.PackagerDevice(noFile: true)
        let dir = Self.folder()
        let scratch = try Self.scratchRoot()
        let url = PackagerFixture.package()
        defer {
            device.remove()
            for each in [dir, scratch, url] { try? FileManager.default.removeItem(at: each) }
        }
        let file = try await Self.seeded(in: dir)
        let store = ItemStore(sources: Self.sources, unsent: [Self.unsent], rows: file, cap: Self.cap)
        let saver = StoreSaver(store: store, file: file)
        let gate = Gate()
        let holding = Task { try await saver.exclusively { await gate.wait() } }
        let packager = Self.packager(dir, file: file, store: store, saver: saver, device: device, scratch: scratch)
        let taking = Task { try await packager.takeAway(to: url, key: .password("password"), pictures: false) { _ in } }
        // Its scratch is made before it waits for the saver's turn.
        #expect(await met("the take-away has made its scratch", by: taking) {
            (try? Self.leftIn(scratch))?.isEmpty == false
        })
        // Cancelled while the turn before it holds the saver: it ends when its turn comes, and
        // copies nothing then.
        taking.cancel()
        await gate.release()
        try await holding.value
        await #expect(throws: CancellationError.self) { try await taking.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Self.leftIn(scratch).isEmpty)
        // The saver's next turn is not held by the one given up.
        await store.ingest([Self.post(Self.count)])
        try await saver.save()
        #expect(try file.load().notes.count == Self.count + 1)
    }

    @Test("a take-away while the indexes are being made leaves every index made, and the copy holds none of them")
    func duringAnIndexBuild() async throws {
        let device = try await PackagerFixture.PackagerDevice(noFile: true)
        let dir = Self.folder()
        let scratch = try Self.scratchRoot()
        let url = PackagerFixture.package()
        let unpacked = Self.folder()
        defer {
            device.remove()
            for each in [dir, scratch, url, unpacked] { try? FileManager.default.removeItem(at: each) }
        }
        let file = try await Self.seeded(in: dir)
        // An older build's file: none of the indexes this one makes.
        try await file.db.write { db in
            for name in StoreFile.derivedIndexes { try db.execute(sql: "DROP INDEX IF EXISTS \(name)") }
        }
        let store = ItemStore(sources: Self.sources, rows: file, cap: Self.cap)
        let saver = StoreSaver(store: store, file: file)
        let packager = Self.packager(dir, file: file, store: store, saver: saver, device: device, scratch: scratch)
        // As a launch does: the pages' index first, beside the saver, then the rest in its turns.
        let building = Task {
            try await file.makePageIndex()
            try await file.makeIndexes(in: saver)
        }
        let taking = Task { try await packager.takeAway(to: url, key: .password("password"), pictures: false) { _ in } }
        try await taking.value
        try await building.value
        let made = try await file.db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_autoindex%'")
        }
        let wanted = StoreFile.pageIndexes.compactMap { sql -> String? in
            guard let range = sql.range(of: "CREATE INDEX IF NOT EXISTS ") else { return nil }
            return sql[range.upperBound...].split(separator: " ", maxSplits: 1).first.map(String.init)
        }
        #expect(Set(wanted).isSubset(of: Set(made)), "\(Set(wanted).subtracting(made))")
        let (summary, _, copy, _) = try await Self.opened(url, into: unpacked)
        defer { try? copy.close() }
        #expect(summary.posts == Self.count)
        let derived = try await copy.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_autoindex%'")
        }
        #expect(derived == 0)
        #expect(try Self.leftIn(scratch).isEmpty)
    }
}
