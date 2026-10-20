import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A Mastodon that answers each ask by its path and query — with a `Link` where the source
/// names a next stretch, and a status where it refuses — and the sign-in check and the source's
/// own account of a token as a 4.6 does.
private actor MarksHost: HTTPSender {
    enum Answer: Sendable {
        case json(String, link: String? = nil, status: Int = 200)
        case fail
    }

    private let tokens: MemoryMastodonTokens
    private var routes: [String: Answer] = [:]
    private(set) var asked: [String] = []

    init(tokens: MemoryMastodonTokens) {
        self.tokens = tokens
    }

    func answer(_ routes: [String: Answer]) {
        self.routes = routes
    }

    func forget() { asked = [] }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        let ask = url.path + (url.query.map { "?\($0)" } ?? "")
        asked.append(ask)
        func answered(_ body: String, _ status: Int = 200, link: String? = nil) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: link.map { ["Link": $0] })!)
        }
        switch routes[ask] {
        case .json(let body, let link, let status)?: return answered(body, status, link: link)
        case .fail?: throw URLError(.notConnectedToInternet)
        case nil: break
        }
        switch url.path {
        case PartServer.check: return answered(#"{"id":"1","acct":"me"}"#)
        case PartServer.info:
            let held = (try? tokens.token(host: url.host() ?? "")) ?? nil
            return answered(PartAskFixture.info(held?.scopes))
        case "/api/v1/timelines/home", "/api/v1/timelines/public", "/api/v1/trends/statuses": return answered("[]")
        default: throw FixtureHTTPError.unmapped
        }
    }
}

/// #317 on the screens: what the person bookmarked and favourited at a Mastodon is read as two of
/// its categories where the sign-in may read them, asked for where it may not — told what more is
/// asked before the source's page opens — read on below the lowest mark held, and said at a
/// timeline's foot to stand by when each post was published.
@MainActor
@Suite("Bookmarks and favourites as categories, on the screens", .watched)
struct MarksCategoriesTests {
    private let host = "social.example"
    private static let reading = MastodonOAuth.reading
    private static let marks = MastodonPart.marks.words.joined(separator: " ")

