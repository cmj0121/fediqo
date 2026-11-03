import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A source keeping the person's filters: what it lists, and what it was asked.
private actor FilterServer: HTTPSender {
    var filters: [String] = []
    var refuse = false
    /// Whether the one post is under a filter here, and whether it has gone.
    var under = false
    var gone = false
    private(set) var asked: [String] = []

    func goneNow() { gone = true }
    var failsPosts = false
    var postsGate: Gate?
    let postsReached = Gate()
    func failingPosts() { failsPosts = true }
    func holdingPosts(_ gate: Gate) { postsGate = gate }

    static func status(filtered: String) -> String {
        #"{"id":"77","created_at":"2026-10-01T00:00:00.000Z","content":"<p>the words</p>","visibility":"public","url":"https://social.example/@a/77","uri":"https://social.example/s/77","account":{"id":"3","username":"a","acct":"a","display_name":"A","url":"https://social.example/@a"},"media_attachments":[],"mentions":[],"tags":[],"emojis":[],"reblogs_count":0,"favourites_count":0,"replies_count":0,"filtered":\#(filtered)}"#
    }

    init(_ filters: [String]) { self.filters = filters }

    func refusing() { refuse = true }
    func setFilters(_ filters: [String]) { self.filters = filters }

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
        case ("POST", let at) where at.hasSuffix("/statuses") && at.hasPrefix("/api/v2/filters/"):
            if refuse { return answer(422, #"{"error":"Validation failed: Status must exist"}"#) }
            under = true
            return answer(200, #"{"id":"1","status_id":"77"}"#)
        case ("DELETE", "/api/v2/filters/statuses/1"):
            if refuse { return answer(500, "down") }
            under = false
            return answer(200, "{}")
        case ("GET", "/api/v1/statuses/77"):
            let hit = #"{"filter":{"id":"5","title":"Hush","context":["home"],"expires_at":null,"filter_action":"hide"},"keyword_matches":null,"status_matches":["77"]}"#
            return answer(200, Self.status(filtered: under ? "[\(hit)]" : "[]"))
        case ("GET", "/api/v1/statuses"):
            if failsPosts { return answer(500, "down") }
            if let postsGate {
                await postsReached.open()
                await postsGate.wait()
            }
            return answer(200, gone ? "[]" : "[" + Self.status(filtered: "[]") + "]")
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

    @Test("With the choice off a caught post is drawn plainly, a muted or blocked author stays hidden, and turning it on hides or covers it again without asking the source")
    func appliedByChoice() async throws {
        let server = FilterServer([])
        let session = try await make(server: server)
        let hidden = Self.item([Self.hit(.hide)])
        let warned = Self.item([Self.hit(.warn)])
        #expect(session.acting(on: hidden).hidden?.opens == false)
        #expect(session.acting(on: warned).hidden?.opens == true)
        #expect(session.serverFilter(over: hidden, applied: false) == nil)
        #expect(session.acting(on: hidden, applied: false).hidden == nil)
        #expect(session.acting(on: warned, applied: false).hidden == nil)
        #expect(session.acting(on: hidden, applied: true).hidden?.words == "Hidden by your filter “Fruit” at social.example.")
        #expect(session.acting(on: warned, applied: true).hidden?.words == "Covered by your filter “Fruit” at social.example.")
        // A mute or a block still hides with the choice off: that hide wins, the filter or not.
        session.hides.hide("@ada@social.example", at: Self.host, .muted)
        #expect(session.acting(on: hidden, applied: false).hidden?.words == "Hidden here: you muted @ada@social.example at social.example.")
        session.hides.show("@ada@social.example", at: Self.host, .muted)
        session.hides.hide("@ada@social.example", at: Self.host, .blocked)
        #expect(session.acting(on: hidden, applied: false).hidden?.words == "Hidden here: you blocked @ada@social.example at social.example.")
        #expect(session.acting(on: hidden, applied: true).hidden?.words == "Hidden here: you blocked @ada@social.example at social.example.")
        #expect(await server.asked.allSatisfy { !$0.contains("filters") }, "turning the choice asks no source for its filters")
    }

    @Test("A row is handed the choice: off, a post a filter caught is not hidden for it, and on, it is")
    func handedToTheRow() async throws {
        let session = try await make()
        let item = Self.item([Self.hit(.hide)])
        let off = RowActing(session: session, serverFilters: false, openThread: { _ in })(item)
        #expect(off.hidden == nil)
        let on = RowActing(session: session, serverFilters: true, openThread: { _ in })(item)
        #expect(on.hidden?.words == "Hidden by your filter “Fruit” at social.example.")
        #expect(on.hidden?.opens == false)
    }

    @Test("A source's filters apply unless this device turns them off, and the choice is kept and read again")
    func preference() throws {
        let defaults = UserDefaults(suiteName: "fediqo.serverFilters.\(UUID().uuidString)")!
        let prefs = DummyPrefs(defaults: defaults)
        #expect(prefs.serverFilters)
        prefs.serverFilters = false
        #expect(!DummyPrefs(defaults: defaults).serverFilters)
        defaults.set("", forKey: "fediqo.dummy.serverFilters")
        prefs.reread()
        #expect(prefs.serverFilters)
        for key in ["prefs.filters", "prefs.filters.head", "prefs.filters.brief", "prefs.filters.footer"] {
            #expect(L10n.t(key, language: .english) != key && L10n.t(key, language: .taiwanese) != key, "\(key)")
        }
        let pane = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Shell/TimelinePane.swift"), encoding: .utf8)
        #expect(!pane.contains("prefs.filters"), "the timeline carries no sentence of the choice")
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

    // MARK: - One post (#439)

    private func held(_ session: ShellSession) async throws -> DummyItem {
        let source = try #require(session.sources.first { $0.host == Self.host })
        let read = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(FilterServer.status(filtered: "[]").utf8))
        let note = try #require(read.asNote(source: source, category: .home, sent: .now()))
        await session.store.ingest([note], ifSourceHere: Self.host)
        await session.reloadFromStore()
        return try #require(session.notes.first.map { DummyItem($0) })
    }

    private static func hush(under: Bool = false) -> String {
        #"{"id":"5","title":"Hush","context":["home"],"expires_at":null,"filter_action":"hide","keywords":[],"statuses":[\#(under ? #"{"id":"1","status_id":"77"}"# : "")]}"#
    }

    @Test("Put under a filter from its `…`, a post is treated by that filter here; taken out, it is as it was")
    func underAndOut() async throws {
        let server = FilterServer([Self.hush()])
        let session = try await make(server: server)
        let item = try await held(session)
        #expect(session.serverFilter(over: item) == nil)
        let more = ItemActs.more(on: item, acting: { var a = session.acting(on: item); a.postFilter = session.postFilterOffer(on: item); return a }())
        #expect(more.items.contains { $0.name == L10n.t("item.act.filter") })

        session.serverFilters.open(on: item, in: session)
        await session.serverFilters.read(host: Self.host, in: session)
        let asked = try #require(session.serverFilters.filtering)
        #expect(asked.statusID == "77")
        let filter = try #require(session.serverFilters.filters(at: Self.host)?.first)
        await session.serverFilters.turn(filter, for: asked, in: session)
        #expect(await server.asked.contains("POST /api/v2/filters/5/statuses"))
        let under = DummyItem(try #require(session.notes.first))
        #expect(session.serverFilter(over: under)?.filterID == "5")

        let now = ServerFilter(id: "5", title: "Hush", context: ["home"], action: .hide, expiresAt: nil, keywords: [], statuses: 1, posts: [FilteredPost(id: "1", statusID: "77")])
        await session.serverFilters.turn(now, for: asked, in: session)
        #expect(await server.asked.contains("DELETE /api/v2/filters/statuses/1"))
        #expect(session.serverFilter(over: DummyItem(try #require(session.notes.first))) == nil)
    }

    // MARK: - Changed elsewhere (#461)

    private static func fruit(_ action: String, posts: String = "") -> String {
        #"{"id":"1","title":"Fruit, now","context":["home"],"expires_at":null,"filter_action":"\#(action)","keywords":[],"statuses":[\#(posts)]}"#
    }

    @Test("A filter changed elsewhere stands over what is held as its list now says, once read again; one removed stands no more")
    func changedElsewhere() async throws {
        let server = FilterServer([Self.fruit("hide")])
        let session = try await make(server: server)
        let item = Self.item([Self.hit(.warn)])
        #expect(session.serverFilter(over: item)?.action == .warn, "as the post was read, until the list is")

        await session.serverFilters.cameForward(hosts: [Self.host], in: session)
        #expect(await server.asked.filter { $0 == "GET /api/v2/filters" }.count == 1, "once, coming forward")
        let now = try #require(session.serverFilter(over: item))
        #expect(now.action == .hide && now.title == "Fruit, now")

        await server.setFilters([])
        await session.serverFilters.cameForward(hosts: [Self.host], in: session)
        #expect(session.serverFilter(over: item) == nil, "removed elsewhere, it stands no more")
    }

    @Test("A post a filter names by itself elsewhere is under it once the list is read again; no word is matched here")
    func namedElsewhere() async throws {
        let server = FilterServer([Self.fruit("hide", posts: #"{"id":"3","status_id":"77"}"#)])
        let session = try await make(server: server)
        let item = try await held(session)
        #expect(session.serverFilter(over: item) == nil)
        await session.serverFilters.cameForward(hosts: [Self.host], in: session)
        #expect(session.serverFilter(over: item)?.filterID == "1")

        await server.setFilters([FilterServer.filter(id: "2", title: "Words")])
        await session.serverFilters.cameForward(hosts: [Self.host], in: session)
        #expect(session.serverFilter(over: item) == nil, "a keyword is the source's to match, when it next sends the post")
    }

    @Test("Coming forward asks nothing of a source whose line is not held")
    func notHeld() async throws {
        let server = FilterServer([Self.fruit("hide")])
        let session = try await make(server: server)
        await session.serverFilters.cameForward(hosts: [], in: session)
        #expect(await server.asked.isEmpty)
        #expect(session.lines.heldHosts.isEmpty)
    }

    @Test("The source refusing says so, and nothing here moves")
    func aRefusalMovesNothing() async throws {
        let server = FilterServer([Self.hush()])
        let session = try await make(server: server)
        let item = try await held(session)
        session.serverFilters.open(on: item, in: session)
        let asked = try #require(session.serverFilters.filtering)
        await server.refusing()
        let filter = ServerFilter(id: "5", title: "Hush", context: ["home"], action: .hide, expiresAt: nil, keywords: [])
        await session.serverFilters.turn(filter, for: asked, in: session)
        #expect(session.serverFilters.refused[Self.host] != nil)
        #expect(await !server.asked.contains("GET /api/v1/statuses/77"), "nothing read over a refusal")
        #expect(session.serverFilter(over: DummyItem(try #require(session.notes.first))) == nil)
    }

    @Test("The posts under a filter are read and taken out; one its source no longer gives stays a line that can be")
    func itsPosts() async throws {
        let server = FilterServer([Self.hush(under: true)])
        let session = try await make(server: server)
        _ = try await held(session)
        let filter = ServerFilter(id: "5", title: "Hush", context: ["home"], action: .hide, expiresAt: nil, keywords: [], statuses: 1, posts: [FilteredPost(id: "1", statusID: "77")])
        await session.serverFilters.openPosts(of: filter, at: Self.host, in: session)
        var line = try #require(session.serverFilters.readingPosts?.lines.first)
        #expect(line.opening == "the words" && line.who != nil)

        await server.goneNow()
        await session.serverFilters.openPosts(of: filter, at: Self.host, in: session)
        line = try #require(session.serverFilters.readingPosts?.lines.first)
        #expect(line.opening == nil && session.serverFilters.readingPosts?.reading == false)

        await session.serverFilters.takeOut(line, in: session)
        #expect(session.serverFilters.readingPosts?.lines.isEmpty == true)
        #expect(await server.asked.contains("DELETE /api/v2/filters/statuses/1"))
    }

    @Test("Offered only on a post of a source with filters where somebody is signed in; dim without the part")
    func whoIsOffered() async throws {
        let session = try await make(filters: false)
        let item = try await held(session)
        #expect(session.postFilterOffer(on: item)?.lock != nil)
        let none = try await make(signedIn: false)
        #expect(none.postFilterOffer(on: try await held(none)) == nil)
    }

    private static let hushed = ServerFilter(id: "5", title: "Hush", context: ["home"], action: .hide, expiresAt: nil, keywords: [], statuses: 1, posts: [FilteredPost(id: "1", statusID: "77")])

    @Test("A read of the posts that fails says so, and says of none that it has gone")
    func aFailedReadOfPosts() async throws {
        let server = FilterServer([Self.hush(under: true)])
        let session = try await make(server: server)
        await server.failingPosts()
        await session.serverFilters.openPosts(of: Self.hushed, at: Self.host, in: session)
        let sheet = try #require(session.serverFilters.readingPosts)
        #expect(sheet.unread && !sheet.reading && sheet.lines.count == 1)
        #expect(session.serverFilters.refused[Self.host] == String(format: L10n.t("filters.failed"), Self.host))
    }

    @Test("A line taken out while the posts are read stays out")
    func outWhileRead() async throws {
        let server = FilterServer([Self.hush(under: true)])
        let gate = Gate()
        await server.holdingPosts(gate)
        let session = try await make(server: server)
        let reading = Task { await session.serverFilters.openPosts(of: Self.hushed, at: Self.host, in: session) }
        await server.postsReached.wait()
        let line = try #require(session.serverFilters.readingPosts?.lines.first)
        await session.serverFilters.takeOut(line, in: session)
        await gate.open()
        await reading.value
        #expect(session.serverFilters.readingPosts?.lines.isEmpty == true)
    }

    @Test("A sign-out lets go of the filters and their sheets, and a read on its way lands nowhere")
    func signOutForgets() async throws {
        let server = FilterServer([Self.hush(under: true)])
        let session = try await make(server: server)
        await session.serverFilters.read(host: Self.host, in: session)
        let item = try await held(session)
        session.serverFilters.open(on: item, in: session)
        await session.serverFilters.openPosts(of: Self.hushed, at: Self.host, in: session)
        #expect(session.serverFilters.filters(at: Self.host) != nil)
        await session.mastodon.signOut(host: Self.host)
        await session.forgetReaderMarksDue()
        #expect(session.serverFilters.filters(at: Self.host) == nil)
        #expect(session.serverFilters.filtering == nil && session.serverFilters.readingPosts == nil)
    }

    @Test("Removing the source lets go of them too")
    func removalForgets() async throws {
        let session = try await make(server: FilterServer([Self.hush()]))
        await session.serverFilters.read(host: Self.host, in: session)
        await session.remove(host: Self.host)
        #expect(session.serverFilters.filters(at: Self.host) == nil)
    }

    @Test("Every language says each of its words")
    func theWords() {
        for key in ["item.act.filter", "filters.post.put", "filters.post.put.spoken", "filters.post.out", "filters.post.out.spoken", "filters.post.unread", "filters.posts.open", "filters.posts.title", "filters.posts.none", "filters.posts.gone", "filters.posts.unread"] {
            for language in [DummyLanguage.english, .taiwanese] { #expect(L10n.t(key, language: language) != key) }
        }
    }
}
