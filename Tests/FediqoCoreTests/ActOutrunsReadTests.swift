import Foundation
import Testing
@testable import FediqoCore

/// What the reader just did to a post is not undone by a read already on its way (#291), in the
/// half of it Core holds: every read of a status says when it was sent, the store marks a post
/// as the answer to an act on it lands, and a copy sent before that mark leaves what the row
/// says the reader did.
///
/// A read "on its way" is made here by taking its moment (`ReadMoment.now()`) before the act and
/// handing its copy to the store after — which is all a read on its way is to the store.
@Suite("An act is not undone by a read already on its way")
struct ActOutrunsReadTests {
    private let host = MastodonFixture.host
    private let source = Source(host: MastodonFixture.host, kind: .mastodon)

    enum Act: String, CaseIterable, Sendable {
        case favourite, boost, bookmark

        func path(_ on: Bool) -> String {
            switch self {
            case .favourite: on ? "favourite" : "unfavourite"
            case .boost: on ? "reblog" : "unreblog"
            case .bookmark: on ? "bookmark" : "unbookmark"
            }
        }

        func mark(_ note: Note?) -> Bool? {
            switch self {
            case .favourite: note?.favourited
            case .boost: note?.boosted
            case .bookmark: note?.bookmarked
            }
        }
    }

