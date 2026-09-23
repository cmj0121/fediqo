import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

@Suite("The on-device index")
struct StoreFileTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let mastodon = Source(host: "first.example", kind: .mastodon)

    private func note(
        id: String = "1",
        source: Source? = nil,
        handle: String = "@ada",
        title: String? = nil,
        board: String? = nil,
        categories: Set<FediqoCore.Category> = [.public],
        reply: Reply? = nil,
        boostedBy: String? = nil,
        avatarURL: URL? = nil,
        attachments: [FediqoCore.Attachment] = [],
        sensitive: Bool? = nil,
        spoiler: String? = nil,
        emojis: [CustomEmoji] = [],
        url: URL? = nil
    ) -> Note {
        Note(
            id: id, source: source ?? mastodon, author: "Ada", handle: handle, body: "hello",
            title: title, board: board, postedAt: origin, categories: categories,
            reply: reply, boostedBy: boostedBy, avatarURL: avatarURL, attachments: attachments,
            sensitive: sensitive, spoiler: spoiler, emojis: emojis, url: url
        )
    }

    @Test("Sources and slim notes survive a save and load")
    func roundTrip() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 33, name: "a")])
        let saved = note(id: "https://first.example/users/ada/statuses/1", categories: [.public, .trends])
        try await file.save(sources: [mastodon, forum], notes: [saved])
        let loaded = try file.load()
        #expect(loaded.sources == [mastodon, forum])
        #expect(loaded.notes == [saved])
    }

    @Test("A post held aside is still held aside after a relaunch, and one that arrived still arrived")
    func holdingSurvivesRelaunch() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        var found = note(id: "2")
        found.holding = .aside
        try await file.save(sources: [mastodon], notes: [note(id: "1"), found])
        let loaded = try file.load().notes
        #expect(loaded.first { $0.id == "1" }?.holding == .arrived)
        #expect(loaded.first { $0.id == "2" }?.holding == .aside)
    }

    /// #177: a topic read to its end is there with the network off, which is a relaunch reading
    /// its replies back — their floor, their own date where the page gave one, and none where it
    /// did not, and the page each was read off.
    @Test("A forum reply read in a thread comes back after a relaunch as the reply it was")
    func keptReplySurvivesRelaunch() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let forum = Source(host: "forum.example", kind: .discuz)
        let read = Date(timeIntervalSince1970: 1_800_000_000)
        let dated = DiscuzPost(
            pid: 71, tid: 5, floor: 21, author: "linlu", handle: "@linlu@forum.example",
            postedAt: origin, body: "第三页的回复",
            quoted: [DiscuzQuotation(words: "上面那句")], page: 3
        )
        let undated = DiscuzPost(
            pid: 72, tid: 5, floor: 22, author: "muyu", handle: "@muyu@forum.example",
            body: "没有日期", page: 3
        )
        var notes = [dated, undated].map { $0.asNote(host: forum.host, read: read) }
        for index in notes.indices { notes[index].holding = .aside }
        try await file.save(sources: [forum], notes: notes)

        let back = try file.load().notes.compactMap(DiscuzPost.init(held:)).sorted { $0.pid < $1.pid }
        #expect(back == [dated, undated], "floor, date, quotation and page, each as read")
        #expect(back[1].postedAt == nil, "a reply the page gave no date to is not given the read's")
        #expect(try file.load().notes.allSatisfy { $0.holding == .aside })
    }

    @Test("A post marked gone from its source is still marked, from the same moment, after a relaunch")
    func goneSurvivesRelaunch() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        var gone = note(id: "2")
        gone.goneSince = origin.addingTimeInterval(3600)
        try await file.save(sources: [mastodon], notes: [note(id: "1"), gone])
        let loaded = try file.load().notes
        #expect(loaded.first { $0.id == "1" }?.goneSince == nil)
        #expect(loaded.first { $0.id == "2" }?.goneSince == origin.addingTimeInterval(3600))
    }

    @Test("A loaded note has every row fact and its multimedia hyperlinks")
    func rowFactsWithMultimedia() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let forum = Source(host: "forum.example", kind: .discuz)
        let picture = URL(string: "https://forum.example/a.png")
        let saved = note(
            source: forum, title: "tool", board: "tools", categories: [.board(id: "33")],
            reply: Reply(handle: "@bob"), boostedBy: "Carol",
            avatarURL: picture, attachments: [FediqoCore.Attachment(kind: .image, url: picture)],
            sensitive: true, spoiler: "cover"
        )
        try await file.save(sources: [forum], notes: [saved])
        #expect(try file.load().notes == [saved])
    }

    @Test("Who boosted a post, as user@instance, survives a relaunch; a post nobody boosted has nobody")
    func boosterHandleSurvivesRelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let boosted = Note(
            id: "1", source: mastodon, author: "Ada", handle: "@ada@second.example", body: "hello",
            postedAt: origin, categories: [.public], boostedBy: "Bob", boosterHandle: "@bob@first.example"
        )
        let plain = note(id: "2")
        try await StoreFile(at: dir).save(sources: [mastodon], notes: [boosted, plain])
        let loaded = StoreFile.open(at: dir).notes
        #expect(loaded.first { $0.id == "1" }?.boosterHandle == "@bob@first.example")
        #expect(loaded.first { $0.id == "2" }?.boosterHandle == nil)
    }

    @Test("A post's id on its server survives a relaunch; a row without one reads back as none")
    func statusIDSurvivesRelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let known = Note(
            id: "1", source: mastodon, author: "Ada", handle: "@ada@first.example", body: "hello",
            postedAt: origin, categories: [.public], statusID: "10942"
        )
        try await StoreFile(at: dir).save(sources: [mastodon], notes: [known, note(id: "2")])
        let loaded = StoreFile.open(at: dir).notes
        #expect(loaded.first { $0.id == "1" }?.statusID == "10942")
        #expect(loaded.first { $0.id == "2" }?.statusID == nil)
    }

    /// #106: a boost that landed shows as boosted after a relaunch. What is written down is the
    /// source's own answer, carried on the note; a source that never said reads back as never
    /// having said, and a no reads back as a no.
    @Test("What the source said about a boost survives a relaunch, and silence stays silence")
    func boostedSurvivesRelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        func said(_ id: String, _ boosted: Bool?) -> Note {
            Note(
                id: id, source: mastodon, author: "Ada", handle: "@ada@first.example", body: "hello",
                postedAt: origin, categories: [.home], boosted: boosted, statusID: id
            )
        }
        try await StoreFile(at: dir).save(
            sources: [mastodon], notes: [said("1", true), said("2", false), said("3", nil)]
        )
        let loaded = StoreFile.open(at: dir).notes
        #expect(loaded.first { $0.id == "1" }?.boosted == true)
        #expect(loaded.first { $0.id == "2" }?.boosted == false)
        #expect(loaded.first { $0.id == "3" }?.boosted == nil)
    }

    /// #107: a favourite is kept the way a boost is, and apart from it.
    @Test("What the source said about a favourite survives a relaunch, apart from the boost")
    func favouritedSurvivesRelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        func said(_ id: String, _ favourited: Bool?) -> Note {
            Note(
                id: id, source: mastodon, author: "Ada", handle: "@ada@first.example", body: "hello",
                postedAt: origin, categories: [.home], boosted: false, favourited: favourited,
                statusID: id
            )
        }
        try await StoreFile(at: dir).save(
            sources: [mastodon], notes: [said("1", true), said("2", false), said("3", nil)]
        )
        let loaded = StoreFile.open(at: dir).notes
        #expect(loaded.first { $0.id == "1" }?.favourited == true)
        #expect(loaded.first { $0.id == "2" }?.favourited == false)
        #expect(loaded.first { $0.id == "3" }?.favourited == nil)
        #expect(loaded.allSatisfy { $0.boosted == false })
    }

    /// #109: what went stays gone after a relaunch, because the store the save writes no
    /// longer holds it — and only it went.
    @Test("A post taken back stays gone after a relaunch, and nothing else goes")
    func takenBackStaysGone() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ItemStore(sources: [mastodon], notes: [note(id: "1"), note(id: "2")])
        await store.forget(NoteKey(host: mastodon.host, id: "1"))
        let snapshot = await store.snapshot()
        try await StoreFile(at: dir).save(sources: snapshot.sources, notes: snapshot.notes)
        #expect(StoreFile.open(at: dir).notes.map(\.id) == ["2"])
    }

    @Test("A reply whose parent's handle is unknown comes back a reply")
    func replyWithoutHandle() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let saved = [note(id: "1", reply: Reply(handle: nil)), note(id: "2")]
        try await file.save(sources: [mastodon], notes: saved)
        #expect(Set(try file.load().notes) == Set(saved))
    }

    @Test("What a reply answers, as its own server names it, survives a relaunch")
    func inReplyToIDSurvivesRelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = [
            note(id: "1", reply: Reply(handle: "@ada@first.example", inReplyToId: "10941")),
            note(id: "2", reply: Reply(handle: "@ada@first.example")),
            note(id: "3"),
        ]
        try await StoreFile(at: dir).save(sources: [mastodon], notes: saved)
        let loaded = StoreFile.open(at: dir).notes
        #expect(loaded.first { $0.id == "1" }?.reply?.inReplyToId == "10941")
        #expect(loaded.first { $0.id == "2" }?.reply?.inReplyToId == nil, "a parent nobody named")
        #expect(loaded.first { $0.id == "3" }?.reply == nil, "not a reply at all")
    }

    @Test("Unset sensitive and spoiler stay unset, apart from false and empty", arguments: [
        (Bool?.none, String?.none), (false, ""), (true, "cover"),
    ])
    func unsetStaysUnset(sensitive: Bool?, spoiler: String?) async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let saved = note(sensitive: sensitive, spoiler: spoiler)
        try await file.save(sources: [mastodon], notes: [saved])
        #expect(try file.load().notes == [saved])
    }

    @Test("Notes are read back in the order they were written, which is the order they arrived in")
    func writtenOrderSurvives() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let second = Source(host: "second.example", kind: .mastodon)
        let uri = "https://first.example/users/ada/statuses/1"
        // Against the key's own order on purpose: the later host and the later id first.
        let saved = [note(id: "z", source: second), note(id: uri, source: second), note(id: uri), note(id: "a")]
        try await file.save(sources: [mastodon, second], notes: saved)
        #expect(try file.load().notes == saved)
    }

    @Test("Row facts survive a relaunch on the same directory")
    func rowFactsSurviveRelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = note(board: "tools", categories: [.board(id: "33")], reply: Reply(handle: nil), boostedBy: "Carol", sensitive: true, spoiler: "")
        try await StoreFile(at: dir).save(sources: [mastodon], notes: [saved])
        let opened = StoreFile.open(at: dir)
        #expect(opened.setAside == nil)
        #expect(opened.notes == [saved])
    }

    /// #7: a drop by time is written, so a relaunch reads back only what was kept.
    @Test("A drop by time holds after a relaunch")
    func dropByTimeSurvivesRelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = note(id: "old")
        let new = Note(
            id: "new", source: mastodon, author: "Ada", handle: "@ada", body: "hello",
            postedAt: origin.addingTimeInterval(30 * 86_400), categories: [.public]
        )
        let store = ItemStore(sources: [mastodon], notes: [old, new])
        #expect(await store.setRetention(months: 1, from: origin.addingTimeInterval(40 * 86_400)) == 1)
        let snapshot = await store.snapshot()
        try await StoreFile(at: dir).save(sources: snapshot.sources, notes: snapshot.notes)

        let opened = StoreFile.open(at: dir)
        #expect(opened.notes.map(\.id) == ["new"])
        #expect(opened.sources.map(\.host) == [mastodon.host], "the source did not stay joined")
    }

    @Test("A note whose host has no source row is dropped on load")
    func orphanDropped() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let kept = note(id: "1")
        let orphan = note(id: "2", source: Source(host: "gone.example", kind: .mastodon))
        try await file.save(sources: [mastodon], notes: [kept, orphan])
        #expect(try file.load().notes == [kept])
    }

    @Test("A note takes its source, boards and all, from the source row")
    func sourceFromRow() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 3, name: "x")])
        try await file.save(sources: [forum], notes: [note(source: Source(host: "forum.example", kind: .discuz))])
        #expect(try file.load().notes.first?.source == forum)
    }

    /// Every field an attachment and an emoji carry, a picture with only a preview among them:
    /// what a row drew before a relaunch — the alt text, the shape it reserved — is what it draws
    /// after.
    private var multimedia: Note {
        note(
            avatarURL: URL(string: "https://cdn.example/ada.png"),
            attachments: [
                FediqoCore.Attachment(
                    kind: .image,
                    url: URL(string: "https://cdn.example/pic.jpg"),
                    previewURL: URL(string: "https://cdn.example/pic-small.jpg"),
                    alt: "a cat on a mat",
                    width: 1200,
                    height: 800
                ),
                FediqoCore.Attachment(kind: .video, previewURL: URL(string: "https://cdn.example/clip.jpg")),
                FediqoCore.Attachment(kind: .unknown, url: URL(string: "https://cdn.example/file.bin"), alt: "",
                                      width: 0, height: 5),
            ],
            emojis: [
                CustomEmoji(shortcode: "blobcat", url: URL(string: "https://cdn.example/blobcat.gif")!,
                            staticURL: URL(string: "https://cdn.example/blobcat.png")),
                CustomEmoji(shortcode: "ok", url: URL(string: "https://cdn.example/ok.png")!),
            ],
            url: URL(string: "https://first.example/@ada/1")
        )
    }

    @Test("Every attachment field, every emoji, and the post's address survive a save and load")
    func multimediaRoundTrip() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let saved = multimedia
        try await file.save(sources: [mastodon], notes: [saved])
        let loaded = try #require(try file.load().notes.first)
        #expect(loaded == saved)
        // Spelled out, so a `==` that stopped comparing a field could not pass this quietly.
        #expect(loaded.attachments.map(\.alt) == ["a cat on a mat", "", ""])
        #expect(loaded.attachments.map(\.width) == [1200, nil, nil])
        #expect(loaded.attachments.map(\.height) == [800, nil, nil])
        #expect(loaded.attachments.map(\.kind) == [.image, .video, .unknown])
        #expect(loaded.attachments[1].url == nil)
        #expect(loaded.attachments[1].previewURL == URL(string: "https://cdn.example/clip.jpg"))
        #expect(loaded.emojis.map(\.staticURL) == [URL(string: "https://cdn.example/blobcat.png"), nil])
        #expect(loaded.url == URL(string: "https://first.example/@ada/1"))
        #expect(loaded.avatarURL == URL(string: "https://cdn.example/ada.png"))
    }

    @Test("A note with no multimedia comes back with none")
    func noMultimedia() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let saved = note()
        try await file.save(sources: [mastodon], notes: [saved])
        let loaded = try #require(try file.load().notes.first)
        #expect(loaded.attachments.isEmpty && loaded.emojis.isEmpty)
        #expect(loaded.avatarURL == nil && loaded.url == nil)
    }

    @Test("Multimedia survives a relaunch on the same directory")
    func multimediaSurvivesRelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await StoreFile(at: dir).save(sources: [mastodon], notes: [multimedia])
        let opened = StoreFile.open(at: dir)
        #expect(opened.setAside == nil)
        #expect(opened.notes == [multimedia])
    }

    @Test("Two sources carrying the same id stay two rows")
    func twoSourcesTwoRows() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let one = Source(host: "a.example", kind: .mastodon)
        let two = Source(host: "b.example", kind: .mastodon)
        let uri = "https://origin.example/users/ada/statuses/1"
        let saved = [note(id: uri, source: one), note(id: uri, source: two, categories: [.trends])]
        try await file.save(sources: [one, two], notes: saved)
        #expect(Set(try file.load().notes) == Set(saved))
    }

    @Test("A directory is excluded from backup")
    func excludedFromBackup() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try StoreFile(at: dir)
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("An empty index loads as nothing")
    func emptyLoad() throws {
        let loaded = try StoreFile(database: DatabaseQueue()).load()
        #expect(loaded.sources.isEmpty)
        #expect(loaded.notes.isEmpty)
    }

    @Test("A title and the source's kind come back")
    func titleAndKind() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let forum = Source(host: "forum.example", kind: .discuz)
        let saved = note(id: "tid-7", source: forum, title: "A thread", categories: [.trends])
        try await file.save(sources: [forum], notes: [saved])
        let loaded = try file.load()
        #expect(loaded.notes == [saved])
        #expect(loaded.sources.first?.kind == .discuz)
    }

    @Test("Every kind of category, an odd board id among them, and none, survive a save and a relaunch")
    func categoriesRoundTrip() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let forum = Source(host: "forum.example", kind: .discuz)
        let saved = [
            note(id: "1", categories: [.public, .trends, .board(id: "a:b \"q\" 🧵")]),
            note(id: "2", categories: []),
            note(id: "4", categories: [.home, .list(id: "42"), .list(id: "a:b \"q\" 🧵"), .public]),
            note(id: "3", source: forum, categories: [.board(id: "37"), .board(id: "4")]),
        ]
        try await StoreFile(at: dir).save(sources: [mastodon, forum], notes: saved)
        let opened = StoreFile.open(at: dir)
        #expect(opened.setAside == nil)
        #expect(Set(opened.notes) == Set(saved))
    }

    @Test("A note seen in no category comes back in none")
    func emptyCategories() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        try await file.save(sources: [mastodon], notes: [note(categories: [])])
        #expect(try file.load().notes.first?.categories == [])
    }

    @Test("Board names holding separators, quotes and emoji survive", arguments: [
        "a\u{1e}b", "a\u{1f}b", "\u{1f}", "", "\"quoted\", [brackets]", "水 🌊 board", "comma,semi;colon",
    ])
    func oddBoardNames(name: String) async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let boards = [BoardSubscription(fid: 1, name: name), BoardSubscription(fid: 2, name: "plain")]
        try await file.save(sources: [Source(host: "forum.example", kind: .discuz, boards: boards)], notes: [])
        #expect(try file.load().sources.first?.boards == boards)
    }

    @Test("Chosen lists and what Home and they brought in survive a relaunch; boards are written as before")
    func listsRoundTrip() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lists = [ListSubscription(id: "42", name: "Friends"), ListSubscription(id: "7", name: "a:b \"q\" 🧵")]
        let signedIn = Source(host: "first.example", kind: .mastodon, lists: lists)
        let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 33, name: "a")])
        let saved = [
            note(id: "1", source: signedIn, categories: [.home, .list(id: "42")]),
            note(id: "2", source: signedIn, categories: [.public]),
        ]
        let file = try StoreFile(at: dir)
        try await file.save(sources: [signedIn, forum], notes: saved)
        let written = try await file.db.read { db in
            try String.fetchOne(db, sql: "SELECT boards FROM source WHERE host = 'forum.example'")
        }
        #expect(written == #"[{"fid":33,"name":"a"}]"#)
        let opened = StoreFile.open(at: dir)
        #expect(opened.setAside == nil)
        #expect(opened.sources == [signedIn, forum])
        #expect(opened.sources.first?.lists == lists)
        #expect(Set(opened.notes) == Set(saved))
    }

    @Test("A subscription that is neither a board nor a list, or both, fails the load, and the file is set aside",
          arguments: [#"[{"name":"x"}]"#, #"[{"fid":1,"list":"42","name":"x"}]"#])
    func neitherBoardNorList(row: String) async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [mastodon], notes: [])
        try await file.db.write { db in
            try db.execute(sql: "UPDATE source SET boards = ?", arguments: [row])
        }
        let opened = StoreFile.open(at: dir)
        #expect(opened.setAside != nil)
        #expect(opened.sources.isEmpty)
    }

    @Test("A second StoreFile on the same directory reads what the first saved")
    func reopenSameDirectory() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 3, name: "x")])
        let saved = note(source: source, categories: [.trends])
        try await StoreFile(at: dir).save(sources: [source], notes: [saved])
        let again = try StoreFile(at: dir)
        let loaded = try again.load()
        #expect(loaded.sources == [source])
        #expect(loaded.notes == [saved])
        try await again.save(sources: [], notes: [])
        #expect(try StoreFile(at: dir).load().sources.isEmpty)
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

