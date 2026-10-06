import CryptoKit
import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// References are all a row says of what it refers to, on disk (#293): the store of the build
/// before — which wrote, beside each row's references, the reply and the quote they came from
/// and a copy of the quoted post — opens with every row referring to what it did; what the
/// facts said and the references did not is made good, once; the reply, the quote and the copy
/// are gone from the file; and the build before refuses what this one wrote.
///
/// The older store is made the way the build before made it — its migrator's ids and the tables
/// as they stood after `v11-one-holding`, frozen here, with rows inserted as raw SQL and their
/// facts spelled as that build spelled them — so no live record type decides what the old file
/// looked like.
@Suite("References are all a row says of what it refers to, on disk")
struct ReferencesOnlyStoreTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let mastodon = PackagerFixture.mastodon
    private static let host = "one.example"

    /// Everything the build before this knew: eleven ids, and the tables as `v11-one-holding` left them.
    private static var v11Migrator: DatabaseMigrator {
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
                t.column("gone_at", .datetime)
                t.column("kept", .boolean).notNull().defaults(to: false)
                t.column("bookmarked", .boolean)
                t.column("edited_at", .datetime)
                t.column("earlier", .text)
                t.column("language", .text)
                t.column("refs", .text)
                t.column("refs_due", .boolean).notNull().defaults(to: false)
            }
        }
        for id in [
            "v2-categories", "v3-holding", "v4-gone", "v5-said", "v6-kept", "v7-bookmarked", "v8-revisions", "v9-language",
            "v10-references", "v11-one-holding",
        ] {
            migrator.registerMigration(id) { _ in }
        }
        return migrator
    }

    /// A row's facts as the build before wrote them: what every row has, and `more` of its keys.
    private static func facts(_ body: String, _ more: String = "") -> String {
        #"{"attachments":[],"author":"Ada","body":"\#(body)","emojis":[],"handle":"@ada@one.example","kind":"mastodon","statusID":"s\#(body.count)"\#(more)}"#
    }

    /// The quoted post's copy, as it was kept inside a quoting row's facts.
    private static let copy = #"{"attachments":[{"alt":"a cat","kind":"image","url":"https://one.example/cat.png"}],"author":"Cyd","body":"the quoted words","emojis":[],"handle":"@cyd@one.example","id":"https://one.example/q7","postedAt":721692800000,"sensitive":true,"spoiler":"a cover","statusID":"7","quotingState":"accepted","quotingStatusID":"3"}"#

    private static let rows: [(id: String, facts: String, refs: String?, kept: Int)] = [
        ("1", facts("plain"), "[]", 0),
        // A reply whose reference a load has since named.
        ("2", facts("a reply", #","reply":{"handle":"@bob@one.example","inReplyToId":"41"}"#),
         #"[{"handle":"@bob@one.example","id":"https://one.example/p41","kind":"answers","statusID":"41"}]"#, 0),
        // A quoting post, and the post it quotes held as the item it is.
        ("3", facts("quoting", #","quote":{"post":\#(copy),"state":"accepted","statusID":"7"}"#),
         #"[{"id":"https://one.example/q7","kind":"quotes","state":"accepted","statusID":"7"}]"#, 0),
        ("https://one.example/q7",
         #"{"attachments":[{"alt":"a cat","kind":"image","url":"https://one.example/cat.png"}],"author":"Cyd","body":"the quoted words","emojis":[],"handle":"@cyd@one.example","kind":"mastodon","sensitive":true,"spoiler":"a cover","statusID":"7","quote":{"state":"accepted","statusID":"3"}}"#,
         #"[{"kind":"quotes","state":"accepted","statusID":"3"}]"#, 0),
        // What the facts say and the cell does not: a cell written short, one that will not
        // read, and one that is missing.
        ("4", facts("short", #","reply":{"inReplyToId":"42"},"quote":{"state":"pending"}"#), "[]", 1),
        ("5", facts("unreadable", #","quote":{"post":\#(copy),"state":"accepted"}"#), "not json", 0),
        ("6", facts("missing", #","reply":{"handle":"@bob@one.example"}"#), nil, 0),
        // A reply whose post its source said is gone.
        ("7", facts("gone", #","reply":{"inReplyToId":"50"}"#), #"[{"gone":true,"kind":"answers","statusID":"50"}]"#, 0),
        // A reblog: no words, and its one reference.
        ("https://one.example/users/bob/statuses/900/activity",
         #"{"attachments":[],"author":"Bob","body":"","emojis":[],"handle":"@bob@one.example","kind":"mastodon","statusID":"900"}"#,
         #"[{"id":"https://one.example/q7","kind":"reblogs","statusID":"7"}]"#, 1),
        // A post that arrived as a reblog before a reblog was an item: its legacy word stays.
        ("8", facts("legacy", #","boostedBy":"Bob","boosterHandle":"@bob@one.example""#), "[]", 0),
        // A quoting post whose quoted post is no longer held: only the copy had its words.
        ("9", facts("orphan", #","quote":{"post":\#(copy.replacingOccurrences(of: "q7", with: "q9").replacingOccurrences(of: "the quoted words", with: "words let go")),"state":"accepted","statusID":"9"}"#),
         #"[{"id":"https://one.example/q9","kind":"quotes","state":"accepted","statusID":"9"}]"#, 0),
    ]

    private func v11Store() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path)
        try Self.v11Migrator.migrate(queue)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO source (host, kind, boards) VALUES ('one.example', 'mastodon', '[]')")
            for (place, row) in Self.rows.enumerated() {
                try db.execute(
                    sql: "INSERT INTO note (host, id, posted_at, categories, facts, kept, refs) VALUES ('one.example', ?, ?, '[]', ?, ?, ?)",
                    arguments: [row.id, "2026-09-16 12:00:\(String(format: "%02d", place)).000", row.facts, row.kept, row.refs]
                )
            }
        }
        try queue.close()
        return dir
    }

    private func cells(_ index: URL) throws -> [String: (facts: [String: Any], refs: String?)] {
        try DatabaseQueue(path: index.path).read { db in
            var cells: [String: (facts: [String: Any], refs: String?)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, CAST(facts AS TEXT) AS facts, refs FROM note") {
                let facts = try JSONSerialization.jsonObject(with: Data((row["facts"] as String).utf8)) as? [String: Any]
                cells[row["id"]] = (facts ?? [:], row["refs"])
            }
            return cells
        }
    }

    private func supersededForTheBuildBefore(_ index: URL) throws -> Bool {
        var readOnly = Configuration()
        readOnly.readonly = true
        return try DatabaseQueue(path: index.path, configuration: readOnly).read(Self.v11Migrator.hasBeenSuperseded)
    }

    private static func key(_ id: String) -> NoteKey { NoteKey(host: host, id: id) }

    // MARK: - An older store

    @Test("The store of the build before opens in place with every row it held, each referring to what it did: a name a load found and the word that a post is gone are kept, and what a row's facts said and its references did not is made good")
    func carriedForward() async throws {
        let dir = try await v11Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let opened = StoreFile.open(at: dir)

        #expect(opened.file != nil && opened.setAside == nil && !opened.storeIsNewer && opened.trouble == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed)
        #expect(opened.notes.map(\.id) == Self.rows.map(\.id), "every row, in the order they were written")
        let refs = Dictionary(uniqueKeysWithValues: opened.notes.map { ($0.id, $0.refs) })
        #expect(refs["1"] == [])
        #expect(refs["2"] == [Reference(kind: .answers, id: "https://one.example/p41", statusID: "41", handle: "@bob@one.example")])
        #expect(refs["3"] == [.quotes(.accepted, id: "https://one.example/q7", statusID: "7")])
        #expect(refs["https://one.example/q7"] == [.quotes(.accepted, statusID: "3")])
        #expect(refs["4"] == [.answers("42"), .quotes(.pending)], "a cell written short is given what the facts say")
        #expect(refs["5"] == [.quotes(.accepted, id: "https://one.example/q7", statusID: "7")], "and so is one that would not read")
        #expect(refs["6"] == [.answers(nil, to: "@bob@one.example")], "and one that was missing")
        #expect(refs["7"] == [Reference(kind: .answers, statusID: "50", gone: true)])
        #expect(refs["https://one.example/users/bob/statuses/900/activity"] == [Reference(kind: .reblogs, id: "https://one.example/q7", statusID: "7")])
        #expect(refs["8"] == [] && opened.notes.first { $0.id == "8" }?.boostedBy == "Bob")
        #expect(opened.notes.map(\.kept) == Self.rows.map { $0.kept == 1 })
        #expect(opened.notes.allSatisfy { !$0.refsDue }, "and nothing is asked for on account of this")
        // What it answers and quotes is read off the references.
        #expect(opened.notes[1].reply == Reply(handle: "@bob@one.example", inReplyToId: "41"))
        #expect(opened.notes[2].quote == Quote(state: .accepted, statusID: "7"))
    }

    @Test("A quote is drawn from the quoted post's own item, and shows everything the copy showed: its words, its author, its cover, its picture and its own quote; where that item is no longer held the quote says so, and the copy's words are nowhere")
    func theQuoteIsTheHeldItem() async throws {
        let dir = try await v11Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        let store = ItemStore(sources: opened.sources, notes: opened.notes)
        let all = await store.all()
        let targets = ReblogTargets(all)
        let quoting = try #require(all.first { $0.id == "3" })
        let shown = QuotedPost(try #require(targets.quoted(by: quoting)))
        #expect(shown.id == "https://one.example/q7" && shown.statusID == "7")
        #expect(shown.body == "the quoted words" && shown.author == "Cyd" && shown.handle == "@cyd@one.example")
        #expect(shown.covered && shown.spoiler == "a cover" && shown.sensitive == true)
        #expect(shown.attachments.map(\.alt) == ["a cat"])
        #expect(shown.quoting == NestedQuote(state: .accepted, statusID: "3"))
        #expect(quoting.refsUnheld.isEmpty)

        let orphan = try #require(all.first { $0.id == "9" })
        #expect(targets.quoted(by: orphan) == nil)
        #expect(orphan.refsUnheld == [.quotes], "named, and no longer held: the quote says so")
        try opened.file?.db.close()
        #expect(try Data(contentsOf: dir.appendingPathComponent("index.sqlite")).range(of: Data("words let go".utf8)) == nil)
    }

    @Test("Nothing in a row's facts says what it answers or quotes afterwards, nor holds a copy of another post; everything else a row's facts said is as it was")
    func nothingLeftInTheFacts() async throws {
        let dir = try await v11Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        let before = try cells(index)
        #expect(before.values.contains { $0.facts["reply"] != nil } && before.values.contains { $0.facts["quote"] != nil }, "the premise")

        let opened = StoreFile.open(at: dir)
        try opened.file?.db.close()

        let after = try cells(index)
        #expect(after.count == before.count)
        for (id, cell) in after {
            #expect(cell.facts["reply"] == nil && cell.facts["quote"] == nil, "\(id)")
            var was = try #require(before[id]).facts
            was["reply"] = nil
            was["quote"] = nil
            #expect(NSDictionary(dictionary: cell.facts) == NSDictionary(dictionary: was), "\(id): every other fact is as it was")
        }
        // A reference the cell already had is the text it was; only what was made good is written.
        #expect(after["2"]?.refs == before["2"]?.refs && after["7"]?.refs == before["7"]?.refs)
        #expect(after["3"]?.refs == before["3"]?.refs && after["1"]?.refs == "[]")
        #expect(after["4"]?.refs == #"[{"kind":"answers","statusID":"42"},{"kind":"quotes","state":"pending"}]"#)
        let file = try Data(contentsOf: index)
        for word in ["inReplyToId", "quotingState", "the quoted words\",\"emojis\":[],\"handle\":\"@cyd@one.example\",\"id\""] {
            #expect(file.range(of: Data(word.utf8)) == nil, "\(word) is still readable in the file")
        }
    }

    @Test("A row whose facts are not text, or not what a row's facts are, does not stop the step or trap it: that row is left as it was, every other row is carried, and the load judges the store as it did before", arguments: ["X'FFFE80FF'", "'not json'", "''", "'[1,2,3]'"])
    func aRowTheStepCannotRead(_ cell: String) async throws {
        let dir = try await v11Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        try await DatabaseQueue(path: index.path).write { db in
            try db.execute(sql: "UPDATE note SET facts = \(cell), refs = 'nor this' WHERE id = '1'")
        }
        let opened = StoreFile.open(at: dir)
        // The step ran to its end whatever the row was: the store that could not be read was
        // put aside by the load, with the step's work in it.
        let judged = try #require(opened.setAside, "such a row has never loaded: the load puts the store aside, as it did before")
        defer { try? FileManager.default.removeItem(at: judged) }
        #expect(opened.trouble == .damaged(replacedBy: .empty))
        let queue = try DatabaseQueue(path: judged.path)
        let ran = try await queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(ran.contains("v12-references-only"), "the step stopped at a row it could not read")
        let left = try await queue.read { db in try String.fetchOne(db, sql: "SELECT refs FROM note WHERE id = '1'") }
        #expect(left == "nor this", "the row it could not read is left as it was")
        let carried = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, CAST(facts AS TEXT) AS facts, refs FROM note WHERE id IN ('2', '4')")
                .map { ($0["id"] as String, $0["facts"] as String, $0["refs"] as String?) }
        }
        #expect(carried.allSatisfy { !$0.1.contains("inReplyToId") }, "the rows it could read are carried")
        #expect(carried.first { $0.0 == "4" }?.2?.contains("answers") == true)
        try queue.close()
    }

    @Test("A cell this step reads and the database does not — facts kept as a blob, text the two parse differently — does not fail the step: the row's references are made good, every other row is carried, and where the row loads nothing reads the two keys left in its facts and the next save writes them without", arguments: ["blob", "blob with a mark before it", "text with a mark before it", "text with a NUL in it"])
    func aCellTheDatabaseReadsDifferently(_ kind: String) async throws {
        let dir = try await v11Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        let facts = Data(Self.facts("odd", #","reply":{"inReplyToId":"60"}"#).utf8)
        // Shapes two JSON readers have disagreed about. The database this was written against
        // reads all of them as this step does, so none makes the removal fail here; an older
        // one refuses a blob outright, which is what the removal's own guard is for.
        let mark = Data([0xEF, 0xBB, 0xBF])
        try await DatabaseQueue(path: index.path).write { db in
            switch kind {
            case "blob":
                try db.execute(sql: "UPDATE note SET facts = ?, refs = '[]' WHERE id = '1'", arguments: [facts])
            case "blob with a mark before it":
                try db.execute(sql: "UPDATE note SET facts = ?, refs = '[]' WHERE id = '1'", arguments: [mark + facts])
            case "text with a mark before it":
                try db.execute(sql: "UPDATE note SET facts = CAST(? AS TEXT), refs = '[]' WHERE id = '1'", arguments: [mark + facts])
            default:
                try db.execute(
                    sql: "UPDATE note SET facts = CAST(? AS TEXT), refs = '[]' WHERE id = '1'",
                    arguments: [facts + Data([0]) + Data("junk".utf8)]
                )
            }
        }
        let opened = StoreFile.open(at: dir)
        let judged = opened.setAside ?? index
        defer { if let aside = opened.setAside { try? FileManager.default.removeItem(at: aside) } }
        let queue = try DatabaseQueue(path: judged.path)
        let ran = try await queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(ran.contains("v12-references-only"), "the step failed on one cell")
        let others = try await queue.read { db in try String.fetchOne(db, sql: "SELECT CAST(facts AS TEXT) FROM note WHERE id = '2'") }
        #expect(others?.contains("inReplyToId") == false, "and every other row was carried")
        try queue.close()
        // Where the load reads the row, it answers what its facts said, and a save writes its
        // facts without the keys. Where it does not, that is the load's to judge, as before.
        guard opened.trouble == nil, let row = opened.notes.first(where: { $0.id == "1" }) else {
            #expect(kind == "text with a NUL in it", "\(kind): the row was expected to load")
            return
        }
        #expect(row.refs == [.answers("60")])
        try await #require(opened.file).save(sources: opened.sources, notes: opened.notes)
        try opened.file?.db.close()
        #expect(try cells(index)["1"]?.facts["reply"] == nil)
    }

    @Test("A save by this build and a relaunch leave them where they stood")
    func savedAndOpenedAgain() async throws {
        let dir = try await v11Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        try await #require(opened.file).save(sources: opened.sources, notes: opened.notes)
        try opened.file?.db.close()
        let again = StoreFile.open(at: dir)
        #expect(again.notes == opened.notes && again.trouble == nil)
        let cells = try cells(dir.appendingPathComponent("index.sqlite"))
        #expect(cells.values.allSatisfy { $0.facts["reply"] == nil && $0.facts["quote"] == nil }, "and a save writes neither")
    }

    @Test("The build before sees a store this build opened as newer, and reads it on disk unchanged; one this build made from nothing is refused too")
    func olderBuildRefusesIt() async throws {
        let dir = try await v11Store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        #expect(try !supersededForTheBuildBefore(index), "the premise: its own store is its own")
        let opened = StoreFile.open(at: dir)
        try opened.file?.db.close()
        let before = try Data(contentsOf: index)
        #expect(try supersededForTheBuildBefore(index))
        #expect(try Data(contentsOf: index) == before)

        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fresh) }
        try await StoreFile(at: fresh).save(sources: [Self.mastodon], notes: [PackagerFixture.note("1")])
        #expect(try supersededForTheBuildBefore(fresh.appendingPathComponent("index.sqlite")))
    }

    // MARK: - Taken away, and moved nearby

    @Test(
        "A package the build before took away — under a file's password, and under a key handed over as a move nearby is; onto a device with a store open, and onto one where the package's index is moved into place — is read back with every row referring to what it did, and nothing left in its facts",
        arguments: [PackageKey.password("password"), .direct(SymmetricKey(data: Data(repeating: 7, count: 32)))], [false, true]
    )
    func anOlderPackage(_ key: PackageKey, movedIntoPlace: Bool) async throws {
        let old = try await v11Store()
        let onto = try await Device(noFile: movedIntoPlace)
        let url = PackagerFixture.package()
        defer { try? FileManager.default.removeItem(at: old); onto.remove(); try? FileManager.default.removeItem(at: url) }
        let index = try Data(contentsOf: old.appendingPathComponent("index.sqlite"))
        let settings = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let summary = PackageSummary(
            sources: [.init(host: Self.mastodon.host, kind: .mastodon)],
            posts: Self.rows.count, timelines: 0, takenAt: PackagerFixture.origin, withPictures: false,
            bytes: index.count + settings.count, hasSecrets: false, device: "an older build", appVersion: "0.0.9",
            entryCount: 3
        )
        let writer = try PackageWriter(to: url, key: key, summary: summary, rounds: 1000)
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

        try await onto.packager().readBack(url, key: key, replacing: false) { _ in }

        let held = await onto.store.snapshot().notes
        #expect(Set(held.map(\.id)) == Set(Self.rows.map(\.id)))
        #expect(held.first { $0.id == "2" }?.reply == Reply(handle: "@bob@one.example", inReplyToId: "41"))
        #expect(held.first { $0.id == "4" }?.refs == [.answers("42"), .quotes(.pending)])
        #expect(held.first { $0.id == "5" }?.quotedKey == Self.key("https://one.example/q7"))
        // And on disk, where the next launch reads.
        let cells = try cells(onto.directory.appendingPathComponent("index.sqlite"))
        #expect(cells.count == Self.rows.count)
        #expect(cells.values.allSatisfy { $0.facts["reply"] == nil && $0.facts["quote"] == nil })
    }
}
