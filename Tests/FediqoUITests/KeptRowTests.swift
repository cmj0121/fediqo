import AppKit
import FediqoPersistence
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// An item the person keeps is never let go (#284), from the session down.
///
/// What a test can reach: the press and the key keeping a row and un-keeping it, written once;
/// every way the session lets posts go — by dates, by either limit, by a source's removal, by
/// what is marked gone, by a take-back — leaving a kept row and counting only the others; the
/// mark a row draws; the key, its line in the keys list, and every word in both languages. What
/// it cannot: the mark in light and dark, on a Mac and a phone — that lives in a view body.
@MainActor
@Suite("A kept row stays", .serialized)
struct KeptRowTests {
    private static let alpha = LimitRoom.alpha
    private static let beta = LimitRoom.beta
    private static let origin = LimitRoom.origin

    private static func note(_ id: String, daysAgo: Double = 1, from source: Source = alpha) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada@\(source.host)", body: "hello \(id)",
            postedAt: origin.addingTimeInterval(-daysAgo * 86_400), categories: [.public], statusID: id
        )
    }

    /// A session holding `notes` on both sources, read back from its store as a launch reads one.
    private static func shell(_ notes: [Note], pictures: ShellPictures? = nil) async -> ShellSession {
        let store = ItemStore(sources: [alpha, beta], notes: notes)
        let session = ShellSession(
            http: FixtureHTTP(), store: store, pictures: pictures ?? ShellPictures(http: FixtureHTTP())
        )
        await session.reloadFromStore()
        return session
    }

    private static func row(_ session: ShellSession, _ id: String) throws -> DummyItem {
        try #require(session.timelineItems(latest: nil).first { $0.noteID == id })
    }

    // MARK: - The press

    @Test("Keeping a row marks it in the store and on the row, written once; the same press un-keeps it")
    func pressKeepsAndUnkeeps() async throws {
        let session = await Self.shell([Self.note("1"), Self.note("2")])
        var saved = 0
        session.persist = { saved += 1 }

        #expect(await session.toggleKept(try Self.row(session, "1")) == true)
        #expect(try Self.row(session, "1").kept)
        #expect(try !Self.row(session, "2").kept, "nothing else moved")
        #expect(await session.store.note(Self.note("1").key)?.kept == true)
        await session.saved()
        #expect(saved == 1)
        #expect(Self.names("item.toast.kept.on").contains(session.toast?.text ?? ""), "the mark and y say it alike")

        #expect(await session.toggleKept(try Self.row(session, "1")) == false)
        #expect(try !Self.row(session, "1").kept)
        #expect(await session.store.note(Self.note("1").key)?.kept == false)
        await session.saved()
        #expect(saved == 2)
    }

    @Test("A row the store does not hold is not kept, nothing is written, and nothing is said to have happened")
    func nothingHeldNothingKept() async {
        let session = await Self.shell([Self.note("1")])
        var saved = 0
        session.persist = { saved += 1 }
        #expect(await session.toggleKept(DummyItem(Self.note("stranger"))) == nil)
        await session.saved()
        #expect(saved == 0)
        #expect(session.toast == nil, "nothing happened, so nothing is said")
    }

    @Test("Keeping a row two sources carried keeps every copy, and un-keeping it un-keeps them all")
    func mergedRowKeepsEveryCopy() async throws {
        let uri = "https://origin.example/users/ada/statuses/1"
        let session = await Self.shell([Self.note(uri, from: Self.alpha), Self.note(uri, from: Self.beta)])
        let row = try #require(session.timelineItems(latest: nil).first)
        #expect(row.copies.count == 2)

        await session.setKept(true, on: row)

        #expect(await session.store.snapshot().notes.map(\.kept) == [true, true])
        let kept = try #require(session.timelineItems(latest: nil).first)
        #expect(kept.kept)
        // One copy un-kept behind the row's back: the row still says kept, and the press un-keeps.
        await session.store.setKept(false, for: Self.note(uri, from: Self.alpha).key)
        await session.reloadFromStore()
        let half = try #require(session.timelineItems(latest: nil).first)
        #expect(half.kept)
        #expect(await session.toggleKept(half) == false)
        #expect(await session.store.snapshot().notes.map(\.kept) == [false, false])
    }

    // MARK: - Letting go by dates

    @Test("Kept, then let go by dates across its day: it stays and the others go, and the question counted only the others")
    func spanLeavesKept() async throws {
        let session = await Self.shell([Self.note("kept"), Self.note("other"), Self.note("beta", from: Self.beta)])
        await session.setKept(true, on: try Self.row(session, "kept"))
        let day = Self.origin.addingTimeInterval(-1.5 * 86_400)..<Self.origin.addingTimeInterval(-0.5 * 86_400)

        #expect(await session.spanHeld(day, host: nil) == 2)
        #expect(await session.letGo(span: day, host: nil) == 2)

        #expect(session.notes.map(\.id) == ["kept"])
        #expect(await session.spanHeld(day, host: nil) == 0)
    }

    // MARK: - The limits

    @Test("The room limit reached: the kept post, the oldest held, is still there, and the account does not count it")
    func roomLeavesKept() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: LimitRoom.held() + [LimitRoom.note("kept", daysAgo: 300, from: Self.alpha)])
        let kept = try #require(room.session.notes.first { $0.id == "kept" })
        await room.session.setKept(true, on: DummyItem(kept))
        await room.session.saved()
        room.session.roomBytes = room.index / 2

        let act = try #require(await room.session.keepWithinRoom(at: Self.origin))

        #expect(act.posts > 0)
        let left = room.session.notes
        #expect(left.contains { $0.id == "kept" && $0.kept }, "the limit took a kept post")
        #expect(left.count == 61 - act.posts, "the account counts what went, and the kept post did not")
        #expect(room.session.limitAccount.first?.posts == act.posts)
        #expect(try room.file.load().notes.contains { $0.id == "kept" && $0.kept }, "and it is kept on disk")
    }

    @Test("Only kept posts left over the room: nothing goes, and the limit writes no line")
    func roomWithOnlyKept() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: (0..<8).map { LimitRoom.note("\($0)", daysAgo: Double($0), from: Self.alpha) })
        for note in room.session.notes { await room.session.setKept(true, on: DummyItem(note)) }
        room.session.roomBytes = 1_000

        #expect(await room.session.keepWithinRoom(at: Self.origin) == nil)

        #expect(room.session.notes.count == 8)
        #expect(room.session.limitAccount.isEmpty)
    }

    // Copies written behind the cache's back after a check has measured them are measured again
    // by `disk.trim()` — the launch's own measure, queued ahead of the check's — so the check
    // judges what is really on disk.

    /// Eight kept posts, which alone weigh far more than a room of a thousand bytes.
    private static func keptRoom(at dir: URL) async throws -> LimitRoom {
        let room = try await LimitRoom(at: dir, notes: (0..<8).map { LimitRoom.note("\($0)", daysAgo: Double($0), from: alpha) })
        for note in room.session.notes { await room.session.setKept(true, on: DummyItem(note)) }
        return room
    }

    @Test("Kept posts alone past the room, with picture copies on disk: the Room says so, and no check lets anything go, rebuilds the index or writes a line")
    func roomHeldByKeptIsQuiet() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await Self.keptRoom(at: dir)
        try room.copies(2, of: 10_000, host: Self.alpha.host)
        room.session.roomBytes = 1_000

        #expect(await room.session.keepWithinRoom(at: Self.origin) == nil)
        #expect(room.session.roomHeldByKept)
        let rebuilt = room.compaction.ran

        // Pictures read since: left where they are, for no trim could reach the room.
        try room.copies(2, of: 10_000, host: Self.alpha.host, from: 2)
        room.pictures.disk?.trim()
        for _ in 0..<3 {
            #expect(await room.session.keepWithinRoom(at: Self.origin) == nil)
        }
        #expect(room.cache.count() == 4, "a copy was trimmed though nothing could bring the store within its room")
        #expect(room.compaction.ran == rebuilt, "the index was rebuilt with nothing to give back")
        #expect(room.session.limitAccount.isEmpty, "a check that let nothing go wrote a line")
        #expect(room.session.notes.count == 8)
        #expect(room.session.roomHeldByKept)

        // Room enough again, or no limit: it stops saying so.
        room.session.roomBytes = 100_000_000
        #expect(await room.session.keepWithinRoom(at: Self.origin) == nil)
        #expect(!room.session.roomHeldByKept)
        room.session.roomHeldByKept = true
        room.session.roomBytes = nil
        #expect(!room.session.roomHeldByKept)
    }

    @Test("A post that arrives, not kept, while kept posts hold the store past its room: the picture copies go before it does, and no kept post goes")
    func arrivalWhileKeptHoldTrimsCopiesFirst() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await Self.keptRoom(at: dir)
        room.session.roomBytes = 1_000
        #expect(await room.session.keepWithinRoom(at: Self.origin) == nil)
        #expect(room.session.roomHeldByKept)
        try room.copies(2, of: 10_000, host: Self.alpha.host)
        room.pictures.disk?.trim()

        await room.session.store.ingest([LimitRoom.note("late", daysAgo: 0.5, from: Self.beta)])
        await room.session.reloadFromStore()
        let act = try #require(await room.session.keepWithinRoom(at: Self.origin))

        #expect(act.copies == 2, "a post went while picture copies that go first were still on disk")
        #expect(act.posts == 1)
        #expect(room.cache.count() == 0)
        #expect(room.session.notes.count == 8 && room.session.notes.allSatisfy(\.kept))
        #expect(room.session.roomHeldByKept, "and the kept posts hold it over still")
    }

    /// Forty posts, all kept, the room half the index, and the check that finds it cannot be met.
    private static func heldOver(at dir: URL, limit: Int? = nil) async throws -> (LimitRoom, Int) {
        let room = try await LimitRoom(at: dir, notes: (0..<40).map { LimitRoom.note("\($0)", daysAgo: Double($0), from: alpha) })
        for note in room.session.notes { await room.session.setKept(true, on: DummyItem(note)) }
        await room.session.saved()
        let limit = limit ?? room.index / 2
        room.session.roomBytes = limit
        #expect(await room.session.keepWithinRoom(at: origin) == nil)
        #expect(room.session.roomHeldByKept)
        return (room, limit)
    }

    @Test("Un-keeping while kept posts hold the store past its room lets the limit act again, copies first: no post goes that trimming the copies spares")
    func unkeepingLetsTheRoomAct() async throws {
        let dir = LimitRoom.scratch()
        let twinDir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: twinDir) }
        let (room, limit) = try await Self.heldOver(at: dir)
        // The same store with no picture copy on disk: what the index alone costs in posts.
        let (twin, _) = try await Self.heldOver(at: twinDir, limit: limit)
        for note in twin.session.notes { await twin.session.setKept(false, on: DummyItem(note)) }
        let alone = try #require(await twin.session.keepWithinRoom(at: Self.origin)).posts
        #expect(alone > 0)

        // Copies that piled up while nothing could go, and then the posts are un-kept.
        try room.copies(4, of: 20_000, host: Self.alpha.host)
        room.pictures.disk?.trim()
        for note in room.session.notes { await room.session.setKept(false, on: DummyItem(note)) }
        let act = try #require(await room.session.keepWithinRoom(at: Self.origin))

        #expect(act.copies > 0, "posts went while picture copies that go first were still on disk")
        #expect(act.posts > 0 && act.posts <= alone, "\(act.posts) posts went where the index alone asked for \(alone)")
        #expect(!room.session.roomHeldByKept)
        #expect(room.index <= limit, "the index still weighs more than the room")
        #expect(room.session.notes.count == 40 - act.posts)
    }

    @Test("What the Room says where kept posts hold it over, in both languages, and nothing where they do not",
          arguments: [DummyLanguage.english, .taiwanese])
    func roomSaysKeptHoldIt(language: DummyLanguage) {
        #expect(UsagePane.roomKeptLine(heldByKept: false, language: language) == nil)
        let line = UsagePane.roomKeptLine(heldByKept: true, language: language)
        #expect(line != nil && line != "prefs.room.kept")
    }

    @Test("The months limit reached: the kept post past the window is still there, and the account counts only the other")
    func monthsLeavesKept() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: [
            LimitRoom.note("kept", daysAgo: 400, from: Self.alpha), LimitRoom.note("old", daysAgo: 400, from: Self.beta),
            LimitRoom.note("new", daysAgo: 1, from: Self.alpha),
        ])
        await room.session.setKept(true, on: DummyItem(try #require(room.session.notes.first { $0.id == "kept" })))

        #expect(await room.session.keep(months: 3, from: Self.origin) == 1)

        #expect(room.session.notes.map(\.id) == ["new", "kept"])
        let line = try #require(room.session.limitAccount.first)
        #expect(line.limit == .months && line.posts == 1 && line.sources == ["beta.test"])
        // With nothing but the kept post past the window, the limit has nothing to say.
        #expect(await room.session.keep(months: 1, from: Self.origin) == 0)
        #expect(room.session.limitAccount.count == 1)
    }

    // MARK: - Its source removed

    @Test("Its source removed with its posts going: the kept post is still drawn, marked as from a source no longer here, and nothing is asked of that host")
    func removalLeavesKept() async throws {
        let pictures = ShellPictures(http: FixtureHTTP())
        let session = await Self.shell(
            [Self.note("kept", from: Self.beta), Self.note("other", from: Self.beta), Self.note("alpha")],
            pictures: pictures
        )
        await session.setKept(true, on: try Self.row(session, "kept"))
        let generation = pictures.generation

        await session.remove(host: Self.beta.host, keepingPosts: false)

        #expect(session.sources == [Self.alpha])
        #expect(Set(session.notes.map(\.id)) == ["kept", "alpha"])
        let row = try Self.row(session, "kept")
        #expect(row.kept)
        #expect(DummyItemRow.sourceLeft(row, here: Set(session.sources.map(\.host))))
        #expect(pictures.generation == generation, "the kept row was told to ask a host nothing may ask")
    }

    @Test("A source removed with nothing of it kept goes as it always did")
    func removalWithNothingKept() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        let session = await Self.shell([Self.note("other", from: Self.beta), Self.note("alpha")], pictures: pictures)
        let generation = pictures.generation
        await session.remove(host: Self.beta.host, keepingPosts: false)
        #expect(session.notes.map(\.id) == ["alpha"])
        #expect(pictures.generation == generation + 1)
    }

    // MARK: - Gone from its source

    @Test("Kept and said gone by its source: still there after everything marked has waited and is let go")
    func goneLeavesKept() async throws {
        let session = await Self.shell([Self.note("kept"), Self.note("other"), Self.note("fine")])
        await session.setKept(true, on: try Self.row(session, "kept"))
        await session.markGone(Self.note("kept").key, at: Self.origin)
        await session.markGone(Self.note("other").key, at: Self.origin)

        let later = Self.origin.addingTimeInterval(9 * 86_400)
        #expect(await session.letGoneGo(waitingDays: 1, keepingMonths: nil, from: later) == WentGone(posts: 1))

        #expect(Set(session.notes.map(\.id)) == ["kept", "fine"])
        let row = try Self.row(session, "kept")
        #expect(row.kept && row.goneEverywhere, "still kept, still marked")
        #expect(await session.letGoneGo(waitingDays: 1, keepingMonths: nil, from: later).isNone)
        // Un-kept, it is an ordinary marked post, and goes with the next letting go.
        #expect(await session.toggleKept(row) == false)
        #expect(await session.letGoneGo(waitingDays: 1, keepingMonths: nil, from: later) == WentGone(posts: 1))
        #expect(session.notes.map(\.id) == ["fine"])
    }

    @Test("A kept post of your own taken back at its source stays, marked gone, and offers nothing more")
    func takenBackStaysMarked() async throws {
        let host = "social.example"
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
            scopes: MastodonOAuth.scopes(writing: true)
        ))
        let server = ActServer([
            "/api/v1/accounts/verify_credentials": .json(#"{"acct":"me"}"#),
            "/api/v1/statuses/1": .json("{}"),
        ])
        let source = Source(host: host, kind: .mastodon)
        let mine = Note(
            id: "https://social.example/users/me/statuses/1", source: source, author: "Me",
            handle: "@me@social.example", body: "mine", postedAt: Self.origin, categories: [.home], statusID: "1"
        )
        let store = ItemStore(sources: [source], notes: [mine])
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.mastodon.verifyAll()
        await session.reloadFromStore()
        let row = DummyItem(try #require(session.notes.first))
        await session.setKept(true, on: row)

        await session.withdraw(DummyItem(try #require(session.notes.first)))

        #expect(await server.requests.last?.httpMethod == "DELETE")
        let stayed = try #require(session.notes.first)
        #expect(stayed.kept && stayed.goneSince != nil)
        #expect(!session.acts(on: DummyItem(stayed)).offers(.withdraw), "nothing can be sent to a post its source no longer has")
    }

    // MARK: - In an open thread

    private static let host = "one.example"
    private static let threadPath = "/api/v1/statuses/9/context"

    private static func status(_ id: String, answering parent: String, replies: Int = 0) -> String {
        """
        {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)","in_reply_to_id":"\(parent)",
         "replies_count":\(replies),
         "created_at":"2024-01-01T00:00:00.000Z","content":"<p>answer \(id)</p>",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static func contextJSON(ancestors: [String] = [], _ descendants: [String]) -> String {
        #"{"ancestors":["# + ancestors.joined(separator: ",") + #"],"descendants":["#
            + descendants.joined(separator: ",") + "]}"
    }

    private static func context(ancestors: [String] = [], _ descendants: [String]) -> FixtureHTTP.Outcome {
        .text(contextJSON(ancestors: ancestors, descendants))
    }

    /// The post 9 under an ancestor 8, its thread cut after 11, whose own thread has 12.
    private static let thread: [String: FixtureHTTP.Outcome] = [
        threadPath: context(
            ancestors: [status("8", answering: "7")],
            [status("10", answering: "9"), status("11", answering: "9", replies: 1)]
        ),
        "/api/v1/statuses/11/context": context([status("12", answering: "11")]),
    ]

    /// A session holding post 9 with its conversation open in front, as the pane opens it.
    private static func threadShell() async -> (ShellSession, DummyItem) {
        let source = Source(host: host, kind: .mastodon)
        let root = Note(
            id: "https://\(host)/users/ada/statuses/9", source: source, author: "Ada",
            handle: "@ada@\(host)", body: "the post", postedAt: origin, categories: [.public],
            // It says what it answers, as its source's copy does: that is what puts 8 above it (#293).
            reply: Reply(inReplyToId: "8"), statusID: "9"
        )
        let http = FixtureHTTP(thread)
        let session = ShellSession(
            http: http, store: ItemStore(sources: [source], notes: [root]), posts: ForumPosts(http: http)
        )
        await session.reloadFromStore()
        let item = DummyItem(root)
        await session.reload.opened(item, in: session)
        return (session, item)
    }

    /// The row a thread draws for the post its source numbers `id`, an ancestor or an answer.
    private static func drawn(_ session: ShellSession, _ item: DummyItem, _ id: String) throws -> DummyItem {
        let conversation = session.conversations.conversation(around: item)
        return try #require((conversation.ancestors + conversation.descendants.map(\.item)).first { $0.statusID == id })
    }

    @Test("A kept answer and a kept ancestor are still drawn kept after the thread is read again and read further, and the press un-keeps them")
    func threadReadAgainDrawsTheStoresWord() async throws {
        let (session, item) = try await Self.threadShell()
        #expect(await session.toggleKept(try Self.drawn(session, item, "10")) == true)
        #expect(await session.toggleKept(try Self.drawn(session, item, "8")) == true)
        #expect(try Self.drawn(session, item, "10").kept)

        await session.conversations.again(item, in: session)

        #expect(try Self.drawn(session, item, "10").kept, "a thread read again drew a kept answer as not kept")
        #expect(try Self.drawn(session, item, "8").kept, "and a kept ancestor")
        #expect(try !Self.drawn(session, item, "11").kept, "nothing else is kept for it")

        await session.conversations.more(item, in: session)
        #expect(try Self.drawn(session, item, "12").statusID == "12", "the thread was read further")
        #expect(try Self.drawn(session, item, "10").kept)
        #expect(await session.toggleKept(try Self.drawn(session, item, "12")) == true)
        await session.conversations.again(item, in: session)
        #expect(try Self.drawn(session, item, "12").kept, "an answer read further, kept, then read again")

        #expect(await session.toggleKept(try Self.drawn(session, item, "10")) == false, "the press un-keeps it")
        #expect(try !Self.drawn(session, item, "10").kept)
        let key = NoteKey(host: Self.host, id: "https://\(Self.host)/users/ada/statuses/10")
        #expect(await session.store.note(key)?.kept == false)
    }

    @Test("A kept answer of your own taken back from inside an open thread stays drawn there, marked gone and still kept")
    func takenBackInAThreadStays() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
            scopes: MastodonOAuth.scopes(writing: true)
        ))
        let server = ActServer([
            "/api/v1/accounts/verify_credentials": .json(#"{"acct":"ada"}"#),
            "/api/v1/statuses/10": .json("{}"),
            "/api/v1/statuses/11": .json("{}"),
            // Signed in, the thread is read through the same door the acts go through.
            Self.threadPath: .json(Self.contextJSON([Self.status("10", answering: "9"), Self.status("11", answering: "9")])),
        ])
        let source = Source(host: Self.host, kind: .mastodon)
        let root = Note(
            id: "https://\(Self.host)/users/bo/statuses/9", source: source, author: "Bo",
            handle: "@bo@\(Self.host)", body: "the post", postedAt: Self.origin, categories: [.public], statusID: "9"
        )
        let http = FixtureHTTP()
        let session = ShellSession(
            http: http, store: ItemStore(sources: [source], notes: [root]),
            mastodon: MastodonSessions(tokens: tokens, sender: server), posts: ForumPosts(http: http)
        )
        session.mastodon.refresh()
        await session.mastodon.verifyAll()
        await session.reloadFromStore()
        let item = DummyItem(root)
        await session.reload.opened(item, in: session)
        await session.toggleKept(try Self.drawn(session, item, "10"))
        let mine = try Self.drawn(session, item, "10")
        #expect(session.acts(on: mine).offers(.withdraw), "the fixture's answers are the reader's own")

        await session.withdraw(mine)

        #expect(await server.requests.last?.httpMethod == "DELETE")
        let stayed = try Self.drawn(session, item, "10")
        #expect(stayed.kept && stayed.goneSince != nil, "dropped from the thread, or drawn as it was")
        // One not kept, taken back the same way, leaves the thread as it always did.
        await session.withdraw(try Self.drawn(session, item, "11"))
        let left = session.conversations.conversation(around: item).descendants.map(\.item.statusID)
        #expect(left == ["10"])
    }

    // MARK: - A relaunch

    @Test("Quit and open again: the row is still kept, from the file the press wrote")
    func relaunchKeepsItKept() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let room = try await LimitRoom(at: dir, notes: [LimitRoom.note("1", daysAgo: 1, from: Self.alpha), LimitRoom.note("2", daysAgo: 2, from: Self.alpha)])
        await room.session.setKept(true, on: DummyItem(try #require(room.session.notes.first { $0.id == "2" })))
        await room.session.saved()

        let opened = StoreFile.open(at: dir)
        let again = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: opened.sources, notes: opened.notes))
        await again.reloadFromStore()

        #expect(again.timelineItems(latest: nil).map(\.kept) == [false, true])
    }

    // MARK: - The mark, the key and the words

    /// The names of the marks a row lays out.
    private static func marks(_ item: DummyItem) -> Set<String> {
        let probe = RowBandProbe()
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), probe: probe)
        let host = NSHostingView(rootView: row.frame(width: 720))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return Set(probe.marks.keys)
    }

    /// A mark's name in every language a row may be drawn in, since the row reads the shell's.
    private static func names(_ key: String) -> Set<String> {
        Set([DummyLanguage.english, .taiwanese].map { L10n.t(key, language: $0) })
    }

    @Test("The row draws the keep mark off what the store holds: named Keep where it is not kept, and Stop keeping where it is")
    func rowDrawsTheStoresWord() {
        var kept = Self.note("1")
        kept.kept = true
        let keep = Self.names("item.act.keep")
        let unkeep = Self.names("item.act.unkeep")
        #expect(keep.isDisjoint(with: unkeep))
        #expect(!Self.marks(DummyItem(Self.note("1"))).isDisjoint(with: keep))
        #expect(Self.marks(DummyItem(Self.note("1"))).isDisjoint(with: unkeep))
        #expect(!Self.marks(DummyItem(kept)).isDisjoint(with: unkeep))
        #expect(Self.marks(DummyItem(kept)).isDisjoint(with: keep))
        // The item carries it; a pane's own copy of the marks is not asked.
        #expect(DummyItem(kept).marks.kept && !DummyItem(Self.note("1")).marks.kept)
    }

    @Test("y keeps, is the draft's while typing, and has its line among the acts")
    func theKey() throws {
        #expect(DummyCommand.from("y") == .keep)
        #expect(DummyCommand.from("y", typing: true) == nil)
        #expect(DummyCommand.from("y", fieldFocused: true) == nil)
        let line = try #require(DummyShortcut.all.first { $0.commands == [.keep] })
        #expect(line.keys == ["y"] && line.group == .act && line.touch == .press)
    }

    @Test("Every word of keeping is written in the language asked for", arguments: [DummyLanguage.english, .taiwanese])
    func words(language: DummyLanguage) {
        for key in ["item.act.keep", "item.act.unkeep", "item.toast.kept.on", "item.toast.kept.off", "shortcut.keep"] {
            #expect(L10n.t(key, language: language) != key, "\(key) is not written in \(language)")
        }
        #expect(L10n.t("item.act.keep", language: language) != L10n.t("item.act.unkeep", language: language))
    }
}