    /// Post 9 as `host` sends it to its reader, saying `said` of all three marks — or of none,
    /// which is a read made signed out.
    private static func status(_ said: Bool?, host: String = MastodonFixture.host, favourites: Int = 0) -> String {
        let flags = said.map { #","favourited":\#($0),"reblogged":\#($0),"bookmarked":\#($0)"# } ?? ""
        return """
        {"id":"9","uri":"https://social.example/users/ada/statuses/9",
         "created_at":"2024-06-01T00:00:00.000Z","content":"<p>hello</p>",
         "visibility":"public","favourites_count":\(favourites)\(flags),
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    /// The copy a read sent at `sent` brings.
    private func copy(_ said: Bool?, sent: ReadMoment, through source: Source? = nil, favourites: Int = 0) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Self.status(said, favourites: favourites).utf8))
            .asNote(source: source ?? self.source, category: .home, sent: sent)
    }

    /// A store holding post 9 as its source last said it, and a signed-in reader whose acts the
    /// server answers as `routes` say.
    private func reader(
        holding said: Bool?, _ routes: [String: FixtureSender.Outcome]
    ) async throws -> (MastodonWrite, ItemStore) {
        let store = ItemStore()
        await store.add(source)
        await store.ingest([try copy(said, sent: .now())], ifSourceHere: host)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: FixtureSender(routes), store: tokens)
        return (MastodonWrite(door: door, store: store), store)
    }

    private func press(_ act: Act, _ on: Bool, with write: MastodonWrite, in store: ItemStore) async throws {
        let row = try #require(await store.all().first)
        switch act {
        case .favourite: try await write.favourite(row, on: on)
        case .boost: try await write.boost(row, on: on)
        case .bookmark: try await write.bookmark(row, on: on)
        }
    }

    /// The server's answer to `act` put (`on`) or taken back: the post saying so of that one mark
    /// and the opposite of the other two, as it said before.
    private static func answer(_ act: Act, _ on: Bool) -> String {
        func flag(_ mine: Act) -> Bool { mine == act ? on : !on }
        return """
        {"id":"9","uri":"https://social.example/users/ada/statuses/9",
         "created_at":"2024-06-01T00:00:00.000Z","content":"<p>hello</p>","visibility":"public",
         "favourited":\(flag(.favourite)),"reblogged":\(flag(.boost)),"bookmarked":\(flag(.bookmark)),
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    // MARK: - The order of the run

    @Test("Each moment taken is later than every one before it, and a moment is no part of what a note is")
    func theOrder() throws {
        let first = ReadMoment.now()
        let second = ReadMoment.now()
        #expect(try #require(first.place) < (try #require(second.place)))
        #expect(ReadMoment.unsaid.place == nil)

        let early = try copy(true, sent: first)
        let late = try copy(true, sent: second)
        #expect(early.asked.place == first.place && late.asked.place == second.place)
        #expect(early == late, "two copies saying the same are one note whenever each was asked for")
        #expect(early.hashValue == late.hashValue)
        #expect(Set([early, late]).count == 1)
    }

    @Test("The store keeps nothing of when a copy was sent")
    func theStoreKeepsNone() async throws {
        let store = ItemStore()
        await store.add(source)
        await store.ingest([try copy(false, sent: .now())], ifSourceHere: host)
        #expect(await store.all().first?.asked.place == nil)
        await store.ingest([try copy(true, sent: .now())], ifSourceHere: host)
        #expect(await store.all().first?.asked.place == nil)
        await store.refresh([try copy(false, sent: .now())], ifSourceHere: host)
        #expect(await store.all().first?.asked.place == nil)
    }

    // MARK: - A read on its way

    @Test(
        "A reload sent before the act and landing after its answer leaves the mark the act set — put or taken back",
        arguments: Act.allCases, [true, false]
    )
    func aReloadOnItsWay(act: Act, on: Bool) async throws {
        let (write, store) = try await reader(holding: !on, [
            "/api/v1/statuses/9/\(act.path(on))": .json(Self.answer(act, on)),
        ])
        let onItsWay = ReadMoment.now()
        try await press(act, on, with: write, in: store)
        #expect(act.mark(await store.all().first) == on, "the premise: the act landed")
        let revision = await store.revision

        // The timeline asked before the press, saying what was true then, and landing now.
        await store.ingest([try copy(!on, sent: onItsWay, favourites: 7)], ifSourceHere: host)
        let row = try #require(await store.all().first)
        #expect(act.mark(row) == on, "a reload on its way put the mark back")
        #expect(row.counts.favourites == 7, "what it says of the post still lands")
        #expect(await store.revision == revision, "and a count alone is not written down")
    }

    @Test(
        "A read of the post or its thread sent before the act leaves the mark too",
        arguments: Act.allCases, [true, false]
    )
    func aReadAgainOnItsWay(act: Act, on: Bool) async throws {
        let (write, store) = try await reader(holding: !on, [
            "/api/v1/statuses/9/\(act.path(on))": .json(Self.answer(act, on)),
        ])
        let onItsWay = ReadMoment.now()
        try await press(act, on, with: write, in: store)

        await store.refresh([try copy(!on, sent: onItsWay, favourites: 7)], ifSourceHere: host)
        let row = try #require(await store.all().first)
        #expect(act.mark(row) == on, "a thread read on its way put the mark back")
        #expect(row.counts.favourites == 7)
    }

    // MARK: - A read asked afterwards

    @Test(
        "A read sent after the act that says otherwise — it was undone elsewhere — changes the mark, on a reload and on a read again",
        arguments: Act.allCases, [true, false]
    )
    func aReadAskedAfterwards(act: Act, on: Bool) async throws {
        let (write, store) = try await reader(holding: !on, [
            "/api/v1/statuses/9/\(act.path(on))": .json(Self.answer(act, on)),
        ])
        try await press(act, on, with: write, in: store)
        #expect(act.mark(await store.all().first) == on)

        await store.ingest([try copy(!on, sent: .now())], ifSourceHere: host)
        #expect(act.mark(await store.all().first) == !on, "a reload asked afterwards is the source's word")

        try await press(act, on, with: write, in: store)
        #expect(act.mark(await store.all().first) == on)
        await store.refresh([try copy(!on, sent: .now())], ifSourceHere: host)
        #expect(act.mark(await store.all().first) == !on, "and so is the post read again afterwards")
    }

    @Test("A read sent after the act but made signed out says nothing, and the mark stands")
    func aSignedOutReadAfterwards() async throws {
        let (write, store) = try await reader(holding: false, [
            "/api/v1/statuses/9/favourite": .json(Self.answer(.favourite, true)),
        ])
        try await press(.favourite, true, with: write, in: store)
        await store.ingest([try copy(nil, sent: .now())], ifSourceHere: host)
        #expect(await store.all().first?.favourited == true)
    }

    // MARK: - An act that did not land

    @Test("An act the source turns away marks nothing: a read sent before it lands as any read does")
    func aFailedActMarksNothing() async throws {
        let (write, store) = try await reader(holding: false, ["/api/v1/statuses/9/favourite": .fail])
        let before = ReadMoment.now()
        await #expect(throws: (any Error).self) {
            try await press(.favourite, true, with: write, in: store)
        }
        #expect(await store.all().first?.favourited == false, "the premise: nothing landed")

        // Favourited elsewhere meanwhile, and the read that says so was sent before the press.
        await store.ingest([try copy(true, sent: before)], ifSourceHere: host)
        #expect(await store.all().first?.favourited == true, "a press that never landed held a read's word back")
    }

    // MARK: - Two copies of one post

    @Test("An act on one source's copy of a post holds back that source's read on its way, and nothing of the other source's copy")
    func twoCopies() async throws {
        let other = Source(host: "other.example", kind: .mastodon)
        let (write, store) = try await reader(holding: false, [
            "/api/v1/statuses/9/favourite": .json(Self.answer(.favourite, true)),
        ])
        await store.add(other)
        await store.ingest([try copy(false, sent: .now(), through: other)], ifSourceHere: other.host)
        #expect(await store.all().count == 2, "the premise: one post, two rows")
        func favourited(_ host: String) async -> Bool? {
            await store.all().first { $0.source.host == host }?.favourited
        }

        let onItsWay = ReadMoment.now()
        let acted = try #require(await store.all().first { $0.source.host == host })
        try await write.favourite(acted, on: true)
        #expect(await favourited(host) == true)
        #expect(await favourited(other.host) == false, "the other source's reader did nothing")

        // The other source's read, sent before the act, says its own reader's word and lands.
        await store.ingest([try copy(true, sent: onItsWay, through: other)], ifSourceHere: other.host)
        #expect(await favourited(other.host) == true, "an act through one source held back the other's read")
        // The acted copy's own read on its way does not.
        await store.ingest([try copy(false, sent: onItsWay)], ifSourceHere: host)
        #expect(await favourited(host) == true)
    }

    // MARK: - The sign-in ending

    @Test("A sign-in ending still takes the marks away, and a read sent before the act does not bring them back")
    func theSweep() async throws {
        let (write, store) = try await reader(holding: false, [
            "/api/v1/statuses/9/favourite": .json(Self.answer(.favourite, true)),
        ])
        let onItsWay = ReadMoment.now()
        try await press(.favourite, true, with: write, in: store)
        #expect(await store.forgetReaderMarks(host: host))
        var row = try #require(await store.all().first)
        #expect(row.favourited == nil && row.boosted == nil && row.bookmarked == nil)

        await store.ingest([try copy(true, sent: onItsWay)], ifSourceHere: host)
        row = try #require(await store.all().first)
        #expect(row.favourited == nil, "a read by the sign-in that ended brought its words back")

        // The next sign-in's first read is asked afterwards, and is taken.
        await store.ingest([try copy(false, sent: .now())], ifSourceHere: host)
        #expect(await store.all().first?.favourited == false)
    }

    // MARK: - A copy that cannot say

    /// Through `refresh`, since `ingest` will not take such a copy in a debug build at all.
    @Test("A copy that cannot say when it was sent undoes no act; on a post never acted on it is taken as before")
    func aCopyThatCannotSay() async throws {
        let (write, store) = try await reader(holding: false, [
            "/api/v1/statuses/9/favourite": .json(Self.answer(.favourite, true)),
        ])
        await store.refresh([try copy(true, sent: .unsaid)], ifSourceHere: host)
        #expect(await store.all().first?.bookmarked == true, "no act yet: the copy's word is taken")

        try await press(.favourite, true, with: write, in: store)
        await store.refresh([try copy(false, sent: .now())], ifSourceHere: host)
        #expect(await store.all().first?.bookmarked == false, "the premise: a read since says no")
        await store.refresh([try copy(true, sent: .unsaid)], ifSourceHere: host)
        #expect(await store.all().first?.bookmarked == false, "a copy of no known age undid the reader's act")
    }

    // MARK: - Two acts out at once

    /// A signed-in door that holds every act until the test lets that one through.
    private actor HeldActs: HTTPSender {
        private let answers: [String: String]
        private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

        init(_ answers: [String: String]) { self.answers = answers }

        /// How many acts are on the wire, waiting.
        var parked: Int { waiting.count }

        func release(_ path: String) { waiting.removeValue(forKey: path)?.resume() }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try #require(request.url)
            await withCheckedContinuation { waiting[url.path] = $0 }
            let body = try #require(answers[url.path])
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    enum Order: String, CaseIterable, Sendable { case favouriteFirst, bookmarkFirst }

    @Test(
        "Two acts on one post out at once both end as pressed, whichever answer lands first — each answer is the word on its own act only",
        .timeLimit(.minutes(1)),
        arguments: Order.allCases
    )
    func twoActsAtOnce(landing order: Order) async throws {
        let favourite = "/api/v1/statuses/9/favourite"
        let bookmark = "/api/v1/statuses/9/bookmark"
        // Each answer says its own act and the old word for the other: the source answered
        // each before it had applied the other.
        let server = HeldActs([
            favourite: Self.answer(.favourite, true),
            bookmark: Self.answer(.bookmark, true),
        ])
        let store = ItemStore()
        await store.add(source)
        await store.ingest([try copy(false, sent: .now())], ifSourceHere: host)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let write = MastodonWrite(
            door: MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens), store: store
        )
        let row = try #require(await store.all().first)

        let favouriting = Task { try await write.favourite(row, on: true) }
        let bookmarking = Task { try await write.bookmark(row, on: true) }
        var both = false
        for _ in 0 ..< 100_000 where !both {
            both = await server.parked == 2
            if !both { await Task.yield() }
        }
        try #require(both, "the premise: both acts are on the wire")

        switch order {
        case .favouriteFirst:
            await server.release(favourite)
            _ = try await favouriting.value
            await server.release(bookmark)
            _ = try await bookmarking.value
        case .bookmarkFirst:
            await server.release(bookmark)
            _ = try await bookmarking.value
            await server.release(favourite)
            _ = try await favouriting.value
        }
        let after = try #require(await store.all().first)
        #expect(after.favourited == true, "the later answer put the favourite back")
        #expect(after.bookmarked == true, "the later answer put the bookmark back")
        #expect(after.boosted == false, "and the mark neither act moved is as the source said")
    }

    @Test("An answer still says the other two marks where nothing later has: one act's answer brings a mark moved elsewhere")
    func anAnswerSaysTheOthers() async throws {
        let (write, store) = try await reader(holding: false, [
            "/api/v1/statuses/9/favourite": .json(Self.status(true)),
        ])
        try await press(.favourite, true, with: write, in: store)
        let row = try #require(await store.all().first)
        #expect(row.favourited == true && row.bookmarked == true && row.boosted == true)
    }

    // MARK: - A sign-in that ended with a read on its way

    enum Sweep: String, CaseIterable, Sendable { case thisHost, everyHostNotSignedIn }

    @Test(
        "A read sent before a sign-in ended brings none of that reader's marks back, on a post never acted on; the next sign-in's read lands",
        arguments: Sweep.allCases, [true, false]
    )
    func aReadByTheReaderWhoLeft(sweep: Sweep, reload: Bool) async throws {
        let store = ItemStore()
        await store.add(source)
        // Held with no mark on it at all: there is nothing for the sweep to take off.
        await store.ingest([try copy(nil, sent: .now())], ifSourceHere: host)
        let onItsWay = ReadMoment.now()

        switch sweep {
        case .thisHost: await store.forgetReaderMarks(host: host)
        case .everyHostNotSignedIn: await store.forgetReaderMarks(keeping: [])
        }
        func land(_ said: Bool, sent: ReadMoment) async throws {
            if reload {
                await store.ingest([try copy(said, sent: sent)], ifSourceHere: host)
            } else {
                await store.refresh([try copy(said, sent: sent)], ifSourceHere: host)
            }
        }
        try await land(true, sent: onItsWay)
        var row = try #require(await store.all().first)
        #expect(
            row.favourited == nil && row.boosted == nil && row.bookmarked == nil,
            "a read by the reader who left told their marks to whoever is here now"
        )

        try await land(true, sent: .now())
        row = try #require(await store.all().first)
        #expect(row.favourited == true && row.boosted == true && row.bookmarked == true, "the next sign-in's own read")
    }

    @Test("A sweep leaves the hosts still signed in to alone: a read of theirs on its way lands")
    func aHostKeptIsNotSwept() async throws {
        let other = Source(host: "other.example", kind: .mastodon)
        let store = ItemStore()
        await store.add(source)
        await store.add(other)
        await store.ingest([try copy(nil, sent: .now())], ifSourceHere: host)
        await store.ingest([try copy(nil, sent: .now(), through: other)], ifSourceHere: other.host)
        let onItsWay = ReadMoment.now()

        await store.forgetReaderMarks(keeping: [host])
        await store.ingest([try copy(true, sent: onItsWay)], ifSourceHere: host)
        await store.ingest([try copy(true, sent: onItsWay, through: other)], ifSourceHere: other.host)
        let rows = await store.all()
        #expect(rows.first { $0.source.host == host }?.favourited == true, "a host still signed in to was swept")
        #expect(rows.first { $0.source.host == other.host }?.favourited == nil)

        await store.forgetReaderMarks(host: other.host)
        await store.ingest([try copy(false, sent: onItsWay)], ifSourceHere: host)
        #expect(await store.all().first { $0.source.host == host }?.favourited == false, "one host's sweep held back another's read")
    }

    // MARK: - Every read says when it was sent

    /// A page of one status, and the same status alone.
    private static let one = status(true)

    /// Where in the run's order each request reached the wire.
    private actor Wire: HTTPClient, HTTPSender {
        private let http: FixtureHTTP?
        private let sender: FixtureSender?
        private(set) var last: UInt64 = 0

        init(_ http: FixtureHTTP) { (self.http, sender) = (http, nil) }
        init(_ sender: FixtureSender) { (http, self.sender) = (nil, sender) }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            last = ReadMoment.now().place ?? 0
            return try await http!.data(from: url)
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            last = ReadMoment.now().place ?? 0
            return try await sender!.send(request)
        }
    }