    /// A post of the source, published `minute` minutes into 2026-10-20.
    private static func status(_ id: String, minute: Int) -> String {
        #"""
        {"id":"\#(id)","uri":"https://social.example/users/ada/statuses/\#(id)","url":"https://social.example/@ada/\#(id)",
         "created_at":"2026-10-20T00:\#(String(format: "%02d", minute)):00.000Z","content":"<p>post \#(id)</p>",
         "visibility":"public","bookmarked":true,"favourited":false,"reblogged":false,
         "account":{"id":"9","username":"ada","acct":"ada","display_name":"Ada"}}
        """#
    }

    private static func listing(_ statuses: [String]) -> String { "[" + statuses.joined(separator: ",") + "]" }

    /// The posts by id: `101` was published first and bookmarked last.
    private static let first = status("101", minute: 1)
    private static let second = status("102", minute: 2)
    private static let third = status("103", minute: 3)

    /// The session holding `scopes` at the host, with nothing yet read.
    private func shell(holding scopes: String) async throws -> (ShellSession, MarksHost, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: scopes, asked: scopes
        ))
        let server = MarksHost(tokens: tokens)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        await session.store.add(Source(host: host, kind: .mastodon))
        session.sources = await session.store.sources()
        session.mastodon.refresh()
        return (session, server, tokens)
    }

    private func row(_ session: ShellSession, signedIn: Bool = true) throws -> SourceRow {
        let source = try #require(session.sources.first)
        return SourceRow(
            source: source, profile: .unasked(host: source.host, kind: source.kind), signedIn: signedIn, writing: nil, unasked: false
        )
    }

    private func through(_ session: ShellSession, _ category: FediqoCore.Category) async -> [String] {
        await session.store.all().filter { $0.categories.contains(category) }.compactMap(\.statusID).sorted()
    }

    // MARK: - Where the sign-in may not read them

    @Test("Signed in for less than reading them, the source's `…` offers its marks as a lock that says why, and pressing it puts the question naming what more is asked — before any page opens, and sending nothing")
    func lessThanThisIsAskedFor() async throws {
        let (session, server, _) = try await shell(holding: Self.reading)
        #expect(session.readableMarks(host: host).isEmpty)
        let lock = try #require(session.marksLock(host: host))
        let drawn = try #require(SourceRow.marksMark(
            try row(session), actsLive: true, reads: false, place: lock, language: .english
        ))
        #expect(drawn.symbol == SourceRow.permissionSymbol)
        #expect(drawn.name == "This sign-in was not asked to read your bookmarks and favourites. Update permission")
        #expect(drawn.look == .live)

        await session.pressMarks(host: host)
        let ask = try #require(session.partAsks.open)
        #expect(ask.ticked == [.marks])
        #expect(ask.said == "\(Self.reading) \(Self.marks)", "what is held, and the two words that read the marks — nothing that acts")
        let question = ShellQuestion.part(ask, language: .english)
        #expect(question.title == "Ask social.example for your bookmarks and favourites?")
        #expect(question.line.contains("your bookmarks and favourites"))
        #expect(question.help?.contains("from Fediqo or any other app") == true)
        #expect(await server.asked.isEmpty, "a press sent something")
        // Nothing is offered as read, and no timeline reads them.
        #expect(!session.readsMarks(.all))
        #expect(ShellReload.stretches(of: try #require(session.sources.first), for: nil, signedIn: true, marks: session.readableMarks(host: host))
            .allSatisfy { $0.category?.isMarks != true })
    }

    @Test("Its yes opens the source's own page for exactly that, and once allowed the marks are read at once: each post carries the category it came through")
    func allowedTheyAreRead() async throws {
        // The source a sign-in is asked on, as every ask in place is checked against.
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: Self.reading, asked: Self.reading
        ))
        let server = PartServer(tokens: tokens)
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: server))
        await session.store.add(Source(host: host, kind: .mastodon))
        session.sources = await session.store.sources()
        await server.answer("/api/v1/bookmarks", .body(Self.listing([Self.first, Self.third])))
        await server.answer("/api/v1/favourites", .body(Self.listing([Self.second])))
        await session.pressMarks(host: host)
        let ask = try #require(session.partAsks.open)
        let page = PartPage()
        session.partAsks.answer(ask, through: page, in: session)
        await session.partAsks.landed(host: host)
        #expect(page.scopes == ["\(Self.reading) \(Self.marks)"])
        #expect(session.readableMarks(host: host) == [.bookmarks, .favourites])
        #expect(await through(session, .bookmarks) == ["101", "103"])
        #expect(await through(session, .favourites) == ["102"])
    }

    @Test("Signed out, the item is there and dim for now, as Lists is; a forum's menu has none")
    func signedOutAndForums() throws {
        let micro = Source(host: "micro.example", kind: .mastodon)
        let out = SourceRow(source: micro, profile: .unasked(host: micro.host, kind: micro.kind), signedIn: false, writing: nil, unasked: false)
        let dim = try #require(SourceRow.marksMark(out, actsLive: true, reads: false, place: nil, language: .english))
        #expect(dim.look == .dim(.notNow) && dim.symbol == SourceRow.marksSymbol)
        #expect(dim.name == "Read your bookmarks and favourites at micro.example again")
        let forum = Source(host: "bbs.example.org", kind: .discuz)
        let none = SourceRow(source: forum, profile: .unasked(host: forum.host, kind: forum.kind), signedIn: true, writing: nil, unasked: false)
        #expect(SourceRow.marksMark(none, actsLive: true, reads: true, place: nil) == nil)
    }

    // MARK: - Where it may

    @Test("Held, the item reads them again; a post un-marked elsewhere leaves the category, and a refusal is said under the row and changes nothing on this device")
    func readAgainUnmarkedAndRefused() async throws {
        let (session, server, _) = try await shell(holding: "\(Self.reading) \(Self.marks)")
        #expect(session.marksLock(host: host) == nil)
        let drawn = try #require(SourceRow.marksMark(try row(session), actsLive: true, reads: true, place: nil, language: .english))
        #expect(drawn.look == .live && drawn.name == "Read your bookmarks and favourites at social.example again")
        await server.answer([
            "/api/v1/bookmarks?limit=40": .json(Self.listing([Self.first, Self.third])),
            "/api/v1/favourites?limit=40": .json("[]"),
        ])
        await session.pressMarks(host: host)
        #expect(await through(session, .bookmarks) == ["101", "103"])
        #expect(session.rowRefusal == nil)

        // Un-marked at the source by another app.
        await server.answer([
            "/api/v1/bookmarks?limit=40": .json(Self.listing([Self.third])),
            "/api/v1/favourites?limit=40": .json("[]"),
        ])
        await session.pressMarks(host: host)
        #expect(await through(session, .bookmarks) == ["103"])
        #expect(await session.store.all().count == 2, "the post is still held")

        let before = await session.store.all()
        await server.answer([
            "/api/v1/bookmarks?limit=40": .json(#"{"error":"This action is outside the authorized scopes"}"#, status: 403),
            "/api/v1/favourites?limit=40": .fail,
        ])
        await session.pressMarks(host: host)
        #expect(await session.store.all() == before)
        #expect(session.rowRefusal?.host == host && session.rowRefusal?.key == "account.source.marks.unread")
        #expect(String(format: L10n.t("account.source.marks.unread", language: .english), host)
            == "social.example did not hand over your bookmarks and favourites. Nothing on this device was changed.")
    }

    @Test("A reload of a timeline that names bookmarks reads them and no other mark, and one that cannot read them names the source as one it could not read; the store is as it was")
    func aTimelineNamingThem() async throws {
        let (session, server, _) = try await shell(holding: "\(Self.reading) \(Self.marks)")
        let marked = TimelineDefinition(name: "Marked", rules: [
            try #require(Rule.category(.bookmarks, in: .source(host: host), sources: session.sources)),
        ])
        session.written = [marked]
        await server.answer(["/api/v1/bookmarks?limit=40": .json(Self.listing([Self.second]))])
        await session.reload.timeline(.written(marked.id), in: session)
        #expect(await through(session, .bookmarks) == ["102"])
        #expect(await server.asked.contains("/api/v1/bookmarks?limit=40"))
        #expect(await !server.asked.contains { $0.hasPrefix("/api/v1/favourites") }, "a mark the timeline does not name is not asked")
        #expect(session.reload.failed.isEmpty)

        let before = await session.store.all()
        await server.answer(["/api/v1/bookmarks?limit=40": .fail])
        await session.reload.timeline(.written(marked.id), in: session)
        #expect(session.reload.failed == [host])
        #expect(await session.store.all() == before)
    }

    @Test("Reaching a listing's end reads on below the lowest mark held — never before a post's id — and stops once the source has said it has no more")
    func readOnBelowTheLowestMark() async throws {
        let (session, server, _) = try await shell(holding: "\(Self.reading) \(Self.marks)")
        let marked = TimelineDefinition(name: "Marked", rules: [
            try #require(Rule.category(.bookmarks, in: .source(host: host), sources: session.sources)),
        ])
        session.written = [marked]
        await server.answer([
            "/api/v1/bookmarks?limit=40": .json(
                Self.listing([Self.first]), link: #"<https://social.example/api/v1/bookmarks?limit=40&max_id=7>; rel="next""#
            ),
            "/api/v1/bookmarks?limit=40&max_id=7": .json(Self.listing([Self.third, Self.second])),
        ])
        await session.reload.timeline(.written(marked.id), in: session)
        #expect(await through(session, .bookmarks) == ["101"])
        #expect(await ShellReload.marksFloors(.written(marked.id), in: session) == [Stretch(host: host, category: .bookmarks): "7"])
        let due = ShellReload.due(
            .written(marked.id), in: session, stretches: ShellStretches(),
            marks: await ShellReload.marksFloors(.written(marked.id), in: session)
        )
        #expect(due.map(\.stretch) == [Stretch(host: host, category: .bookmarks)])

        await server.forget()
        await session.reload.more(.written(marked.id), in: session)
        #expect(await server.asked == ["/api/v1/bookmarks?limit=40&max_id=7"])
        #expect(await through(session, .bookmarks) == ["101", "102", "103"])
        #expect(await session.store.all().count == 3, "no post twice")
        // Read to the end: nothing more is due.
        #expect(await ShellReload.marksFloors(.written(marked.id), in: session).isEmpty)
        await server.forget()
        await session.reload.more(.written(marked.id), in: session)
        #expect(await server.asked.allSatisfy { !$0.hasPrefix("/api/v1/bookmarks") })
    }

    @Test("Reading on goes on below the source's own next though a stretch landed nothing — an empty one naming a next — and is never held at one mark")
    func readOnIsNeverHeld() async throws {
        let (session, server, _) = try await shell(holding: "\(Self.reading) \(Self.marks)")
        let marked = TimelineDefinition(name: "Marked", rules: [
            try #require(Rule.category(.bookmarks, in: .source(host: host), sources: session.sources)),
        ])
        session.written = [marked]
        await server.answer([
            "/api/v1/bookmarks?limit=40": .json(
                Self.listing([Self.first]), link: #"<https://social.example/api/v1/bookmarks?limit=40&max_id=7>; rel="next""#
            ),
            "/api/v1/bookmarks?limit=40&max_id=7": .json("[]", link: #"<https://social.example/api/v1/bookmarks?limit=40&max_id=3>; rel="next""#),
            "/api/v1/bookmarks?limit=40&max_id=3": .json(Self.listing([Self.second])),
        ])
        await session.reload.timeline(.written(marked.id), in: session)
        await server.forget()
        await session.reload.more(.written(marked.id), in: session)
        await session.reload.more(.written(marked.id), in: session)
        #expect(await server.asked == ["/api/v1/bookmarks?limit=40&max_id=7", "/api/v1/bookmarks?limit=40&max_id=3"])
        #expect(await through(session, .bookmarks) == ["101", "102"])
        await server.forget()
        await session.reload.more(.written(marked.id), in: session)
        #expect(await server.asked.allSatisfy { !$0.hasPrefix("/api/v1/bookmarks") }, "the end is the end")
    }

    @Test("Where more were marked since than a reload reads, the place where marks may be missing is said beside the timeline's rows, and reaching it reads down until it meets what is held")
    func aPlaceMissingIsReadDown() async throws {
        let (session, server, _) = try await shell(holding: "\(Self.reading) \(Self.marks)")
        let marked = TimelineDefinition(name: "Marked", rules: [
            try #require(Rule.category(.bookmarks, in: .source(host: host), sources: session.sources)),
        ])
        session.written = [marked]
        session.timelineID = .written(marked.id)
        // The third post held, under the end.
        await server.answer(["/api/v1/bookmarks?limit=40": .json(Self.listing([Self.third]))])
        await session.reload.timeline(.written(marked.id), in: session)
        // Since then, more than a reload walks: every stretch of it brings a new post and names a next.
        var routes: [String: MarksHost.Answer] = [:]
        for n in 0..<MastodonMarks.thoroughBound {
            let ask = n == 0 ? "/api/v1/bookmarks?limit=40" : "/api/v1/bookmarks?limit=40&max_id=\(1000 - n)"
            routes[ask] = .json(Self.listing([Self.status("\(200 + n)", minute: 10 + n % 40)]),
                                link: #"<https://social.example/api/v1/bookmarks?limit=40&max_id=\#(999 - n)>; rel="next""#)
        }
        routes["/api/v1/bookmarks?limit=40&max_id=975"] = .json(Self.listing([Self.second, Self.third]))
        await server.answer(routes)
        await session.reload.timeline(.written(marked.id), in: session)
        await session.reloadFromStore()
        let carrier = try #require(await session.store.all().first { !$0.gaps.isEmpty })
        #expect(carrier.statusID == "224", "on the lowest post the walk brought")
        let marks = session.gapMarks(in: session.timelineItems(latest: nil))
        #expect(marks.values.contains { $0.below.contains(Stretch(host: host, category: .bookmarks)) }, "said where it is")

        await server.forget()
        await session.reload.readDown(Stretch(host: host, category: .bookmarks), below: carrier.key, in: session)
        #expect(await server.asked == ["/api/v1/bookmarks?limit=40&max_id=975"])
        #expect(await session.store.all().allSatisfy { $0.gaps.isEmpty }, "met what is held: the place goes")
        #expect(await through(session, .bookmarks).contains("102"))
    }

    @Test("One read of a category of marks at a source at a time, however it was asked: a press while a read of bookmarks is on its way asks only for favourites, and once it has ended, for both")
    func oneReadAtATime() async throws {
        let (session, server, _) = try await shell(holding: "\(Self.reading) \(Self.marks)")
        await server.answer(["/api/v1/bookmarks?limit=40": .json("[]"), "/api/v1/favourites?limit=40": .json("[]")])
        let bookmarks = Stretch(host: host, category: .bookmarks)
        session.reload.marksReading.insert(bookmarks)
        await session.pressMarks(host: host)
        #expect(await server.asked == ["/api/v1/favourites?limit=40"])
        session.reload.marksReading.remove(bookmarks)
        await server.forget()
        await session.pressMarks(host: host)
        #expect(await server.asked == ["/api/v1/bookmarks?limit=40", "/api/v1/favourites?limit=40"])
        #expect(session.reload.marksReading.isEmpty)
    }

    // MARK: - Said where they differ

    @Test("A timeline that names a mark says at its foot that its rows stand by when each was published, not when it was marked; All, and a timeline naming none, say nothing of it")
    func theFootSaysTheOrder() async throws {
        let (session, _, _) = try await shell(holding: "\(Self.reading) \(Self.marks)")
        let marked = TimelineDefinition(name: "Marked", rules: [
            try #require(Rule.category(.favourites, in: .source(host: host), sources: session.sources)),
        ])
        let home = TimelineDefinition(name: "Home", rules: [
            try #require(Rule.category(.home, in: .source(host: host), sources: session.sources)),
        ])
        session.written = [marked, home]
        #expect(session.readsMarks(.written(marked.id)))
        #expect(!session.readsMarks(.written(home.id)))
        #expect(!session.readsMarks(.all))
        #expect(L10n.t("timeline.marks.order", language: .english) == "Bookmarks and favourites stand by when each post was published, not by when you marked it.")
    }

    @Test("Every word of this is written in each of the three string tables, the second and third alike, and names the two categories as a rule does")
    func everyWordInEveryTable() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        let tables = try ["en", "zh-TW", "zh-Hant"].map {
            try String(contentsOf: resources.appendingPathComponent("\($0).lproj/Localizable.strings"), encoding: .utf8)
        }
        let keys = [
            "rule.category.bookmarks", "rule.category.favourites", "timeline.marks.order", "account.source.marks.read",
            "account.source.marks.unread",
            "part.marks.ask.title", "part.marks.ask.line", "part.marks.ask.detail", "part.marks.unasked", "part.marks.partly",
            "part.marks.name",
        ]
        for key in keys {
            for table in tables { #expect(table.contains("\n\"\(key)\""), "\(key) is missing from a table") }
            #expect(L10n.t(key, language: .english) != key)
            #expect(L10n.t(key, language: .taiwanese) != key)
            #expect(L10n.t(key, language: .taiwanese) != L10n.t(key, language: .english))
        }
        let line: (String) -> [Substring] = { table in table.split(separator: "\n").filter { $0.contains("marks") || $0.contains("bookmarks\"") || $0.contains("favourites\"") } }
        #expect(line(tables[1]) == line(tables[2]))
        #expect(RuleText.categoryName(.bookmarks, host: host, sources: [], language: .english) == "Bookmarks")
        #expect(RuleText.categoryName(.favourites, host: host, sources: [], language: .taiwanese) == "收藏")
        #expect(ShellSearch.labels[.bookmarks] == ["Bookmarks", "書籤"])
    }
}
