import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A source answering a thread still gathered `gathering` times, then gathered; and years.
private actor ExtrasServer: HTTPSender {
    var gathering: Int
    var years: (status: Int, body: String)
    private(set) var asked: [String] = []

    init(gathering: Int = 0, years: (Int, String) = (200, #"{"annual_reports":[],"accounts":[],"statuses":[]}"#)) {
        self.gathering = gathering
        self.years = years
    }

    var contextReads: Int { asked.filter { $0.hasSuffix("/context") }.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        asked.append(path)
        var headers: [String: String] = [:]
        let (status, body): (Int, String)
        if path.hasSuffix("/context") {
            if gathering > 0 {
                gathering -= 1
                headers[MastodonGathering.header] = #"id="x", retry=3, result_count=0"#
            }
            (status, body) = (200, #"{"ancestors":[],"descendants":[]}"#)
        } else if path == "/api/v1/annual_reports" {
            (status, body) = years
        } else {
            (status, body) = (200, #"{"id":"9","acct":"reader"}"#)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

@MainActor
@Suite("What else a server keeps for the person, read", .watched)
struct ServerExtrasTests {
    private static let host = "social.example"
    private static let forum = "forum.example"

    private static let year = #"{"annual_reports":[{"year":2025,"data":{"archetype":"lurker","time_series":[{"month":12,"statuses":3,"followers":1}],"top_hashtags":[{"name":"fediqo","count":2}],"top_statuses":{"by_reblogs":null,"by_replies":null,"by_favourites":null}},"schema_version":2,"share_url":"https://social.example/@reader/wrapstodon/2025/x","account_id":"9"}],"accounts":[],"statuses":[]}"#

    private func make(signedIn: Bool = true, scopes: String = MastodonOAuth.reading, server: ExtrasServer) async throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        if signedIn {
            try tokens.save(MastodonToken(host: Self.host, accessToken: "tok-1", clientID: "c", clientSecret: "s", scopes: scopes))
        }
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        await store.add(Source(host: Self.forum, kind: .discourse))
        let session = ShellSession(http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server))
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        session.mastodon.refresh()
        await session.reloadFromStore()
        return session
    }

    // MARK: - A year looked back on

    @Test("A year the source looked back on opens from its page, read whole")
    func year() async throws {
        let session = try await make(server: ExtrasServer(years: (200, Self.year)))
        await session.years.read(host: Self.host, in: session)
        guard case .years(.read(let years)?)? = session.years.offer(host: Self.host, in: session), let year = years.first else {
            Issue.record("no year")
            return
        }
        #expect(ShellYears.title(year) == "Your 2025, looked back on")
        #expect(ShellYears.archetype(year) == "You read more than you wrote.")
        #expect(ShellYears.month(year.months[0], language: .english) == "December: 3 posts, 1 new followers")
        #expect(ShellYears.tag(year.tags[0], language: .english) == "#fediqo, 2 posts")
    }

    @Test("A host with no such address shows nothing and says nothing is missing; none made draws nothing; a failure says so")
    func absent() async throws {
        let older = try await make(server: ExtrasServer(years: (404, "<html>not here</html>")))
        await older.years.read(host: Self.host, in: older)
        #expect(older.years.offer(host: Self.host, in: older) == nil)
        #expect(older.years.absent == [Self.host])

        let none = try await make(server: ExtrasServer())
        await none.years.read(host: Self.host, in: none)
        #expect(none.years.offer(host: Self.host, in: none) == .years(.read([])))

        let failing = try await make(server: ExtrasServer(years: (500, "{}")))
        await failing.years.read(host: Self.host, in: failing)
        #expect(failing.years.offer(host: Self.host, in: failing) == .years(.failed("social.example did not answer about your years. Nothing here changed.")))
    }

    @Test("Signed out it asks to sign in; signed in for less than reading needs it says the part's sentence; a forum has none")
    func offer() async throws {
        let signedOut = try await make(signedIn: false, server: ExtrasServer())
        #expect(signedOut.years.offer(host: Self.host, in: signedOut) == .signIn("Sign in to social.example to read the years it looked back on for you."))
        signedOut.years.press(host: Self.host, in: signedOut)
        #expect(signedOut.signInChoice == Self.host)
        let lacking = try await make(scopes: "read:statuses", server: ExtrasServer())
        // Held for less than reading: not offered, and the place says why — the part's sentence, or
        // the sign-in's where the sign-in is not taken for one that reads.
        switch lacking.years.offer(host: Self.host, in: lacking) {
        case .locked?, .signIn?: break
        default: Issue.record("offered without read:accounts")
        }
        #expect(lacking.years.offer(host: Self.forum, in: lacking) == nil)
    }

    // MARK: - Collections

    @Test("A collection is a row of somebody's About, named with how many are in it, and opens its people as a list of people")
    func collection() {
        let person = Person(
            source: Source(host: Self.host, kind: .mastodon), accountID: "5", handle: "@per@social.example", name: "Per"
        )
        let list = PeopleList(collection: PersonCollection(id: "77", name: "Friends", words: nil, count: 2), of: person)
        var featured = FeaturedSaid(source: Self.host)
        featured.collections = [list]
        #expect(featured.press(on: FeaturedSaid.lamp(ofCollection: list)) == .people(list))
        #expect(FeaturedSaid.collectionWords(list, language: .english).hasPrefix("Friends"))
        #expect(PeopleSaid.title(list, language: .english) == "“Friends”, put together by @per@social.example")
        #expect(list.thing == .collections && list.asked == nil)
    }

    // MARK: - A thread still gathered

    @Test("An open thread its source is still gathering says so, is read again after the source's wait with no key pressed, and stops once gathered")
    func gathered() async throws {
        let server = ExtrasServer(gathering: 2)
        let session = try await make(server: server)
        let clock = TurnedClock()
        session.reload.gatherSleep = clock.sleep
        let note = Note(
            id: "https://elsewhere.example/statuses/1", source: Source(host: Self.host, kind: .mastodon), author: "Far",
            handle: "@far@elsewhere.example", body: "from afar", postedAt: Date(), categories: [.home], statusID: "41"
        )
        await session.store.ingest([note])
        await session.reloadFromStore()
        let item = try #require(session.held(note.key.rowID))
        let opening = Task { await session.reload.opened(item, in: session) }
        defer { opening.cancel() }

        let said = await met("the thread said to be gathered", by: opening) { session.conversations.gathering[item.id] != nil }
        try #require(said)
        let waits = await met("waiting the source's wait", by: opening) { clock.sleeping == 1 }
        try #require(waits)
        #expect(clock.asked.last == .seconds(3))
        clock.turn()
        let again = await met("read again", by: opening) { await server.contextReads == 2 && clock.sleeping == 1 }
        try #require(again)
        clock.turn()
        await opening.value
        #expect(await server.contextReads == 3)
        #expect(session.conversations.gathering[item.id] == nil, "gathered: nothing more said, and nothing more asked")
    }

    @Test("Leaving the thread stops the reading again")
    func leaving() async throws {
        let server = ExtrasServer(gathering: 5)
        let session = try await make(server: server)
        let clock = TurnedClock()
        session.reload.gatherSleep = clock.sleep
        let note = Note(
            id: "https://elsewhere.example/statuses/2", source: Source(host: Self.host, kind: .mastodon), author: "Far",
            handle: "@far@elsewhere.example", body: "from afar", postedAt: Date(), categories: [.home], statusID: "42"
        )
        await session.store.ingest([note])
        await session.reloadFromStore()
        let item = try #require(session.held(note.key.rowID))
        let opening = Task { await session.reload.opened(item, in: session) }
        let waits = await met("waiting the source's wait", by: opening) { clock.sleeping == 1 }
        try #require(waits)
        session.reload.left(item)
        opening.cancel()
        await opening.value
        #expect(await server.contextReads == 1)
    }

    @Test("Every word it says is in each language", arguments: [
        "work.purpose.yearsLookedBack", "year.title", "year.signIn", "year.failed", "year.months", "year.month",
        "person.collections", "person.collection.count", "people.title.collection", "people.collection.none",
        "people.collection.asking", "people.collection.absent", "thread.gathering",
    ])
    func words(key: String) {
        for language in DummyLanguage.allCases {
            #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
        }
    }
}
