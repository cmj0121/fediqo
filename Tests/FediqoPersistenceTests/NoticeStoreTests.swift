import FediqoCore
import Foundation
import GRDB
import Synchronization
import Testing
@testable import FediqoPersistence

/// What each source says happened to the person is written down beside the posts, as a part of
/// its own (#323), and is not left readable once it is let go (#292).
///
/// What a test can reach: the tables and the bytes of the file, a store as the build before
/// this one left it, a build that knows no `v14-notices`, the saver's own order, and a package
/// taken away and read back. What it cannot: a process killed between two of these writes.
@Suite("Notices are on disk until they are let go")
struct NoticeStoreTests {
    private static let mastodon = PackagerFixture.mastodon
    private static let origin = PackagerFixture.origin

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Long enough to fill pages of their own, so letting one go frees whole pages.
    private static let padding = String(repeating: " ordinary words about the day, and more of them.", count: 120)

    private static func post(_ id: String, _ words: String = "hello", minutes: Double = 0, spoiler: String? = nil) -> Note {
        Note(
            id: "https://one.example/statuses/\(id)", source: mastodon, author: "Ada", handle: "@ada@one.example",
            body: words, postedAt: origin.addingTimeInterval(minutes * 60), categories: [],
            audience: .mentioned, sensitive: spoiler != nil, spoiler: spoiler, statusID: id
        )
    }

    private static func line(
        _ id: Int, kind: Notice.Kind = .mention, who: String = "Bo", post: Note? = nil, minutes: Double = 0
    ) -> Notice {
        Notice(
            source: mastodon, handle: .one(id: "\(id)"), kind: kind,
            people: [NoticePerson(handle: "@bo@elsewhere.example", name: who)], post: post,
            at: origin.addingTimeInterval(minutes * 60), newestID: "\(id)", oldestID: "\(id)"
        )
    }

    private static func reach(_ lines: [Notice], before: String? = nil) -> NoticeReach {
        NoticeReach(
            host: mastodon.host, notices: lines, before: before, reached: lines.map(\.at).min(), gathered: false
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

    // MARK: - Written and read back

    @Test("A source's notices are read back by a relaunch in its own order, with who, how many, what each is about — still covered where it was — and how far down the source was read; and writing them touches no post")
    func writtenAndReadBack() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        let item = PackagerFixture.note("1")
        try await file.save(sources: [Self.mastodon], notes: [item])
        let covered = Self.post("77", "the words under the cover", minutes: 3, spoiler: "about lunch")
        let gathered = Notice(
            source: Self.mastodon, handle: .gathered(key: "favourite-9-1"), kind: .favourite,
            people: [
                NoticePerson(
                    handle: "@cy@elsewhere.example", name: "Cy :wave:", avatarURL: URL(string: "https://cdn.example/cy.png"),
                    emojis: [CustomEmoji(shortcode: "wave", url: URL(string: "https://cdn.example/wave.gif")!)]
                ),
                NoticePerson(handle: "@di@one.example", name: "Di"),
            ],
            count: 7, post: Self.post("9", "the person's own post"), at: Self.origin.addingTimeInterval(600),
            newestID: "44", oldestID: "31"
        )
        let lines = [
            gathered, Self.line(30, post: covered, minutes: 5), Self.line(29, kind: .follow, minutes: 4),
            Self.line(28, kind: .unknown("something.new"), minutes: 2),
        ]
        let reach = NoticeReach(
            host: Self.mastodon.host, notices: lines, before: "28", reached: Self.origin.addingTimeInterval(120),
            gathered: true
        )

        try await file.save(notices: [reach])

        let opened = StoreFile.open(at: dir)
        #expect(opened.notices == [reach])
        let back = try #require(opened.notices.first)
        #expect(back.notices.map(\.id) == lines.map(\.id), "in the source's order, whatever order the rows lie in")
        #expect(back.notices[0].people.map(\.lineName) == ["Cy :wave:", "Di"])
        #expect(back.notices[1].post?.spoiler == "about lunch" && back.notices[1].post?.sensitive == true, "covered still")
        #expect(back.notices[1].post?.audience == .mentioned)
        #expect(back.notices[3].kind == .unknown("something.new"))
        #expect(opened.notes == [item], "the posts are as they were, and the carried ones are none of them")

        try await #require(opened.file).save(notices: [])
        #expect(StoreFile.open(at: dir).notices.isEmpty)
    }

    @Test("Notices of a host that is no source here are not read, and a line named by a read this build does not know is left out")
    func onlyOfASourceHere() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: [])
        try await file.save(notices: [Self.reach([Self.line(2), Self.line(1)])])
        try await file.db.write { db in
            try db.execute(sql: "UPDATE notice SET handle = 'bundled' WHERE name = '2'")
        }

