import CryptoKit
import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// What an item refers to, and whether that is still to be asked for (#290, #293), on disk:
/// written with its row, read back by a relaunch, carried by the package, and behind a migration
/// id of its own so a build that knows nothing of them refuses the store.
///
/// The older store is made the way the build before made it — its migrator's ids and the tables
/// as they stood after `v9-language`, frozen here, with rows inserted as raw SQL — so no live
/// record type decides what the old file looked like.
@Suite("What an item refers to, on disk")
struct ReferenceStoreTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let mastodon = PackagerFixture.mastodon

    /// Everything the build before this knew: nine ids, and the tables as `v9-language` left them.
    private static var v9Migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-index") { db in
            try db.create(table: "source") { t in
                t.primaryKey("host", .text)
                t.column("kind", .text).notNull()
                t.column("boards", .text).notNull()
                t.column("said", .text)
                t.column("said_at", .datetime)
            }
            try db.create(table: "note") { t in
                t.column("host", .text).notNull()
                t.column("id", .text).notNull()
                t.primaryKey(["host", "id"])
                t.column("posted_at", .datetime).notNull()
                t.column("categories", .text).notNull()
                t.column("facts", .text).notNull()
                t.column("holding", .text).notNull().defaults(to: "arrived")
                t.column("gone_at", .datetime)
                t.column("kept", .boolean).notNull().defaults(to: false)
                t.column("bookmarked", .boolean)
                t.column("edited_at", .datetime)
                t.column("earlier", .text)
                t.column("language", .text)
            }
        }
        for id in ["v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked", "v8-revisions", "v9-language"] {
            migrator.registerMigration(id) { _ in }
        }
        return migrator
    }

    /// The facts of a row as the build before wrote them, with whatever else it says.
    private static func facts(_ extra: String = "") -> String {
        #"{"attachments":[],"author":"Ada","body":"as written","emojis":[],"handle":"@ada","kind":"mastodon"\#(extra)}"#
    }

    private static let quotedPost = #"{"attachments":[],"author":"Cy","body":"quoted","emojis":[],"handle":"@cy","id":"https://one.example/q7","postedAt":700000000,"statusID":"77"}"#

    /// A store the build before wrote: a post, an answer, a post quoting one it holds a copy of,
    /// a quote still waiting, one that arrived as a boost, and one held aside that answers and quotes.
    private static let rows: [String] = [
        #"INSERT INTO source (host, kind, boards) VALUES ('one.example', 'mastodon', '[]')"#,
        row("1", facts()),
        row("2", facts(#","reply":{"handle":"@bob@two.example","inReplyToId":"41"}"#)),
        row("3", facts(#","quote":{"post":\#(quotedPost),"state":"accepted","statusID":"77"}"#)),
        row("4", facts(#","quote":{"state":"pending"}"#)),
        row("5", facts(#","boostedBy":"Bob","boosterHandle":"@bob@one.example""#)),
        row("6", facts(#","reply":{},"quote":{"state":"accepted","statusID":"88"}"#), holding: "aside", kept: 1),
    ]

    private static func row(_ id: String, _ facts: String, holding: String = "arrived", kept: Int = 0) -> String {
        #"INSERT INTO note VALUES ('one.example', '\#(id)', '2026-09-16 12:00:0\#(id).000', '[{"kind":"home"}]', '\#(facts)', '\#(holding)', NULL, \#(kept), NULL, NULL, NULL, NULL)"#
    }

    private func v9Store(_ statements: [String] = rows) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        try Self.v9Migrator.migrate(queue)
        try queue.write { db in
            for sql in statements { try db.execute(sql: sql) }
        }
        try queue.close()
        return dir
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func cells(_ dir: URL) throws -> [String: (refs: String?, due: Bool?)] {
        try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path).read { db in
            var out: [String: (String?, Bool?)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, refs, refs_due FROM note") {
                out[row["id"]] = (row["refs"], row["refs_due"])
            }
            return out
        }
    }

    private static func note(
        _ id: String, reply: Reply? = nil, quote: Quote? = nil, refs: [Reference]? = nil, refsDue: Bool = false,
        kept: Bool = false
    ) -> Note {
        Note(
            id: id, source: mastodon, author: "Ada", handle: "@ada", body: "hello \(id)",
            postedAt: PackagerFixture.origin.addingTimeInterval(Double(id.count)), categories: [.home], reply: reply,
            spoiler: "", quote: quote, kept: kept, refs: refs, refsDue: refsDue
        )
    }

    // MARK: - An older store

    @Test("The store of the build before opens in place with every post as it was, each given the references its reply and quote state, and none of them owed a load")
    func carriedForward() throws {
        let dir = try v9Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let opened = StoreFile.open(at: dir)

        #expect(opened.file != nil && opened.setAside == nil && !opened.storeIsNewer && opened.trouble == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
        #expect(opened.notes.map(\.id) == ["1", "2", "3", "4", "5", "6"], "in the order they were written")
        #expect(opened.notes.map(\.refs) == [
            [],
            [Reference(kind: .answers, statusID: "41", handle: "@bob@two.example")],
            [Reference(kind: .quotes, id: "https://one.example/q7", statusID: "77", state: .accepted)],
            [Reference(kind: .quotes, state: .pending)],
            [],
            [Reference(kind: .answers), Reference(kind: .quotes, statusID: "88", state: .accepted)],
        ])
        #expect(opened.notes.allSatisfy { !$0.refsDue }, "a post held before there was any asking owes none")
        #expect(opened.notes.allSatisfy { !$0.isReblog }, "and one that arrived as a boost is still the post")
        // And everything else a row said is as it was.
        #expect(opened.notes[1].reply == Reply(handle: "@bob@two.example", inReplyToId: "41"))
        // What it quotes is its reference's to say (#293): where the quote stands and which post.
        // The copy of the quoted post the row once carried is not: that post is its own item,
        // and this store holds none, so the row names it and nothing draws it.
        #expect(opened.notes[2].quote == Quote(state: .accepted, statusID: "77"))
        #expect(opened.notes[2].quotedKey == NoteKey(host: "one.example", id: "https://one.example/q7"))
        #expect(opened.notes[4].boostedBy == "Bob")
        #expect(opened.notes.map(\.kept) == [false, false, false, false, false, true])
        let migrations = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        #expect(migrations == [
            "v1-index", "v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked", "v8-revisions",
            "v9-language", "v10-references", "v11-one-holding", "v12-references-only", "v13-unsent", "v14-notices",
        ])
    }

    @Test("What the migration wrote into each row is this text and no other: the format is the file's, and a later build reads these")
    func theCells() throws {
        let dir = try v9Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        try opened.file?.db.close()
        let cells = try cells(dir)
        #expect(cells["1"]?.refs == "[]")
        #expect(cells["2"]?.refs == #"[{"handle":"@bob@two.example","kind":"answers","statusID":"41"}]"#)
        #expect(cells["3"]?.refs == #"[{"id":"https:\/\/one.example\/q7","kind":"quotes","state":"accepted","statusID":"77"}]"#)
        #expect(cells["4"]?.refs == #"[{"kind":"quotes","state":"pending"}]"#)
        #expect(cells["5"]?.refs == "[]")
        #expect(cells["6"]?.refs == #"[{"kind":"answers"},{"kind":"quotes","state":"accepted","statusID":"88"}]"#)
        #expect(cells.values.allSatisfy { $0.due == false })
    }

    @Test("A save by this build writes each row's references the way the migration did, so a carried row and a saved one are one format")
    func savedAsMigrated() async throws {
        let dir = try v9Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        let migrated = try cells(dir).mapValues(\.refs)
        try await #require(opened.file).save(sources: opened.sources, notes: opened.notes)
        #expect(try cells(dir).mapValues(\.refs) == migrated)
        #expect(StoreFile.open(at: dir).notes == opened.notes)
    }

    /// What `StoreFile.open` made of a store of the build before holding the rows of `rows`
    /// and one more whose facts are `bad`, opened by that build's own reading and by this one's.
    private func judged(_ bad: String) throws -> (StoreFile.Opened, URL) {
        let dir = try v9Store()
        let raw = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        try raw.write { db in
            try db.execute(sql: "INSERT INTO note VALUES ('one.example', '7', '2026-09-16 12:00:07.000', '[]', \(bad), 'arrived', NULL, 0, NULL, NULL, NULL, NULL)")
        }
        try raw.close()
        return (StoreFile.open(at: dir), dir)
    }

    @Test(
        "A row whose facts are not text, or not the JSON a row's facts are, does not stop the migration or trap it: every other row is carried, that one is given nothing, and the load judges the store as it did before this step",
        arguments: ["X'FFFE80FF'", "'not what a row is'", "''", "'[1,2,3]'", "NULL_AS_TEXT"]
    )
    func aRowThatWillNotRead(_ cell: String) throws {
        let bad = cell == "NULL_AS_TEXT" ? "'null'" : cell
        let (opened, dir) = try judged(bad)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The migration ran to its end whatever the row was: the store that could not be read
        // was put aside by the load, with the migration's work in it.
        let judgedFile = opened.setAside ?? dir.appendingPathComponent("index.sqlite")
        let queue = try DatabaseQueue(path: judgedFile.path)
        let migrated = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations").contains("v10-references")
        }
        #expect(migrated, "the migration stopped at a row it could not read")
        let cells = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, refs FROM note ORDER BY id").map { ($0["id"] as String, $0["refs"] as String?) }
        }
        #expect(cells.first { $0.0 == "2" }?.1 == #"[{"handle":"@bob@two.example","kind":"answers","statusID":"41"}]"#, "the rows it could read are carried")
        #expect(cells.first { $0.0 == "7" }?.1 == nil, "and the one it could not is left with nothing written")
        try queue.close()

        // What the load made of a store with that row is what it made of it before this step:
        // such a row has never loaded, so the store is damaged and put aside — by the load.
        #expect(opened.setAside != nil && opened.trouble == .damaged(replacedBy: .empty))
    }

    @Test("The build before sees a store this build opened as newer, and reads it on disk unchanged")
    func olderBuildRefusesIt() throws {
        let dir = try v9Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        let opened = StoreFile.open(at: dir)
        try opened.file?.db.close()
        let before = try Data(contentsOf: index)

        var readOnly = Configuration()
        readOnly.readonly = true
        let superseded = try DatabaseQueue(path: index.path, configuration: readOnly).read(Self.v9Migrator.hasBeenSuperseded)

        #expect(superseded)
        #expect(try Data(contentsOf: index) == before)
    }

    // MARK: - A relaunch

    @Test("Quit and open again: each item refers to what it referred to, and one whose references are still to be asked for still says so")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reblog = [Reference(kind: .reblogs, id: "https://one.example/9", statusID: "9")]
        let notes = [
            Self.note("1"),
            Self.note("22", reply: Reply(handle: "@bob", inReplyToId: "41"), refsDue: true),
            Self.note("333", refs: reblog, refsDue: true, kept: true),
            Self.note("4444", quote: Quote(state: .rejected)),
        ]
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: notes)

        let opened = StoreFile.open(at: dir)

        #expect(opened.notes == notes)
        #expect(opened.notes.map(\.refsDue) == [false, true, true, false])
        #expect(opened.notes[2].refs == reblog && opened.notes[2].isReblog, "a reference no reply or quote states is the row's own")
        let cells = try cells(dir)
        #expect(cells["333"]?.refs == #"[{"id":"https:\/\/one.example\/9","kind":"reblogs","statusID":"9"}]"#)
        #expect(cells["333"]?.due == true && cells["1"]?.due == false)
    }

    @Test(
        "A references cell that will not read costs the row its references and nothing else: the store is not put aside, a post that says something stays — a kept one too — referring to nothing, and nothing of the cell is kept",
        arguments: [
            "not json", "{}", #"[{"kind":"marries","id":"x"}]"#, #"[{"id":"x"}]"#, "", "7", #"["answers"]"#,
            "[" + String(repeating: #"{"kind":"quotes","id":"x"},"#, count: 4_000) + #"{"kind":"quotes"}]"#,
        ]
    )
    func aCellThatWillNotRead(_ cell: String) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let answer = Self.note("1", reply: Reply(handle: "@bob", inReplyToId: "41"))
        let quoting = Note(
            id: "3", source: Self.mastodon, author: "Ada", handle: "@ada", body: "look", postedAt: PackagerFixture.origin,
            categories: [.home], kept: true, refs: [.quotes(.accepted, id: "22", statusID: "22")]
        )
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [answer, Self.note("22"), quoting])
        let index = dir.appendingPathComponent("index.sqlite")
        try await DatabaseQueue(path: index.path).write { db in
            try db.execute(sql: "UPDATE note SET refs = ?", arguments: [cell])
        }

        let opened = StoreFile.open(at: dir)

        #expect(opened.setAside == nil && opened.file != nil && opened.trouble == nil)
        #expect(opened.notes.map(\.id) == ["1", "22", "3"], "every post is still here")
        #expect(opened.notes.map(\.body) == [answer.body, Self.note("22").body, "look"])
        #expect(opened.notes.allSatisfy { $0.refs.isEmpty }, "there is nothing else to read what it referred to from")
        #expect(opened.notes[0].reply == nil && opened.notes[2].quote == nil)
        #expect(opened.notes[2].kept, "and what the person keeps is kept")
        // Saved again, the cell is the references the row has: none.
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: opened.notes)
        #expect(try cells(dir)["1"]?.refs == "[]")
    }

    @Test("A cell is read one reference at a time: an entry that names no kind, or a kind this build does not know, or is no object, is left out alone and the references beside it stand; a name that is not text is no name")
    func oneReferenceAtATime() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [Self.note("1"), Self.note("22")])
        let mixed = #"[{"kind":"marries","id":"x"},{"kind":"answers","statusID":"41","handle":"@bob"},7,{"id":"y"},{"kind":"quotes","state":"accepted","id":"q","statusID":77}]"#
        try await DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path).write { db in
            try db.execute(sql: "UPDATE note SET refs = ? WHERE id = '1'", arguments: [mixed])
        }
        let opened = StoreFile.open(at: dir)
        #expect(opened.trouble == nil && opened.setAside == nil && opened.notes.count == 2)
        #expect(opened.notes.first { $0.id == "1" }?.refs == [
            Reference(kind: .answers, statusID: "41", handle: "@bob"), .quotes(.accepted, id: "q"),
        ])
    }

    @Test("A post whose whole content is its quote — no words of its own — stays for as long as that reference reads, whatever else in its cell did not, and so does an answer with no words; with nothing read of the cell it is no item", arguments: [
        (#"[{"kind":"quotes","state":"accepted","id":"22","statusID":"22"},{"kind":"marries"}]"#, true),
        (#"[7,{"kind":"answers","statusID":"41"}]"#, true),
        (#"[{"kind":"marries"}]"#, false), ("not json", false),
    ])
    func aRowThatIsOnlyItsReference(cell: String, stays: Bool) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wordless = Note(
            id: "3", source: Self.mastodon, author: "Ada", handle: "@ada", body: "", postedAt: PackagerFixture.origin,
            categories: [.home], statusID: "3", kept: true, refs: [.quotes(.accepted, id: "22", statusID: "22")]
        )
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [Self.note("22"), wordless])
        try await DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path).write { db in
            try db.execute(sql: "UPDATE note SET refs = ? WHERE id = '3'", arguments: [cell])
        }
        let opened = StoreFile.open(at: dir)
        #expect(opened.trouble == nil && opened.setAside == nil)
        #expect(opened.notes.map(\.id) == (stays ? ["22", "3"] : ["22"]))
        #expect(opened.notes.first { $0.id == "3" }?.kept != false, "kept, where it stays")
    }

    @Test("A row that says nothing — no words, title, cover, picture or opening post — whose reference will not read is no item and is left out, kept or not; one whose reblog reference did read stays, whatever else in its cell did not", arguments: [
        ("not json", false), (#"[{"kind":"marries","id":"x"}]"#, false), ("[]", true),
        (#"[{"kind":"reblogs","id":"https://one.example/9","statusID":"9"},{"kind":"marries"}]"#, true),
    ])
    func aRowWithNothingToShow(cell: String, stays: Bool) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reblog = Note(
            id: "333", source: Self.mastodon, author: "Bob", handle: "@bob", body: "", postedAt: PackagerFixture.origin,
            categories: [.home], statusID: "900", kept: true,
            refs: [Reference(kind: .reblogs, id: "https://one.example/9", statusID: "9")]
        )
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [Self.note("1"), reblog])
        try await DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path).write { db in
            try db.execute(sql: "UPDATE note SET refs = ? WHERE id = '333'", arguments: [cell])
        }
        let opened = StoreFile.open(at: dir)
        #expect(opened.trouble == nil && opened.setAside == nil, "the store is read either way")
        #expect(opened.notes.map(\.id) == (stays ? ["1", "333"] : ["1"]))
    }

    @Test("A row on disk that says it reblogs another and also holds words, a cover, counts and a reader's mark opens as a reblog with none of them — and is written back that way")
    func aRowThatClaimsBoth() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wordy = Note(
            id: "1", source: Self.mastodon, author: "Ada", handle: "@ada", body: "words of its own",
            postedAt: PackagerFixture.origin, categories: [.home], favourited: true, spoiler: "a cover",
            counts: Counts(favourites: 9), statusID: "900"
        )
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [wordy])
        let index = dir.appendingPathComponent("index.sqlite")
        try await DatabaseQueue(path: index.path).write { db in
            try db.execute(sql: #"UPDATE note SET refs = '[{"kind":"reblogs","id":"https://one.example/9"}]'"#)
        }

        let opened = StoreFile.open(at: dir)

        #expect(opened.trouble == nil && opened.setAside == nil)
        let note = try #require(opened.notes.first)
        #expect(note.isReblog && note.refs == [Reference(kind: .reblogs, id: "https://one.example/9")])
        #expect(note.body.isEmpty && note.spoiler == nil && note.favourited == nil && note.counts == Counts())
        #expect(note.statusID == "900" && note.sendableID == nil && note.author == "Ada")
        try await #require(opened.file).save(sources: opened.sources, notes: opened.notes)
        try opened.file?.db.close()
        #expect(try Data(contentsOf: index).range(of: Data("words of its own".utf8)) == nil, "the words are not left on disk")
        #expect(StoreFile.open(at: dir).notes == opened.notes)
    }

    @Test(
        "A reblog whose references cell will not read is no item: it is left out of the load — never opened as an empty post under the reblog's id — the store is not put aside, every other row is whole, and the next save writes the file without it",
        arguments: [
            "not json", "{}", #"[{"kind":"marries","id":"x"}]"#, #"[{"id":"x"}]"#, "", "NULL",
            "[" + String(repeating: #"{"kind":"reblogs","id":"x"},"#, count: 4_000) + #"{"kind":"reblogs"}]"#,
        ]
    )
    func aReblogWhoseCellWillNotRead(_ cell: String) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reblog = Note(
            id: "r", source: Self.mastodon, author: "Bob", handle: "@bob", body: "", postedAt: PackagerFixture.origin,
            categories: [.home], statusID: "900", kept: true, refs: [Reference(kind: .reblogs, id: "22")]
        )
        let post = Self.note("22")
        let answer = Self.note("333", reply: Reply(handle: "@bob", inReplyToId: "41"))
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [reblog, post, answer])
        let index = dir.appendingPathComponent("index.sqlite")
        try await DatabaseQueue(path: index.path).write { db in
            if cell == "NULL" {
                try db.execute(sql: "UPDATE note SET refs = NULL WHERE id = 'r'")
            } else {
                try db.execute(sql: "UPDATE note SET refs = ? WHERE id = 'r'", arguments: [cell])
            }
        }

        let opened = StoreFile.open(at: dir)

        #expect(opened.setAside == nil && opened.file != nil && opened.trouble == nil)
        #expect(opened.notes == [post, answer], "the reblog is not here as anything, and the others are as they were")
        #expect(!opened.notes.contains { $0.statusID == "900" }, "nothing holds the reblog's id")
        try await #require(opened.file).save(sources: opened.sources, notes: opened.notes)
        try opened.file?.db.close()
        let ids = try await DatabaseQueue(path: index.path).read { db in try String.fetchAll(db, sql: "SELECT id FROM note ORDER BY id") }
        #expect(ids == ["22", "333"], "the save wrote the rows held, and the row is gone from the file")
    }

    @Test(
        "Read back onto a device that keeps only the latest months — from a file, and under a key handed over as a move nearby is — a kept reblog arrives with the post it shows, and a post in the window with the one it quotes; a reblog is brought for nothing that refers to it, and an old post nobody shows is not brought",
        arguments: [PackageKey.password("password"), .direct(SymmetricKey(data: Data(repeating: 7, count: 32)))]
    )
    func readBackSparesWhatIsShown(_ key: PackageKey) async throws {
        let now = Date()
        func made(_ id: String, daysAgo: Double, kept: Bool = false, quote: Quote? = nil, refs: [Reference]? = nil) -> Note {
            Note(
                id: id, source: Self.mastodon, author: "Ada", handle: "@ada", body: refs == nil ? "post \(id)" : "",
                postedAt: now.addingTimeInterval(-daysAgo * 86400), categories: [.home], statusID: id, quote: quote,
                kept: kept, refs: refs
            )
        }
        let shown = made("shown", daysAgo: 400)
        let quoted = made("quoted", daysAgo: 400)
        let notes = [
            shown, made("kept-reblog", daysAgo: 300, kept: true, refs: [Reference(kind: .reblogs, id: "shown")]),
            quoted, made("quoting", daysAgo: 1, quote: Quote(state: .accepted, post: QuotedPost(quoted))),
            made("old-reblog", daysAgo: 300, refs: [Reference(kind: .reblogs, id: "nobody")]),
            made("new-reblog", daysAgo: 1, refs: [Reference(kind: .reblogs, id: "old-reblog")]),
            made("alone", daysAgo: 400),
        ]
        let from = try await Device(sources: [Self.mastodon], notes: notes)
        let onto = try await Device()
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        await onto.store.setRetention(months: 1, from: now)
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }

        try await onto.packager().readBack(url, key: key, replacing: false) { _ in }

        #expect(Set(await onto.store.all().map(\.id)) == ["shown", "kept-reblog", "quoted", "quoting", "new-reblog"])
        #expect(await onto.store.all().first { $0.id == "kept-reblog" }?.kept == true)
    }

    @Test("That a referred post is gone at its source is written in the references cell as one more key, only where it is so, and read back; a cell with a key this build does not know reads as the references it has")
    func goneInTheCell() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gone = [Reference(kind: .answers, statusID: "41", handle: "@bob", gone: true)]
        let notes = [
            Self.note("1", reply: Reply(handle: "@bob", inReplyToId: "41"), refs: gone),
            Self.note("22", reply: Reply(handle: "@bob", inReplyToId: "42")),
        ]
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: notes)
        let written = try cells(dir)
        #expect(written["1"]?.refs == #"[{"gone":true,"handle":"@bob","kind":"answers","statusID":"41"}]"#)
        #expect(written["22"]?.refs == #"[{"handle":"@bob","kind":"answers","statusID":"42"}]"#, "a reference that is not gone is the text it always was")
        #expect(StoreFile.open(at: dir).notes == notes)

        // The post turns up after all: read at launch beside it, the reference is named, and a
        // save writes the cell without the key.
        let found = Note(
            id: "p41", source: Self.mastodon, author: "Bob", handle: "@bob", body: "here after all",
            postedAt: PackagerFixture.origin, categories: [.public], statusID: "41"
        )
        let store = ItemStore(sources: [Self.mastodon], notes: notes + [found])
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: await store.snapshot().notes)
        #expect(try cells(dir)["1"]?.refs == #"[{"handle":"@bob","id":"p41","kind":"answers","statusID":"41"}]"#)
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: notes)

        // A key from a build to come: ignored, and the references it sits among are read.
        try await DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path).write { db in
            try db.execute(sql: #"UPDATE note SET refs = '[{"handle":"@bob","kind":"answers","statusID":"42","seen":7,"later":{"a":1}}]' WHERE id = '22'"#)
            try db.execute(sql: #"UPDATE note SET refs = '[{"gone":"yes","kind":"answers","statusID":"41"}]' WHERE id = '1'"#)
        }
        let opened = StoreFile.open(at: dir)
        #expect(opened.trouble == nil && opened.setAside == nil)
        #expect(opened.notes.first { $0.id == "22" }?.refs == [Reference(kind: .answers, statusID: "42", handle: "@bob")])
        // A `gone` that is no yes-or-no is not a yes: the reference stands as the cell says it, not gone.
        #expect(opened.notes.first { $0.id == "1" }?.refs == [Reference(kind: .answers, statusID: "41")])
    }

    @Test("A cell that reads but says more than an item may hold, or names longer than a name is, is held to the bounds every item is")
    func aCellPastTheBounds() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await StoreFile(at: dir).save(sources: [Self.mastodon], notes: [Self.note("1"), Self.note("22")])
        let many = "[" + (0 ..< 40).map { #"{"kind":"quotes","state":"accepted","id":"https://one.example/\#($0)"}"# }.joined(separator: ",") + "]"
        let long = #"[{"kind":"answers","statusID":"\#(String(repeating: "x", count: 5_000))"},{"kind":"answers","statusID":"41"}]"#
        try await DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path).write { db in
            try db.execute(sql: "UPDATE note SET refs = ? WHERE id = '1'", arguments: [many])
            try db.execute(sql: "UPDATE note SET refs = ? WHERE id = '22'", arguments: [long])
        }
        let opened = StoreFile.open(at: dir)
        #expect(opened.notes[0].refs.count == Reference.most)
        #expect(opened.notes[1].refs == [Reference(kind: .answers, statusID: "41")])
    }

    // MARK: - Taken away, and moved nearby

    @Test(
        "Taken away and read back — by a file's password, and by a key handed over as a move nearby is; onto a device with a store open, and onto one where the package's index is moved into place — each item's references came with it, and no row arrives still owing a load",
        arguments: [PackageKey.password("password"), .direct(SymmetricKey(data: Data(repeating: 7, count: 32)))], [false, true]
    )
    func ridesThePackage(_ key: PackageKey, movedIntoPlace: Bool) async throws {
        let reblog = [Reference(kind: .reblogs, id: "https://one.example/9")]
        let notes = [
            Self.note("1", reply: Reply(handle: "@bob", inReplyToId: "41"), refsDue: true),
            Self.note("22", refs: reblog, refsDue: true),
            Self.note("333"),
        ]
        let from = try await Device(sources: [Self.mastodon], notes: notes)
        let onto = try await Device(noFile: movedIntoPlace)
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        #expect(StoreFile.open(at: from.directory).notes.filter(\.refsDue).count == 2, "the premise: the package's store has rows still due")

        try await onto.packager().readBack(url, key: key, replacing: false) { _ in }

        let arrived = await onto.store.all().sorted { $0.id.count < $1.id.count }
        #expect(arrived.map(\.refs) == notes.map(\.refs))
        #expect(arrived.allSatisfy { !$0.refsDue }, "what another device still owed came to be asked for here")
        // And on disk, before any save of this run's: the next launch owes none either.
        let cells = try cells(onto.directory)
        #expect(cells.count == 3 && cells.values.allSatisfy { $0.due == false }, "the index read back still says its rows are due")
        #expect(cells["22"]?.refs == #"[{"id":"https:\/\/one.example\/9","kind":"reblogs"}]"#)
    }

    @Test("A package the build before took away is read back by this one, its rows carried forward as an opened store's are")
    func anOlderPackage() async throws {
        let old = try v9Store()
        let onto = try await Device()
        let url = PackagerFixture.package()
        defer { try? FileManager.default.removeItem(at: old); onto.remove(); try? FileManager.default.removeItem(at: url) }
        let index = try Data(contentsOf: old.appendingPathComponent("index.sqlite"))
        let settings = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let summary = PackageSummary(
            sources: [.init(host: Self.mastodon.host, kind: .mastodon)], posts: 6, timelines: 0,
            takenAt: PackagerFixture.origin, withPictures: false, bytes: index.count + settings.count,
            hasSecrets: false, device: "an older build", appVersion: "0.0.9", entryCount: 3
        )
        let writer = try PackageWriter(to: url, key: .password("password"), summary: summary, rounds: 1000)
        for (kind, name, data) in [
            (PackageFormat.Entry.Kind.store, "index.sqlite", index), (.settings, "settings", settings), (.secrets, "secrets", Data()),
        ] {
            var offset = 0
            try writer.add(kind, name: name, bytes: data.count) { most in
                guard offset < data.count else { return nil }
                let end = min(data.count, offset + most)
                defer { offset = end }
                return data[offset..<end]
            }
        }
        try writer.finish()

        try await onto.packager().readBack(url, key: .password("password"), replacing: false) { _ in }
        let now = await onto.store.all()
        #expect(now.count == 6)
        #expect(now.first { $0.id == "2" }?.refs == [Reference(kind: .answers, statusID: "41", handle: "@bob@two.example")])
        #expect(now.allSatisfy { !$0.refsDue })
    }
}
