import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A server that answers by method and address, and holds an ask until it is let go.
/// The seam a check waits on, in place of a clock.
fileprivate actor ListsHeldServer: HTTPClient, HTTPSender {
    struct Answer: Sendable {
        var body: String
        var link: String?
        var status = 200
        var authenticate: String?
    }

    struct Asked: Equatable, Sendable {
        var method: String
        var address: String
        var form: String
    }

    private var routes: [String: Answer]
    private(set) var asked: [Asked] = []
    private var held: Set<String> = []
    private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var arrived: [String: Int] = [:]

    init(_ routes: [String: Answer]) {
        self.routes = routes
    }

    func hold(_ ask: String) { held.insert(ask) }

    func release(_ ask: String) {
        held.remove(ask)
        for gate in gates.removeValue(forKey: ask) ?? [] { gate.resume() }
    }

    func arrivals(of ask: String) -> Int { arrived[ask, default: 0] }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(URLRequest(url: url))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        let path = url.path + (url.query.map { "?\($0)" } ?? "")
        let key = "\(method) \(path)"
        asked.append(Asked(
            method: method, address: url.absoluteString,
            form: String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        ))
        arrived[key, default: 0] += 1
        if held.contains(key) {
            await withCheckedContinuation { gates[key, default: []].append($0) }
        }
        guard let answer = routes[key] else { throw URLError(.badURL) }
        var headers: [String: String] = [:]
        if let link = answer.link { headers["Link"] = link }
        if let authenticate = answer.authenticate { headers["WWW-Authenticate"] = authenticate }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(answer.body.utf8), response)
    }
}