@Suite("Opening the index at launch")
struct StoreFileOpenTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let garbage = Data("this is not a database, and it is the reader's only copy".utf8)

    @Test("A healthy index opens with what it held and sets nothing aside")
    func healthy() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = Source(host: "first.example", kind: .mastodon)
        try await StoreFile(at: dir).save(sources: [source], notes: [])
        let opened = StoreFile.open(at: dir)
        #expect(opened.file != nil)
        #expect(opened.sources == [source])
        #expect(opened.setAside == nil)
    }

    @Test("A directory with no index opens empty and writable")
    func fresh() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = StoreFile.open(at: dir)
        #expect(opened.file != nil)
        #expect(opened.sources.isEmpty && opened.notes.isEmpty)
        #expect(opened.setAside == nil)
        #expect(!opened.storeIsNewer)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.sqlite").path))
    }

    @Test("A corrupt index is moved aside, byte for byte, and a save does not touch it")
    func corruptIsSetAside() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try garbage.write(to: dir.appendingPathComponent("index.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let opened = StoreFile.open(at: dir, now: now)
        let aside = try #require(opened.setAside)
        #expect(aside.lastPathComponent.hasPrefix("index-unreadable-20270115T080000"))
        #expect(aside.pathExtension == "sqlite")
        #expect(opened.sources.isEmpty && opened.notes.isEmpty)
        let file = try #require(opened.file)
        let source = Source(host: "first.example", kind: .mastodon)
        try await file.save(sources: [source], notes: [])
        #expect(try Data(contentsOf: aside) == garbage)
        #expect(try StoreFile(at: dir).load().sources == [source])
    }

    @Test("Two indexes set aside at the same moment get two names, and both are kept")
    func twoInOneSecond() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try garbage.write(to: dir.appendingPathComponent("index.sqlite"))
        let first = try #require(StoreFile.open(at: dir, now: now).setAside)
        try garbage.write(to: dir.appendingPathComponent("index.sqlite"))
        let second = try #require(StoreFile.open(at: dir, now: now).setAside)
        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("An index whose migration fails is set aside, not migrated over")
    func failedMigrationIsSetAside() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A `source` table the migrator did not make: v1 cannot create its own over it.
        try await DatabaseQueue(path: dir.appendingPathComponent("index.sqlite").path).write { db in
            try db.execute(sql: "CREATE TABLE source (anything TEXT)")
            try db.execute(sql: "INSERT INTO source VALUES ('keep me')")
        }
        let opened = StoreFile.open(at: dir)
        let aside = try #require(opened.setAside)
        let kept = try await DatabaseQueue(path: aside.path).read { db in
            try String.fetchOne(db, sql: "SELECT anything FROM source")
        }
        #expect(kept == "keep me")
        #expect(opened.file != nil)
    }

    @Test("A row that cannot be decoded fails the load, and the file is set aside")
    func undecodableRowIsSetAside() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Source(host: "forum.example", kind: .discuz)], notes: [])
        try await file.db.write { db in
            try db.execute(sql: "UPDATE source SET boards = 'not json'")
        }
        let opened = StoreFile.open(at: dir)
        #expect(opened.setAside != nil)
        #expect(opened.sources.isEmpty)
    }

    @Test("A note whose categories are not JSON fails the load, and the file is set aside unchanged")
    func undecodableCategoriesAreSetAside() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = Source(host: "first.example", kind: .mastodon)
        let note = Note(id: "1", source: source, author: "Ada", handle: "@ada", body: "hello",
                        postedAt: origin, categories: [.public])
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [source], notes: [note])
            try await file.db.write { db in
                try db.execute(sql: "UPDATE note SET categories = 'not json'")
            }
        }
        let before = try Data(contentsOf: dir.appendingPathComponent("index.sqlite"))
        let opened = StoreFile.open(at: dir)
        let aside = try #require(opened.setAside)
        #expect(try Data(contentsOf: aside) == before)
        #expect(opened.sources.isEmpty && opened.notes.isEmpty)
    }

    @Test("An index from a newer build is left alone: no file, not set aside, bytes unchanged")
    func newerStoreIsLeftAlone() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let file = try StoreFile(at: dir)
            try await file.save(sources: [Source(host: "first.example", kind: .mastodon)], notes: [])
            // What a newer build leaves behind: a migration this one has never heard of.
            try await file.db.write { db in
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v9-from-a-newer-build')")
            }
        }
        let index = dir.appendingPathComponent("index.sqlite")
        let before = try Data(contentsOf: index)
        let touched = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        let listed = try FileManager.default.contentsOfDirectory(atPath: dir.path)

        let opened = StoreFile.open(at: dir)
        let again = StoreFile.open(at: dir)

        #expect(opened.file == nil)
        #expect(again.file == nil && again.storeIsNewer)
        #expect(opened.storeIsNewer)
        #expect(opened.setAside == nil)
        #expect(opened.sources.isEmpty && opened.notes.isEmpty)
        #expect(try Data(contentsOf: index) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date == touched)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == listed.sorted())
    }

    @Test("An unreadable index is not mistaken for a newer one")
    func unreadableIsNotNewer() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try garbage.write(to: dir.appendingPathComponent("index.sqlite"))
        let opened = StoreFile.open(at: dir)
        #expect(!opened.storeIsNewer)
        #expect(opened.setAside != nil)
    }

    @Test("When the directory cannot be made, the run gets no file to save to")
    func noDirectoryNoFile() throws {
        let blocker = scratch()
        defer { try? FileManager.default.removeItem(at: blocker) }
        try garbage.write(to: blocker)
        let opened = StoreFile.open(at: blocker.appendingPathComponent("Fediqo", isDirectory: true))
        #expect(opened.file == nil)
        #expect(opened.setAside == nil)
        #expect(try Data(contentsOf: blocker) == garbage)
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