    @Test("Every way a status is read says when it was sent, taken before the request went out")
    func everyReadSaysWhen() async throws {
        let before = try #require(ReadMoment.now().place)
        func said(_ note: Note?, on wire: Wire, _ what: String) async throws {
            let place = try #require(note?.asked.place, "\(what) cannot say when it was sent")
            #expect(place > before, "\(what)")
            #expect(place < (await wire.last), "\(what) took its moment after it was sent")
        }
        let http = FixtureHTTP([
            "/api/v1/timelines/public": .text("[\(Self.one)]"),
            "/api/v1/trends/statuses": .text("[\(Self.one)]"),
            "/api/v1/statuses/9": .text(Self.one),
            "/api/v1/statuses/9/context": .text(#"{"ancestors":[\#(Self.one)],"descendants":[\#(Self.one)]}"#),
            "/api/v1/timelines/tag/swift": .text("[\(Self.one)]"),
        ])
        let open = Wire(http)
        let client = MastodonClient(http: open, host: host)
        try await said(try await client.publicTimeline(source: source).first, on: open, "the public timeline")
        try await said(try await client.trending(source: source).first, on: open, "what is rising")
        let post = MastodonPost(http: open, host: host)
        try await said(try await post.post(id: "9", source: source), on: open, "the post")
        let thread = try await post.conversation(id: "9", source: source)
        try await said(thread.ancestors.first, on: open, "the posts above")
        try await said(thread.descendants.first, on: open, "the answers")
        let tag = try #require(PostTag("#swift"))
        try await said(
            try await MastodonTag(http: open, host: host).posts(under: tag, source: source).first, on: open,
            "a tag's posts"
        )

        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let signed = Wire(FixtureSender([
            "/api/v2/search": .json(#"{"statuses":[\#(Self.one)]}"#),
            "/api/v1/timelines/home": .json("[\(Self.one)]"),
            "/api/v1/statuses": .json(Self.one),
        ]))
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: signed, store: tokens)
        try await said(
            try await MastodonSearch(door: door).statuses(matching: "hello", source: source).first, on: signed,
            "a search"
        )

        let store = ItemStore()
        await store.add(source)
        let account = MastodonAccount(door: door, store: store)
        try await said(try await account.older(.home, than: "10").first, on: signed, "the reader's own timelines")
        let written = try await MastodonWrite(door: door, store: store).post("hello", visibility: .everyone)
        try await said(written, on: signed, "a post the reader wrote")
    }

    @Test("The store says when a held post was last read again, and lets that go with the post and with its host")
    func whenAPostWasLastRead() async throws {
        let (_, store) = try await reader(holding: false, [:])
        let key = try #require(await store.all().first?.key)
        #expect(await store.lastRead(of: [key]).isEmpty, "the read that brought a post is not a read of a held one")
        // A read again says the same words, and is noted all the same; an older one is not the latest.
        let earlier = ReadMoment.now(), later = ReadMoment.now()
        await store.refresh([try copy(false, sent: later)], ifSourceHere: host)
        await store.ingest([try copy(false, sent: earlier)], ifSourceHere: host)
        #expect(await store.lastRead(of: [key])[key] == later.place)

        await store.forget(key)
        #expect(await store.lastRead(of: [key]).isEmpty, "let go with its post")

        await store.ingest([try copy(false, sent: .now())], ifSourceHere: host)
        await store.ingest([try copy(false, sent: .now())], ifSourceHere: host)
        #expect(await store.lastRead(of: [key])[key] != nil)
        await store.remove(host: host)
        #expect(await store.lastRead(of: [key]).isEmpty, "let go with its host")
    }
}