        #expect(try file.loadNotices(of: [Self.mastodon]).first?.notices.map(\.newestID) == ["1"])
        #expect(try file.loadNotices(of: []).isEmpty)
    }

    @Test("A line whose post or people will not read is a notice without them, never a store judged damaged")
    func aCellThatWillNotRead() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.mastodon], notes: [])
        try await file.save(notices: [Self.reach([Self.line(1, post: Self.post("5"))])])
        try await file.db.write { db in
            try db.execute(sql: "UPDATE notice SET post = '{not json', people = 'nor this'")
        }

        let opened = StoreFile.open(at: dir)

        #expect(opened.file != nil && opened.trouble == nil && opened.setAside == nil)
        let line = try #require(opened.notices.first?.notices.first)
        #expect(line.post == nil && line.people.isEmpty)
        #expect(line.kind == .mention && line.newestID == "1")
    }

    // MARK: - The store's format

    @Test("A store as the build before this one left it opens with everything it held, and no notice; it is then this build's")
    func aStoreFromBefore() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index.sqlite")
        let notes = [PackagerFixture.note("1"), PackagerFixture.note("2")]
        let waiting = Unsent(host: Self.mastodon.host, text: "still waiting", audience: .everyone, pressedAt: Self.origin)
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Self.mastodon], notes: notes)
            try await file.save(unsent: [waiting])
            // As the build before left it: no table for notices, and no word of the step that makes them.
            try await file.db.write { db in
                try db.execute(sql: "DROP TABLE notice")
                try db.execute(sql: "DROP TABLE notice_reach")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v14-notices'")
            }
        }
        #expect(try migrations(index).last == "v13-unsent", "the premise: a store from before")

        let opened = StoreFile.open(at: dir)

        #expect(opened.file != nil && opened.setAside == nil && !opened.storeIsNewer && opened.trouble == nil)
        #expect(opened.sources == [Self.mastodon])
        #expect(opened.notes == notes)
        #expect(opened.unsent == [waiting])
        #expect(opened.notices.isEmpty)
        #expect(try migrations(index).last == "v14-notices")
    }

    @Test("A build that knows no v14-notices sees this build's store as newer — one it made from nothing too — and the store is unchanged for being asked")
    func anOlderBuildRefusesIt() async throws {
        for holding in [true, false] {
            let dir = scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let index = dir.appendingPathComponent("index.sqlite")
            do {
                let file = try StoreFile(at: dir)
                if holding {
                    try await file.save(sources: [Self.mastodon], notes: [])
                    try await file.save(notices: [Self.reach([Self.line(1, post: Self.post("5"))])])
                }
            }
            let before = try Data(contentsOf: index)

            let superseded = try supersededForTheBuildBefore(index)

            #expect(superseded, "an older build would never let go of a line a sign-out should take")
            #expect(try Data(contentsOf: index) == before)
        }
    }

    /// Asked as `StoreFile` asks: read-only, of a migrator — here one that knows every step this
    /// store records but the last, by name.
    private func supersededForTheBuildBefore(_ index: URL) throws -> Bool {
        var older = DatabaseMigrator()
        for id in try migrations(index) where id != "v14-notices" { older.registerMigration(id) { _ in } }
        var readOnly = Configuration()
        readOnly.readonly = true
        return try DatabaseQueue(path: index.path, configuration: readOnly).read(older.hasBeenSuperseded)
    }

    // MARK: - Let go

    @Test("A notice let go — its people's names and the words of the post it carried — is not left readable in the file, with nothing else done", arguments: [
        "dismissed", "signed out", "removed", "read back", "months",
    ])
    func letGoLeavesNothing(how: String) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let words = "persimmon-lantern-notice", name = "Quillon-Harrow-Notice"
        let staying = "quince-harbour-notice"
        let going = Self.line(2, who: name, post: Self.post("5", words + Self.padding), minutes: -100_000)
        let kept = Self.line(3, post: Self.post("6", staying + Self.padding))
        let other = Source(host: "two.example", kind: .mastodon)
        let store = ItemStore(sources: [Self.mastodon, other], notes: [PackagerFixture.note("1")])
        let file = try StoreFile(at: dir)
        let saver = StoreSaver(store: store, file: file)
        await store.hold(Self.reach([kept, going]))
        try await saver.save()
        #expect(try files(in: dir, holding: words) == ["index.sqlite"], "the premise: it was written")
        #expect(try files(in: dir, holding: name) == ["index.sqlite"])

        switch how {
        case "dismissed": await store.hold(Self.reach([kept]))
        case "signed out": await store.forgetReaderMarks(host: Self.mastodon.host)
        case "removed": await store.remove(host: Self.mastodon.host, keepingPosts: true)
        case "read back": await store.replace(sources: [Self.mastodon], notes: [])
        default: _ = await store.letGoBeyond(months: 1, from: Self.origin)
        }
        try await saver.save()

        #expect(try files(in: dir, holding: words).isEmpty)
        #expect(try files(in: dir, holding: name).isEmpty)
        let stays = how == "dismissed" || how == "months"
        #expect(try files(in: dir, holding: staying) == (stays ? ["index.sqlite"] : []))
    }

    @Test("The words of a post let go are not left readable in the notice that carried it")
    func aCarriedPostLetGo() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let words = "marrow-thistle-carried"
        let post = Self.post("5", words + Self.padding)
        let store = ItemStore(sources: [Self.mastodon], notes: [post])
        let file = try StoreFile(at: dir)
        let saver = StoreSaver(store: store, file: file)
        await store.hold(Self.reach([Self.line(2, post: post)]))
        try await saver.save()
        #expect(try files(in: dir, holding: words) == ["index.sqlite"], "the premise: held as a post and carried")

        await store.letGo(span: Date.distantPast..<Date.distantFuture)
        try await saver.save()

        #expect(try files(in: dir, holding: words).isEmpty)
        #expect(try file.loadNotices(of: [Self.mastodon]).first?.notices.map { $0.post == nil } == [true], "the line stays")
    }

    @Test("What is read past the months limit is never written")
    func pastTheLimitIsNeverWritten() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let words = "older-than-the-limit-words"
        let store = ItemStore(sources: [Self.mastodon], notes: [])
        let saver = StoreSaver(store: store, file: try StoreFile(at: dir))
        _ = await store.letGoBeyond(months: 1, from: Self.origin)
        await store.hold(Self.reach([Self.line(2, post: Self.post("5", words, minutes: -200_000))]))

        try await saver.save()

        #expect(try files(in: dir, holding: words).isEmpty)
        #expect(StoreFile.open(at: dir).notices.first?.notices.map(\.newestID) == ["2"])
    }

    // MARK: - The saver

    /// What the saver wrote, in order.
    private final class Wrote: Sendable {
        private let all = Mutex<[String]>([])
        func add(_ what: String) { all.withLock { $0.append(what) } }
        var list: [String] { all.withLock { $0 } }
    }

    @Test("A save writes the notices where they moved, after the texts and before the posts, and not again where they did not")
    func aPartOfItsOwn() async throws {
        let store = ItemStore(sources: [Self.mastodon], notes: [PackagerFixture.note("1")])
        let wrote = Wrote()
        let saver = StoreSaver(
            store: store,
            write: { _, notes, _ in wrote.add("posts:\(notes.count)") },
            writeUnsent: { wrote.add("texts:\($0.count)") },
            writeNotices: { wrote.add("notices:" + $0.flatMap(\.notices).map(\.newestID).joined(separator: ",")) }
        )
        await store.hold(Self.reach([Self.line(2), Self.line(1)]))
        await store.hold(Unsent(host: Self.mastodon.host, text: "one", audience: .everyone))
        try await saver.save()
        #expect(wrote.list == ["texts:1", "notices:2,1", "posts:1"])

        await store.ingest([PackagerFixture.note("2")])
        try await saver.save()
        #expect(wrote.list.last == "posts:2" && wrote.list.count == 4, "notices that did not move are not written again")

        await store.hold(Self.reach([Self.line(1)]))
        try await saver.save()
        #expect(wrote.list.last == "notices:1" && wrote.list.count == 5, "and a notice dismissed rewrites no post")
    }

    @Test("A page of notices read is saved by the follower with nobody asking, and no post is written for it")
    func followed() async throws {
        let store = ItemStore(sources: [Self.mastodon], notes: [PackagerFixture.note("1")])
        let wrote = Wrote()
        let slept = Wrote()
        let saver = StoreSaver(
            store: store,
            write: { _, notes, _ in wrote.add("posts:\(notes.count)") },
            writeNotices: { wrote.add("notices:\($0.flatMap(\.notices).count)") }
        )
        let following = Task {
            await saver.follow(quiet: .seconds(2), gap: .seconds(60)) { slept.add("\($0)") }
        }
        defer { following.cancel() }

        await store.hold(Self.reach([Self.line(1)]))
        for _ in 0..<200_000 where wrote.list.isEmpty { await Task.yield() }

        #expect(wrote.list == ["notices:1"], "a launch's store is not written whole for a notice")
        #expect(slept.list == ["2.0 seconds"], "the quiet, and no gap: no note was written")
    }

    @Test("A saver with nowhere to write notices is not armed by one")
    func nowhereToWrite() async throws {
        let store = ItemStore(sources: [Self.mastodon], notes: [])
        let wrote = Wrote()
        let slept = Wrote()
        let saver = StoreSaver(store: store, write: { _, _, _ in wrote.add("posts") })
        let following = Task { await saver.follow { slept.add("\($0)") } }
        defer { following.cancel() }

        await store.hold(Self.reach([Self.line(1)]))
        for _ in 0..<2_000 { await Task.yield() }

        #expect(wrote.list.isEmpty && slept.list.isEmpty)
    }

    // MARK: - Carried

    @Test("A take-away carries no notice, and a read back lets go of the ones this device holds — from the store and from the file")
    func notCarried() async throws {
        let from = try await PackagerFixture.PackagerDevice(sources: [Self.mastodon], notes: [PackagerFixture.note("1")])
        let onto = try await PackagerFixture.PackagerDevice(sources: [Self.mastodon], notes: [PackagerFixture.note("9")])
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        let theirs = Self.reach([Self.line(1, who: "Said-On-The-First", post: Self.post("5", "told-on-the-first-device"))])
        let mine = Self.reach([Self.line(2, who: "Said-On-The-Second", post: Self.post("6", "told-on-the-second-device"))])
        await from.store.hold(theirs)
        try await #require(from.file).save(notices: [theirs])
        await onto.store.hold(mine)
        try await #require(onto.file).save(notices: [mine])

        try await from.packager().takeAway(to: url, key: .password("open sesame"), pictures: false) { _ in }
        try await onto.packager().readBack(url, key: .password("open sesame"), replacing: true) { _ in }

        #expect(await onto.store.snapshot().notes.map(\.id) == ["1"], "the premise: the store was replaced")
        #expect(await onto.store.noticesHeld().notices.isEmpty, "they may be another sign-in's")
        #expect(try StoreFile(at: onto.directory).loadNotices(of: [Self.mastodon]).isEmpty)
        for phrase in ["told-on-the-second-device", "Said-On-The-Second", "told-on-the-first-device", "Said-On-The-First"] {
            #expect(try files(in: onto.directory, holding: phrase).isEmpty, "\(phrase)")
        }
        #expect(try #require(from.file).loadNotices(of: [Self.mastodon]) == [theirs], "and taking away let nothing go")
    }

    @Test("What a read back does to a staged store that carries notices all the same: every one goes, unreadable, and the posts stay")
    func aStagedStoreIsEmptiedOfNotices() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try StoreFile(at: dir)
        try await staged.save(sources: [Self.mastodon], notes: [PackagerFixture.note("1")])
        try await staged.save(notices: [Self.reach([Self.line(1, post: Self.post("5", "from-somewhere-else-entirely"))])])

        try staged.dropNotices()

        #expect(try staged.loadNotices(of: [Self.mastodon]).isEmpty)
        #expect(try staged.load().notes.map(\.id) == ["1"])
        #expect(try files(in: dir, holding: "from-somewhere-else-entirely").isEmpty)
    }
}
