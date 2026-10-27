import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A source keeping the person's filters: what it lists, and what it was asked.
private actor FilterServer: HTTPSender {
    var filters: [String] = []
    var refuse = false
    private(set) var asked: [String] = []

    init(_ filters: [String]) { self.filters = filters }

    func refusing() { refuse = true }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        asked.append("\(method) \(path)")
        func answer(_ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        switch (method, path) {
        case ("GET", "/api/v2/filters"): return answer(200, "[" + filters.joined(separator: ",") + "]")
        case ("POST", "/api/v2/filters"):
            if refuse { return answer(422, #"{"error":"Validation failed: Title can't be blank"}"#) }
            let made = Self.filter(id: "\(filters.count + 1)", title: "Made")
            filters.append(made)
            return answer(200, made)
        case ("DELETE", _):
            filters.removeAll { $0.hasPrefix(#"{"id":"\#(path.split(separator: "/").last ?? "")","#) }
            return answer(200, "{}")
        default: return answer(200, #"{"id":"9","acct":"reader"}"#)
        }
    }

    static func filter(id: String, title: String) -> String {
        #"{"id":"\#(id)","title":"\#(title)","context":["home"],"expires_at":null,"filter_action":"warn","keywords":[{"id":"1","keyword":"apple","whole_word":true}],"statuses":[]}"#
    }
}

@MainActor
@Suite("What the server hides for the person, and its filters tended", .watched)
struct ServerFiltersTests {
    private static let host = "social.example"
    private static let forum = "forum.example"

    private func make(signedIn: Bool = true, filters: Bool = true, server: FilterServer = FilterServer([])) async throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        if signedIn {
            let parts: Set<MastodonPart> = filters ? [.reading, .filters] : [.reading]
            try tokens.save(MastodonToken(
                host: Self.host, accessToken: "tok-1", clientID: "c", clientSecret: "s",
                scopes: MastodonParts.page(held: nil, ticked: parts)
            ))
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

    private static func item(_ hits: [ServerFilterHit]?) -> DummyItem {
        var note = Note(
            id: "https://social.example/users/ada/statuses/1", source: Source(host: host, kind: .mastodon), author: "Ada",
            handle: "@ada@social.example", body: "an apple pie", postedAt: Date(), categories: [.home]
        )
        note.serverFiltered = hits
        return DummyItem(note)
    }

    private static func hit(_ action: ServerFilterAction, _ context: Set<String> = ["home"], expires: Date? = nil) -> ServerFilterHit {
        ServerFilterHit(filterID: "1", title: "Fruit", action: action, context: context, expiresAt: expires)
    }

    @Test("A post a hiding filter caught is drawn hidden, naming the filter and the server, and does not open")
    func hidden() async throws {
        let session = try await make()
        let acting = session.acting(on: Self.item([Self.hit(.hide)]))
        #expect(acting.hidden?.words == "Hidden by your filter “Fruit” at social.example.")
        #expect(acting.hidden?.opens == false && acting.showAnyway == nil)
    }

    @Test("A post a warning filter caught is covered with the filter's name, and opens on asking for the run")
    func warned() async throws {
        let session = try await make()
        let item = Self.item([Self.hit(.warn)])
        let acting = session.acting(on: item)
        #expect(acting.hidden?.words == "Covered by your filter “Fruit” at social.example.")
        let show = try #require(acting.showAnyway)
        show()
        #expect(session.acting(on: item).hidden == nil)
    }

    @Test("Nothing is drawn of a filter that lapsed, or that applies only where timelines are not, or where no read said one caught it")
    func notStanding() async throws {
        let session = try await make()
        #expect(session.acting(on: Self.item([Self.hit(.hide, expires: Date().addingTimeInterval(-60))])).hidden == nil)
        #expect(session.acting(on: Self.item([Self.hit(.hide, ["thread"])])).hidden == nil)
        #expect(session.acting(on: Self.item(nil)).hidden == nil)
        #expect(session.acting(on: Self.item([])).hidden == nil)
    }

    @Test("Offered with the filters part; dim with the part's own sentence without it, whose press asks for it; asking to sign in where signed out; nothing for a forum")
    func offer() async throws {
        let session = try await make()
        #expect(session.serverFilters.offer(host: Self.host, in: session) == .list(nil))
        #expect(session.serverFilters.offer(host: Self.forum, in: session) == nil)

        let lacking = try await make(filters: false)
        guard case .locked(let sentence) = lacking.serverFilters.offer(host: Self.host, in: lacking) else {
            Issue.record("offered without the filters part")
            return
        }
        #expect(sentence.contains("filters"))
        lacking.serverFilters.press(host: Self.host, in: lacking)
        #expect(lacking.partAsks.open?.ticked.contains(.filters) == true, "the question that says what more is asked")

        let signedOut = try await make(signedIn: false)
        #expect(signedOut.serverFilters.offer(host: Self.host, in: signedOut)
            == .signIn("Sign in to social.example, with your filters, to see and tend them here."))
    }

    @Test("Read, made and removed as the source keeps them, the list read again after each; a refusal is said and changes nothing")
    func tended() async throws {
        let server = FilterServer([FilterServer.filter(id: "1", title: "Fruit")])
        let session = try await make(server: server)
        await session.serverFilters.read(host: Self.host, in: session)
        guard case .list(.read(let filters)?) = session.serverFilters.offer(host: Self.host, in: session) else {
            Issue.record("not read")
            return
        }
        #expect(filters.map(\.title) == ["Fruit"])
        #expect(ShellServerFilters.line(filters[0]) == "Warns · Home and lists · apple")

        let draft = ServerFilterDraft(title: "Made", context: ["home"], action: .warn, keywords: [.init(keyword: "pear", wholeWord: true)])
        #expect(await session.serverFilters.make(draft, host: Self.host, in: session))
        #expect(session.serverFilters.reading[Self.host] .map { if case .read(let list) = $0 { list.count } else { 0 } } == 2)

        await server.refusing()
        #expect(await !session.serverFilters.make(draft, host: Self.host, in: session))
        #expect(session.serverFilters.refused[Self.host] == "social.example refused that filter as it was. Nothing changed.")
        if case .read(let list)? = session.serverFilters.reading[Self.host] { #expect(list.count == 2) }

        #expect(await session.serverFilters.remove(filters[0], host: Self.host, in: session))
        if case .read(let list)? = session.serverFilters.reading[Self.host] { #expect(list.map(\.title) == ["Made"]) }
        #expect(await server.asked.contains("DELETE /api/v2/filters/1"))
    }

    @Test("Every word it says is in each language", arguments: [
        "work.purpose.filters", "part.filters.unasked", "part.filters.name", "hidden.filter", "hidden.filter.warn",
        "hidden.filter.show", "filters.title", "filters.remove.title", "filters.lasts.unchanged", "filters.place.account",
    ])
    func words(key: String) {
        for language in DummyLanguage.allCases {
            #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
        }
    }
}