/// #337, on the page: lists are drawn for every source, a sign-in without the part sees them
/// dim with the reason, removing one asks first from `…`, and a failure changes nothing here.
///
/// Every wait is on an ask arriving or being let go (`ListsHeldServer`), tied to the work that
/// made the ask.
@MainActor
@Suite("Lists a source keeps, on its page", .serialized, .watched)
struct ServerListsTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reading = "read:statuses read:lists read:accounts"
    private static let writing = reading + " write:lists"
    private static let created = #"{"id":"2","title":"fediqo-337-probe","replies_policy":"list","exclusive":false}"#
    private static let mustFollow = #"{"error":"Validation failed: Account must be a followed account"}"#
    private static let listsPath = "GET /api/v1/lists"
    private static let postPath = "POST /api/v1/lists"

    private func prepared(_ routes: [String: ListsHeldServer.Answer]) async -> (ShellSession, ListsHeldServer, ShellServerLists) {
        let server = ListsHeldServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(),
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        let lists = ShellPersonPages().serverLists
        lists.reaching = { token in
            let tokens = MemoryMastodonTokens()
            try! tokens.save(token)
            return MastodonLists(door: MastodonAuthorized(token: token, sender: server, store: tokens))
        }
        return (session, server, lists)
    }

    private func signIn(_ session: ShellSession, scopes: String) throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes
        ))
        session.mastodon.refresh()
    }

    private func signOut(_ session: ShellSession) throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        session.mastodon.refresh()
    }

    private func height<Block: View>(_ block: Block) -> CGFloat {
        let hosted = NSHostingView(rootView: VStack(spacing: 0) { block }.frame(width: 460))
        hosted.layoutSubtreeIfNeeded()
        return hosted.fittingSize.height
    }

    private func chosen(_ session: ShellSession) async -> [ListSubscription] {
        await session.store.sources().first { $0.host == Self.host }?.lists ?? []
    }

    @Test("A forum's page draws the section dim, and asks nobody; nobody signed in draws it dim for now, and asks nobody")
    func drawnWhereItCannot() async throws {
        let (session, server, lists) = await prepared([:])
        #expect(lists.said(at: Self.forum.host, in: session) == ServerListsSaid(
            source: Self.forum.host, stand: .unavailable(.never, L10n.t("mark.dim.never"))
        ))
        #expect(lists.said(at: Self.host, in: session) == ServerListsSaid(
            source: Self.host, stand: .unavailable(.notNow, L10n.t("mark.dim.notNow"))
        ))
        await lists.opened(Self.forum.host, in: session)
        await lists.opened(Self.host, in: session)
        #expect(await server.asked.isEmpty)
        #expect(height(ServerListsBlock(host: Self.forum.host, lists: lists, session: session)) > 0)
        #expect(height(ServerListsBlock(host: Self.host, lists: lists, session: session)) > 0)
        #expect(await server.asked.isEmpty, "drawing asks nobody")
    }

    @Test("A sign-in without lists still reads them, stands locked with the reason, and a press to make one asks instead of posting")
    func readOnlyStandsLocked() async throws {
        let (session, server, lists) = await prepared([Self.listsPath: .init(body: "[]")])
        try signIn(session, scopes: Self.reading)
        await lists.opened(Self.host, in: session)
        #expect(await server.arrivals(of: Self.listsPath) == 1)
        let said = try #require(lists.said(at: Self.host, in: session))
        #expect(said.stand == .locked(L10n.t("part.lists.unasked")))
        #expect(!said.writes)
        lists.setMaking("fediqo-337-probe", at: Self.host)
        await lists.make(at: Self.host, in: session)
        #expect(await server.arrivals(of: Self.postPath) == 0)
        #expect(await chosen(session).isEmpty)
        #expect(session.partAsks.open?.ticked == [.lists])
        let row = ServerListsSaid.Row(id: "1", title: "Friends", draft: "Friends", replies: .list, alsoOnHome: true)
        var locked = said
        locked.rows = [row]
        let menu = ServerListsSection(said: locked, lists: lists, session: session, onAgain: {}).more(row)
        #expect(menu.dangers.isEmpty && menu.items.count == 1)
        #expect(menu.items[0].look == .dim(.askAgain) && menu.items[0].symbol == "list.bullet")
        menu.items[0].press { _ in }
        #expect(await server.arrivals(of: "DELETE /api/v1/lists/1") == 0)
        #expect(session.partAsks.open?.ticked.contains(.lists) == true)
    }

    @Test("Making a list the server takes puts it among the categories at once; one the server refuses changes nothing here and says the server's sentence")
    func makingWritesOnlyAfterTheServerTakesIt() async throws {
        let (session, server, lists) = await prepared([
            Self.listsPath: .init(body: "[]"),
            Self.postPath: .init(body: Self.created),
        ])
        try signIn(session, scopes: Self.writing)
        await lists.opened(Self.host, in: session)
        lists.setMaking("  fediqo-337-probe  ", at: Self.host)
        await lists.make(at: Self.host, in: session)
        let kept = [ListSubscription(id: "2", name: "fediqo-337-probe")]
        #expect(await chosen(session) == kept)
        #expect(session.sources.first { $0.host == Self.host }?.lists == kept)
        #expect(lists.said(at: Self.host, in: session)?.rows.map(\.id) == ["2"])
        #expect(await server.asked.contains { $0.method == "POST" && $0.form == "title=fediqo-337-probe" })

        let (refusedSession, refusedServer, refused) = await prepared([
            Self.listsPath: .init(body: "[]"),
            Self.postPath: .init(body: Self.mustFollow, status: 422),
        ])
        try signIn(refusedSession, scopes: Self.writing)
        await refused.opened(Self.host, in: refusedSession)
        refused.setMaking("far", at: Self.host)
        await refused.make(at: Self.host, in: refusedSession)
        #expect(await chosen(refusedSession).isEmpty)
        #expect(refused.said(at: Self.host, in: refusedSession)?.sentence == "Validation failed: Account must be a followed account")
        #expect(await refusedServer.arrivals(of: Self.postPath) == 1)

        lists.setMaking("   ", at: Self.host)
        let posted = await server.arrivals(of: Self.postPath)
        await lists.make(at: Self.host, in: session)
        #expect(await server.arrivals(of: Self.postPath) == posted)
        #expect(lists.said(at: Self.host, in: session)?.sentence == L10n.t("lists.blank"))
    }

    @Test("A list made while the reader has gone is kept for nobody, and changes nothing on this device")
    func aLateWriteChangesNothing() async throws {
        let (session, server, lists) = await prepared([
            Self.listsPath: .init(body: "[]"),
            Self.postPath: .init(body: Self.created),
        ])
        try signIn(session, scopes: Self.writing)
        await lists.opened(Self.host, in: session)
        lists.setMaking("fediqo-337-probe", at: Self.host)
        await server.hold(Self.postPath)
        let work = Task { await lists.make(at: Self.host, in: session) }
        await met("the post has arrived", by: work) { await server.arrivals(of: Self.postPath) >= 1 }
        try signOut(session)
        await server.release(Self.postPath)
        await work.value
        #expect(await chosen(session).isEmpty)
        #expect(session.sources.first { $0.host == Self.host }?.lists.isEmpty == true)
    }

    @Test("Removing a list asks first, from the row's …, and names a timeline that uses it")
    func removingAsksFirst() async throws {
        let (session, _, lists) = await prepared([:])
        try signIn(session, scopes: Self.writing)
        let rule = try #require(Rule.category(.list(id: "1"), in: .source(host: Self.host), sources: [Self.source]))
        session.written = [TimelineDefinition(name: "Morning", rules: [rule])]
        let row = ServerListsSaid.Row(id: "1", title: "Friends", draft: "Friends", replies: .list, alsoOnHome: true)
        let said = ServerListsSaid(source: Self.host, stand: .ready, rows: [row])
        let menu = ServerListsSection(said: said, lists: lists, session: session, onAgain: {}).more(row)
        #expect(menu.ordinary.isEmpty && menu.dangers.count == 1)
        #expect(menu.dangers[0].symbol == "trash" && menu.dangers[0].name == L10n.t("lists.delete"))
        var question: ShellConfirmation?
        menu.dangers[0].press { question = $0.question }
        let asked = try #require(question)
        #expect(asked.chorded?.role == .destructive)
        let text = asked.line + " " + (asked.help ?? "")
        #expect(text.contains("Morning"))
        #expect(text.contains("Friends") && text.contains(Self.host))
    }

    @Test("Putting somebody the server will not list says the server's sentence and does not tick them on")
    func aPersonTheServerWillNotList() async throws {
        let person = "42"
        let (session, server, lists) = await prepared([
            Self.listsPath: .init(body: #"[{"id":"1","title":"Friends","replies_policy":"list","exclusive":false}]"#),
            "GET /api/v1/accounts/\(person)/lists": .init(body: "[]"),
            "POST /api/v1/lists/1/accounts": .init(body: Self.mustFollow, status: 422),
        ])
        try signIn(session, scopes: Self.writing)
        lists.openPerson(person, named: "ada", at: Self.host, in: session)
        await met("their lists have been read") {
            lists.personSaid()?.asking == false
        }
        let before = try #require(lists.personSaid())
        #expect(before.rows == [PersonListsSaid.Row(id: "1", title: "Friends", on: false)])
        await lists.toggle("1", in: session)
        let after = try #require(lists.personSaid())
        #expect(after.rows == before.rows)
        #expect(after.sentence == "Validation failed: Account must be a followed account")
        #expect(await server.asked.contains { $0.method == "POST" && $0.form == "account_ids%5B%5D=\(person)" })
    }

    @Test("A timeline whose every include is a list this device no longer keeps says the list is gone; any other include, or All, stays the ordinary empty")
    func aTimelineOfAGoneList() {
        let source = Source(host: Self.host, kind: .mastodon)
        let gone = Rule.category(.list(id: "1"), in: .source(host: Self.host), sources: [source])!
        let definition = TimelineDefinition(name: "Morning", rules: [gone])
        func notice(
            _ query: TimelineQuery, rules: [Rule], notes: [Note] = [], sources: [Source] = [source]
        ) -> EmptyNotice {
            EmptyNotice.timeline(
                searching: false, indexed: true, query: query, notes: notes,
                written: [TimelineDefinition(id: definition.id, name: "Morning", rules: rules)],
                sources: sources, index: TextIndex(notes), latest: nil, asked: false
            )
        }
        let empty = notice(.written(definition.id), rules: [gone])
        #expect(empty.kind == .goneList && empty.symbol == "list.bullet")
        #expect(empty.title == L10n.t("timeline.list.gone.title"))
        let kept = Source(host: Self.host, kind: .mastodon, lists: [ListSubscription(id: "2", name: "Work")])
        let still = Rule.category(.list(id: "2"), in: .source(host: Self.host), sources: [kept])!
        #expect(notice(.written(definition.id), rules: [gone, still], sources: [kept]).kind != .goneList)
        let open = Rule.category(.public, in: .source(host: Self.host), sources: [source])!
        #expect(notice(.written(definition.id), rules: [gone, open]).kind != .goneList)
        #expect(notice(.all, rules: [gone]).kind != .goneList)
        let note = Note(
            id: "n1", source: source, author: "Ada", handle: "@ada@m.example", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public]
        )
        #expect(notice(.written(definition.id), rules: [gone], notes: [note]).kind != .goneList)
    }

    @Test("A person's … offers Lists, and without the part it is dim with the lock and its press only asks")
    func aPersonsMenuOffersLists() {
        let offered = PersonActing(source: Self.host, named: "ada", lists: true)
        var pressed = false
        let live = offered.menu(act: { _ in }, onLists: { pressed = true })
        let item = live.items.first { $0.symbol == "list.bullet" }
        #expect(item?.name == L10n.t("lists.section.title") && item?.look == .live)
        item?.press { _ in }
        #expect(pressed)

        let locked = PersonActing(
            source: Self.host, named: "ada", lists: true,
            listsLock: PartWords.Place(kind: .unasked, key: "part.lists.unasked")
        )
        var asked = false
        let dim = locked.menu(act: { _ in }, onLists: { asked = true })
        let held = dim.items.first { $0.symbol == "list.bullet" }
        #expect(held?.look == .dim(.askAgain))
        #expect(held?.title().contains(L10n.t("part.lists.unasked")) == true)
        held?.press { _ in }
        #expect(asked)
        #expect(!PersonActing(source: Self.host, named: "ada").menu(act: { _ in }).items.contains { $0.symbol == "list.bullet" })
    }
}
