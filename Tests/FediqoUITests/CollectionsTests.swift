import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A server that answers by method and address, in turn where given several, and holds an ask
/// (the next to arrive) until it is let go: the seam a check waits on, in place of a clock.
fileprivate actor CollectionsServer: HTTPClient, HTTPSender {
    struct Answer: Sendable {
        var body: String
        var status = 200
        var authenticate: String?
        var lost = false
    }

    private var routes: [String: [Answer]]
    private(set) var asked: [String] = []
    private var forms: [String] = []
    private var bearers: [String: String] = [:]
    private var held: Set<String> = []
    private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(_ routes: [String: [Answer]]) {
        self.routes = routes
    }

    func hold(_ ask: String) { held.insert(ask) }

    func release(_ ask: String) {
        for gate in gates.removeValue(forKey: ask) ?? [] { gate.resume() }
    }

    func arrivals(of ask: String) -> Int { asked.filter { $0 == ask }.count }
    func sent() -> [String] { forms }
    func bearer(of ask: String) -> String? { bearers[ask] }
    func set(_ ask: String, _ answers: [Answer]) { routes[ask] = answers }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(URLRequest(url: url))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        asked.append(key)
        bearers[key] = request.value(forHTTPHeaderField: "Authorization")
        if request.httpMethod != "GET" && request.httpMethod != nil { forms.append("\(key) [\(String(decoding: request.httpBody ?? Data(), as: UTF8.self))]") }
        // The answer is this request's, chosen as it arrives: one held brings what it was given.
        guard var answers = routes[key], let answer = answers.first else { throw URLError(.badURL) }
        if answers.count > 1 {
            answers.removeFirst()
            routes[key] = answers
        }
        if held.remove(key) != nil {
            await withCheckedContinuation { gates[key, default: []].append($0) }
        }
        if answer.lost { throw URLError(.networkConnectionLost) }
        var headers: [String: String] = [:]
        if let authenticate = answer.authenticate { headers["WWW-Authenticate"] = authenticate }
        return (Data(answer.body.utf8), HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

/// #433, on the page: the sheet of a person's own collections, and taking oneself out.
@MainActor
@Suite("Collections made and tended on the page", .serialized, .watched)
struct CollectionsTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reading = "read:statuses read:lists read:accounts"
    private static let whole = reading + " read:collections write:collections"
    private static let who = "GET /api/v1/accounts/verify_credentials"
    private static let ownList = "GET /api/v1/accounts/7/collections"
    private static let make = "POST /api/v1/collections"
    private static let ada = DummyPerson(handle: "@ada@m.example", host: host)!

    private static func collection(_ id: String = "9", name: String = "Friends", found: Bool = true, items: String = "") -> String {
        #"{"id":"\#(id)","name":"\#(name)","description":null,"account_id":"7","sensitive":false,"discoverable":\#(found),"item_count":\#(items.isEmpty ? 0 : 1),"items":[\#(items)]}"#
    }

    private static func item(_ id: String, of account: String, state: String = "accepted") -> String {
        #"{"id":"\#(id)","state":"\#(state)","account_id":"\#(account)"}"#
    }

    private static func list(_ bodies: String...) -> CollectionsServer.Answer {
        .init(body: #"{"collections":[\#(bodies.joined(separator: ","))]}"#)
    }

    private static func one(_ body: String) -> CollectionsServer.Answer {
        .init(body: #"{"collection":\#(body)}"#)
    }

    private func prepared(
        _ routes: [String: [CollectionsServer.Answer]], scopes: String? = CollectionsTests.whole
    ) async throws -> (ShellSession, CollectionsServer, ShellPersonPages) {
        let me = CollectionsServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#)
        let server = CollectionsServer(routes.merging([Self.who: [me]]) { mine, _ in mine })
        let session = ShellSession(http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server))
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        if let scopes { try await signIn(session, scopes: scopes) }
        return (session, server, ShellPersonPages())
    }

    private func signIn(_ session: ShellSession, scopes: String, token: String = "tok") async throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: token, clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
    }

    private func signOut(_ session: ShellSession) throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        session.mastodon.refresh()
    }

    private static func page(id: String = "42") throws -> PersonSaid {
        let person = try MastodonPeople.person(
            from: Data(#"{"id":"\#(id)","acct":"ada","display_name":"Ada","statuses_count":3}"#.utf8), source: source
        )
        return PersonSaid(source: host, reading: .said(person), posts: [])
    }

    // MARK: - Who is offered it

    @Test("A sign-in without the part sends nothing on opening: it only asks; a source that does not offer them does neither")
    func withoutThePart() async throws {
        let (session, server, people) = try await prepared([:], scopes: Self.reading)
        await people.collections.opening(at: Self.host, in: session)
        #expect(people.collections.open == nil)
        #expect(session.partAsks.open?.host == Self.host)
        #expect(await server.arrivals(of: Self.ownList) == 0)
        await people.collections.opening(at: Self.forum.host, in: session)
        #expect(people.collections.open == nil)
    }

    @Test("A person's … offers Collections, without the part dim with the lock and its press only asks; the menu draws no item where it is not told to")
    func aPersonsMenu() {
        let offered = PersonActing(source: Self.host, named: "ada", collections: true)
        var pressed = false
        let item = offered.menu(act: { _ in }, onCollections: { pressed = true }).items.first { $0.symbol == PersonActing.collectionsSymbol }
        #expect(item?.name == L10n.t("collections.title") && item?.look == .live)
        item?.press { _ in }
        #expect(pressed)

        let locked = PersonActing(
            source: Self.host, named: "ada", collections: true,
            collectionsLock: PartWords.Place(kind: .unasked, key: "part.collections.unasked")
        )
        var asked = false
        let dim = locked.menu(act: { _ in }, onCollections: { asked = true }).items.first { $0.symbol == PersonActing.collectionsSymbol }
        #expect(dim?.look == .dim(.askAgain) && dim?.title().contains(L10n.t("part.collections.unasked")) == true)
        dim?.press { _ in }
        #expect(asked)
        #expect(!PersonActing(source: Self.host, named: "ada").menu(act: { _ in }).items.contains { $0.symbol == PersonActing.collectionsSymbol })
    }

    // MARK: - The sheet

    @Test("Opened, the sheet reads as the reader and draws one not to be found as such")
    func opensSigned() async throws {
        let (session, server, people) = try await prepared([Self.ownList: [Self.list(Self.collection(found: false))]])
        await people.collections.opening(at: Self.host, in: session)
        let said = try #require(people.collections.said())
        #expect(said.rows.map(\.name) == ["Friends"] && said.rows.first?.hidden == true && said.live)
        #expect(await server.bearer(of: Self.ownList) == "Bearer tok")
    }

    @Test("Made, it stands at the head of the sheet, and the form goes")
    func making() async throws {
        let (session, server, people) = try await prepared([Self.ownList: [Self.list()], Self.make: [Self.one(Self.collection())]])
        await people.collections.opening(at: Self.host, in: session)
        people.collections.startMaking()
        people.collections.setDraft(CollectionDraft(name: "Friends"))
        await people.collections.save(in: session)
        let said = try #require(people.collections.said())
        #expect(said.rows.map(\.id) == ["9"] && said.form == nil && said.sentence == nil)
        #expect(await server.sent() == ["\(Self.make) [name=Friends&sensitive=false&discoverable=true]"])
    }

    @Test("What the source refuses is said in its sentence; the form stays with what was typed, the rows do not move, and nothing is read again")
    func refusalChangesNothing() async throws {
        let refused = CollectionsServer.Answer(body: #"{"error":{"error":"Validation failed: Name is too long (maximum is 40 characters)","details":{}}}"#, status: 422)
        let (session, server, people) = try await prepared([Self.ownList: [Self.list(Self.collection())], Self.make: [refused]])
        await people.collections.opening(at: Self.host, in: session)
        people.collections.startMaking()
        people.collections.setDraft(CollectionDraft(name: String(repeating: "x", count: 41)))
        await people.collections.save(in: session)
        let said = try #require(people.collections.said())
        #expect(said.sentence == "Validation failed: Name is too long (maximum is 40 characters)")
        #expect(said.form?.draft.name.count == 41 && said.rows.map(\.id) == ["9"] && said.live)
        #expect(await server.arrivals(of: Self.ownList) == 1)
    }

    @Test("An answer lost is not sent again: the sheet reads what the source holds and says it may have happened")
    func aLostAnswer() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(), Self.list(Self.collection())],
            Self.make: [.init(body: "", lost: true)],
        ])
        await people.collections.opening(at: Self.host, in: session)
        people.collections.startMaking()
        people.collections.setDraft(CollectionDraft(name: "Friends"))
        await people.collections.save(in: session)
        let said = try #require(people.collections.said())
        #expect(said.rows.map(\.id) == ["9"], "what the second read said")
        #expect(said.sentence == L10n.t("collections.lost") && said.form == nil)
        #expect(await server.arrivals(of: Self.make) == 1)
    }

    @Test("Two quick writes are one: a second press while the first is out sends nothing")
    func twoQuickWrites() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection())], "DELETE /api/v1/collections/9": [.init(body: "")],
        ])
        await people.collections.opening(at: Self.host, in: session)
        await server.hold("DELETE /api/v1/collections/9")
        let first = Task { await people.collections.remove("9", in: session) }
        await met("the removal has arrived", by: first) { await server.arrivals(of: "DELETE /api/v1/collections/9") >= 1 }
        await people.collections.remove("9", in: session)
        await server.release("DELETE /api/v1/collections/9")
        await first.value
        #expect(await server.arrivals(of: "DELETE /api/v1/collections/9") == 1)
        #expect(people.collections.said()?.rows.isEmpty == true)
    }

    @Test("A write answered after the sign-in ended lands nowhere: the sheet is let go")
    func aSignInSwitch() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list()], Self.make: [Self.one(Self.collection())],
        ])
        await people.collections.opening(at: Self.host, in: session)
        people.collections.startMaking()
        people.collections.setDraft(CollectionDraft(name: "Friends"))
        await server.hold(Self.make)
        let work = Task { await people.collections.save(in: session) }
        await met("the post has arrived", by: work) { await server.arrivals(of: Self.make) >= 1 }
        try signOut(session)
        await server.release(Self.make)
        await work.value
        #expect(people.collections.said() == nil)
    }

    @Test("A read of the sheet still out does nothing to a press: acts wait for it, and send nothing")
    func aReadOnItsWay() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection())], "DELETE /api/v1/collections/9": [.init(body: "")],
        ])
        await server.hold(Self.ownList)
        let reading = Task { await people.collections.opening(at: Self.host, in: session) }
        await met("the read has arrived", by: reading) { await server.arrivals(of: Self.ownList) >= 1 }
        await people.collections.remove("9", in: session)
        #expect(await server.arrivals(of: "DELETE /api/v1/collections/9") == 0)
        await server.release(Self.ownList)
        await reading.value
        #expect(people.collections.said()?.rows.map(\.id) == ["9"])
    }

    @Test("Changing sends what differs alone, and the row becomes what came back; nothing differing sends nothing")
    func changing() async throws {
        let path = "PATCH /api/v1/collections/9"
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection())], path: [Self.one(Self.collection(found: false))],
        ])
        await people.collections.opening(at: Self.host, in: session)
        people.collections.startChanging("9")
        await people.collections.save(in: session)
        #expect(await server.arrivals(of: path) == 0)
        #expect(people.collections.said()?.form == nil)
        people.collections.startChanging("9")
        var draft = try #require(people.collections.said()?.form?.draft)
        draft.discoverable = false
        people.collections.setDraft(draft)
        await people.collections.save(in: session)
        #expect(await server.sent() == ["\(path) [discoverable=false]"])
        #expect(people.collections.said()?.rows.first?.hidden == true)
    }

    @Test("On somebody's sheet, a press puts them in by their id and a second takes them out by their place; one waiting on them says so")
    func somebodysSheet() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection(), Self.collection("8", name: "Waits", items: Self.item("3", of: "42", state: "pending")))],
            "POST /api/v1/collections/9/items": [.init(body: #"{"collection_item":\#(Self.item("5", of: "42"))}"#)],
            "DELETE /api/v1/collections/9/items/5": [.init(body: "")],
        ])
        await people.collections.opening(at: Self.host, person: ("42", "ada"), in: session)
        var said = try #require(people.collections.said())
        #expect(said.person == "ada" && said.rows.map(\.holds) == [false, true] && said.rows.map(\.waits) == [false, true])
        await people.collections.toggle("9", in: session)
        said = try #require(people.collections.said())
        #expect(said.rows.first?.holds == true && said.rows.first?.count == 1)
        await people.collections.toggle("9", in: session)
        said = try #require(people.collections.said())
        #expect(said.rows.first?.holds == false && said.rows.first?.count == 0)
        #expect(await server.sent() == ["POST /api/v1/collections/9/items [account_id=42]", "DELETE /api/v1/collections/9/items/5 []"])
    }

    @Test("Refused a person who does not let themselves be added, the row stays out and the sheet says so")
    func notAllowedToAdd() async throws {
        let (session, _, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection())],
            "POST /api/v1/collections/9/items": [.init(body: #"{"error":"This action is not allowed"}"#, status: 403)],
        ])
        await people.collections.opening(at: Self.host, person: ("42", "ada"), in: session)
        await people.collections.toggle("9", in: session)
        let said = try #require(people.collections.said())
        #expect(said.rows.first?.holds == false && said.sentence == L10n.t("collections.notAllowed.add") && said.live)
    }

    @Test("Opened as its owner, one's people are read signed with who waits on them, and one taken out leaves the sheet; removing and taking out each sit in … behind a question")
    func members() async throws {
        let whole = #"{"collection":\#(Self.collection(items: Self.item("3", of: "42", state: "pending"))),"accounts":[{"id":"42","username":"ada","acct":"ada","display_name":"Ada"}]}"#
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection())], "GET /api/v1/collections/9": [.init(body: whole)],
            "DELETE /api/v1/collections/9/items/3": [.init(body: "")],
        ])
        await people.collections.opening(at: Self.host, in: session)
        await people.collections.openMembers("9", in: session)
        let opened = try #require(people.collections.said()?.opened)
        #expect(opened.members.map(\.id) == ["3"] && opened.members.first?.waits == true)
        #expect(await server.bearer(of: "GET /api/v1/collections/9") == "Bearer tok")

        let body = CollectionsSheetBody(said: try #require(people.collections.said()))
        let member = body.more(opened.members[0], of: opened.name)
        #expect(member.ordinary.isEmpty && member.dangers.count == 1)
        var question: ShellConfirmation?
        member.dangers[0].press { question = $0.question }
        #expect(question?.chorded?.role == .destructive)
        let row = CollectionsSaid.Row(id: "9", name: "Friends", count: 0, hidden: false, warns: false)
        #expect(body.more(row).ordinary.count == 1 && body.more(row).dangers.count == 1)

        await people.collections.dropMember("3", in: session)
        #expect(people.collections.said()?.opened?.members.isEmpty == true)
    }

    // MARK: - The page behind

    @Test("On their own page the reader's collections are read signed, those not to be found among them, with the way to the sheet")
    func theOwnPage() async throws {
        let (session, server, people) = try await prepared([Self.ownList: [Self.list(Self.collection(found: false))]])
        let me = try #require(DummyPerson(handle: "@me@m.example", host: Self.host))
        let page = try Self.page(id: "7")
        await people.features.opened(me, said: page, in: session)
        #expect(await server.bearer(of: Self.ownList) == "Bearer tok")
        let said = try #require(people.features.said(of: me, said: page, own: true, in: session))
        #expect(said.tendsCollections && said.collections.map(\.accountID) == ["9"] && said.collectionsLock == nil)
        #expect(said.press(on: FeaturedSaid.tendID) == .tendCollections)
        #expect(said.collectionRows.first == FeaturedSaid.tendID)
    }

    @Test("A read of the page out when a write lands is no word: the page draws what was read after the write")
    func aReadOnItsWayToThePage() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection("old", name: "Before")), Self.list(Self.collection("new", name: "After"))],
        ])
        let me = try #require(DummyPerson(handle: "@me@m.example", host: Self.host))
        let page = try Self.page(id: "7")
        await server.hold(Self.ownList)
        let opening = Task { await people.features.opened(me, said: page, in: session) }
        await met("the page's read has arrived", by: opening) { await server.arrivals(of: Self.ownList) >= 1 }
        await people.features.collectionsChanged(of: "7", at: Self.host, in: session)
        await server.release(Self.ownList)
        await opening.value
        #expect(people.features.said(of: me, said: page, own: true, in: session)?.collections.map(\.accountID) == ["new"])
    }

    @Test("In another's collection, its row's … takes the reader out behind a question; pressed, the place is revoked and the page reads again without them; not in it, the row has no …")
    func takingOneselfOut() async throws {
        let theirs = "GET /api/v1/accounts/42/collections"
        let revoke = "POST /api/v1/collections/9/items/5/revoke"
        let (session, server, people) = try await prepared([
            theirs: [Self.list(Self.collection(items: Self.item("5", of: "7")), Self.collection("8"))],
            revoke: [.init(body: "")],
        ])
        let page = try Self.page()
        await people.features.opened(Self.ada, said: page, in: session)
        var said = try #require(people.features.said(of: Self.ada, said: page, own: false, in: session))
        #expect(!said.tendsCollections && said.takeOuts == ["9": "5"])
        let rows = said.collections
        let inIt = try #require(rows.first { $0.accountID == "9" }), outOf = try #require(rows.first { $0.accountID == "8" })
        #expect(said.more(ofCollection: outOf, act: {}, ask: {}) == nil)
        let more = try #require(said.more(ofCollection: inIt, act: {}, ask: {}))
        #expect(more.ordinary.isEmpty && more.dangers.first?.name == L10n.t("collections.takeOut"))
        var question: ShellConfirmation?
        more.dangers[0].press { question = $0.question }
        #expect(question?.chorded?.role == .destructive)

        await server.set(theirs, [Self.list(Self.collection(), Self.collection("8"))])
        await people.collections.takeOut(item: "5", of: "9", owner: "42", at: Self.host, in: session)
        #expect(await server.arrivals(of: revoke) == 1)
        said = try #require(people.features.said(of: Self.ada, said: page, own: false, in: session))
        #expect(said.takeOuts.isEmpty)
    }

    @Test("Refused taking out, the page stays as it was and says so; without the part the row is dim with the lock and the press only asks")
    func takingOutRefusedOrLocked() async throws {
        let theirs = "GET /api/v1/accounts/42/collections"
        let revoke = "POST /api/v1/collections/9/items/5/revoke"
        let (session, server, people) = try await prepared([
            theirs: [Self.list(Self.collection(items: Self.item("5", of: "7")))],
            revoke: [.init(body: #"{"error":"This action is not allowed"}"#, status: 403)],
        ])
        let page = try Self.page()
        await people.features.opened(Self.ada, said: page, in: session)
        await people.collections.takeOut(item: "5", of: "9", owner: "42", at: Self.host, in: session)
        #expect(people.features.said(of: Self.ada, said: page, own: false, in: session)?.takeOuts == ["9": "5"])
        #expect(session.toast?.text == L10n.t("collections.notAllowed"))
        #expect(await server.arrivals(of: theirs) == 1, "not read again: the source said what happened")

        try await signIn(session, scopes: Self.reading)
        await people.collections.takeOut(item: "5", of: "9", owner: "42", at: Self.host, in: session)
        #expect(await server.arrivals(of: revoke) == 1, "nothing more sent")
        #expect(session.partAsks.open?.host == Self.host)

        var locked = FeaturedSaid(source: Self.host)
        locked.collectionsLock = PartWords.Place(kind: .unasked, key: "part.collections.unasked")
        locked.takeOuts = ["9": "5"]
        let list = PeopleList(collection: PersonCollection(id: "9", name: "Friends", words: nil, count: 1), of: Person(source: Self.source, accountID: "42", handle: "ada", name: "Ada"))
        let dim = locked.more(ofCollection: list, act: {}, ask: {})
        #expect(dim?.items.first?.look == .dim(.askAgain))
    }

    // MARK: - Another account, and what was reviewed

    private static let remove9 = "DELETE /api/v1/collections/9"

    @Test("The decision of a person's page: a source that keeps them offers the item; one that said it has no such address does not; and a forum's kind says it does not offer them")
    func theRealOffer() async throws {
        let (session, _, people) = try await prepared([:])
        let page = try Self.page()
        #expect(people.acts.acting(of: Self.ada, said: page, in: session)?.collections == true)
        let hosts = try #require(people.acts.hosts)
        hosts.notFound(.collections, at: Self.host, round: hosts.round(at: Self.host))
        #expect(people.acts.acting(of: Self.ada, said: page, in: session)?.collections == false)
        #expect(!Self.forum.kind.offers.tendsCollections)
    }

    @Test("A write answered after another account signed in, known by the same name, lands nowhere")
    func anAccountChangeWithAWriteOut() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list()], Self.make: [Self.one(Self.collection())],
        ])
        await people.collections.opening(at: Self.host, in: session)
        people.collections.startMaking()
        people.collections.setDraft(CollectionDraft(name: "Friends"))
        await server.hold(Self.make)
        let work = Task { await people.collections.save(in: session) }
        await met("the post has arrived", by: work) { await server.arrivals(of: Self.make) >= 1 }
        try await signIn(session, scopes: Self.whole, token: "other")
        await server.release(Self.make)
        await work.value
        #expect(people.collections.said() == nil)
    }

    @Test("A read answered after another account signed in, known by the same name, lands nowhere")
    func anAccountChangeWithAReadOut() async throws {
        let (session, server, people) = try await prepared([Self.ownList: [Self.list(Self.collection())]])
        await server.hold(Self.ownList)
        let work = Task { await people.collections.opening(at: Self.host, in: session) }
        await met("the read has arrived", by: work) { await server.arrivals(of: Self.ownList) >= 1 }
        try await signIn(session, scopes: Self.whole, token: "other")
        await server.release(Self.ownList)
        await work.value
        #expect(people.collections.said() == nil)
    }

    @Test("A press on a sheet left up from another account sends nothing on the new sign-in's token, and the sheet goes")
    func aPressAfterAnAccountChange() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection())], Self.remove9: [.init(body: "")],
        ])
        await people.collections.opening(at: Self.host, in: session)
        try await signIn(session, scopes: Self.whole, token: "other")
        await people.collections.remove("9", in: session)
        #expect(await server.arrivals(of: Self.remove9) == 0)
        #expect(people.collections.said() == nil)
    }

    @Test("Opening after another account signed in stays open, read as them: the look comes before the sheet is kept")
    func openingLooksFirst() async throws {
        let (session, server, people) = try await prepared([Self.ownList: [Self.list(Self.collection())]])
        await people.collections.opening(at: Self.host, in: session)
        people.collections.close()
        try await signIn(session, scopes: Self.whole, token: "other")
        await people.collections.opening(at: Self.host, in: session)
        #expect(people.collections.said()?.rows.map(\.id) == ["9"])
        #expect(await server.bearer(of: Self.ownList) == "Bearer other")
    }

    @Test("A write taken with an answer that cannot be read is read again and Save has nothing left to send")
    func takenAndUnreadable() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(), Self.list(Self.collection())], Self.make: [.init(body: "<html>")],
        ])
        await people.collections.opening(at: Self.host, in: session)
        people.collections.startMaking()
        people.collections.setDraft(CollectionDraft(name: "Friends"))
        await people.collections.save(in: session)
        await people.collections.save(in: session)
        #expect(await server.arrivals(of: Self.make) == 1)
        #expect(await server.arrivals(of: Self.ownList) == 2)
        #expect(people.collections.said()?.rows.map(\.id) == ["9"] && people.collections.said()?.form == nil)
    }

    @Test("Return on the way to the reader's collections, the press About's lamp makes, opens the sheet; the root's keyboard path goes to that one press")
    func returnOnTheTendRow() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection())],
            "GET /api/v1/accounts/lookup": [.init(body: #"{"id":"7","acct":"me","username":"me"}"#)],
        ])
        let me = try #require(DummyPerson(handle: "@me@m.example", host: Self.host))
        await people.opened(me, in: session)
        await people.features.opened(me, said: people.said(of: me, in: session), in: session)
        let said = try #require(people.featured(of: me, in: session))
        let press = try #require(said.press(on: FeaturedSaid.tendID))
        let arrived = await server.arrivals(of: Self.ownList)
        #expect(people.collections.pressed(press, on: me, in: people, session: session))
        await met("the sheet's read has landed") { people.collections.said()?.rows.isEmpty == false }
        #expect(await server.arrivals(of: Self.ownList) == arrived + 1)
        let root = try Self.text("Sources/FediqoUI/FediqoRootView.swift")
        let inPath = try #require(root.components(separatedBy: "private func featuredPressed(").dropFirst().first)
        let theCase = try #require(inPath.components(separatedBy: "case .tendCollections, .takeOut:").dropFirst().first)
        let body = try #require(theCase.components(separatedBy: "\n    }\n").first)
        #expect(body.contains("guard let person = walk.openedPerson") && body.contains("people.collections.pressed(press, on: person"))
    }

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Return matches the pointer: a lock that may be asked is a press, one that may not is none; and the whole row is lit, locked too, when the lamp is on it")
    func theTendRowLocked() throws {
        var said = FeaturedSaid(source: Self.host, own: true)
        said.tendsCollections = true
        said.collectionsLock = PartWords.Place(kind: .unasked, key: "part.collections.unasked")
        #expect(try #require(said.collectionsLock).asks)
        #expect(said.press(on: FeaturedSaid.tendID) == .tendCollections)
        said.collectionsLock = PartWords.Place(kind: .none, key: "part.collections.unasked")
        #expect(try !#require(said.collectionsLock).asks)
        #expect(said.press(on: FeaturedSaid.tendID) == nil)

        #expect(FeaturedSaid.tendLamp(FeaturedSaid.tendID).lit && FeaturedSaid.tendLamp(FeaturedSaid.tendID).traits == .isSelected)
        #expect(!FeaturedSaid.tendLamp("about.words").lit && !FeaturedSaid.tendLamp(nil).lit)
        let about = try Self.text("Sources/FediqoUI/Shell/PersonAbout.swift")
        let row = try #require(about.components(separatedBy: "private func tendCollections(").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        let locked = try #require(row.range(of: "locked(String(format:")), lamp = try #require(row.range(of: "FeaturedSaid.tendLamp(lit)"))
        #expect(locked.lowerBound < lamp.lowerBound, "the lamp stands round both ways the row is drawn")
    }

    @Test("A lost answer and a read after it that fails say the one and the other, and the second claims nothing of what happened")
    func aLostAnswerThenAFailedRead() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(), .init(body: "down", status: 500)], Self.make: [.init(body: "", lost: true)],
        ])
        await people.collections.opening(at: Self.host, in: session)
        people.collections.startMaking()
        people.collections.setDraft(CollectionDraft(name: "Friends"))
        await people.collections.save(in: session)
        let said = try #require(people.collections.said())
        #expect(said.sentence == L10n.t("collections.lost") && said.failed == L10n.t("collections.readFailed"))
        for language in [DummyLanguage.english, .taiwanese] {
            let words = L10n.t("collections.readFailed", language: language)
            #expect(!words.contains("Nothing") && !words.contains("沒有任何變更"))
        }
        #expect(await server.arrivals(of: Self.make) == 1)
    }

    @Test("Saving a form that differs only by spaces at the edges sends nothing, and the form goes")
    func onlySpacesDiffer() async throws {
        let path = "PATCH /api/v1/collections/9"
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection())], path: [Self.one(Self.collection())],
        ])
        await people.collections.opening(at: Self.host, in: session)
        people.collections.startChanging("9")
        var draft = try #require(people.collections.said()?.form?.draft)
        draft.name += " "
        draft.words += "  "
        people.collections.setDraft(draft)
        await people.collections.save(in: session)
        #expect(await server.arrivals(of: path) == 0)
        #expect(people.collections.said()?.form == nil && people.collections.said()?.sentence == nil)
    }

    @Test("A read that fails says so with asking again: no empty sheet, Make not live, nothing said to have happened; asked again it draws")
    func aFailedRead() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [.init(body: "down", status: 500), Self.list(Self.collection())], Self.make: [Self.one(Self.collection())],
        ])
        await people.collections.opening(at: Self.host, in: session)
        var said = try #require(people.collections.said())
        #expect(said.failed == L10n.t("collections.readFailed") && !said.live && said.sentence == nil)
        people.collections.startMaking()
        #expect(people.collections.said()?.form == nil)
        await people.collections.again(in: session)
        said = try #require(people.collections.said())
        #expect(said.failed == nil && said.rows.map(\.id) == ["9"] && said.live)
        #expect(await server.arrivals(of: Self.make) == 0)
    }

    /// The source's own 401, on `ask` and on the door's own check after it.
    private func revoked(_ ask: String, on server: CollectionsServer) async {
        let gone = CollectionsServer.Answer(body: #"{"error":"The access token was revoked"}"#, status: 401)
        await server.set(ask, [gone])
        await server.set(Self.who, [gone])
    }

    @Test("The source taking the token back, a read of the sheet tells the row, and so does opening one in it")
    func aReadFindsItEnded() async throws {
        let (session, server, people) = try await prepared([:])
        await revoked(Self.ownList, on: server)
        await people.collections.opening(at: Self.host, in: session)
        #expect(session.mastodon.ended.contains(Self.host))

        let (again, secondServer, secondPeople) = try await prepared([Self.ownList: [Self.list(Self.collection())]])
        await secondPeople.collections.opening(at: Self.host, in: again)
        await revoked("GET /api/v1/collections/9", on: secondServer)
        await secondPeople.collections.openMembers("9", in: again)
        #expect(again.mastodon.ended.contains(Self.host))
    }

    @Test("The source taking the token back, a write of the sheet tells the row")
    func aWriteFindsItEnded() async throws {
        let (session, server, people) = try await prepared([Self.ownList: [Self.list(Self.collection())]])
        await people.collections.opening(at: Self.host, in: session)
        await revoked("DELETE /api/v1/collections/9", on: server)
        await people.collections.remove("9", in: session)
        #expect(session.mastodon.ended.contains(Self.host))
        #expect(await server.arrivals(of: "DELETE /api/v1/collections/9") == 1)
    }

    @Test("The source taking the token back, leaving another's collection tells the row")
    func leavingFindsItEnded() async throws {
        let revoke = "POST /api/v1/collections/9/items/5/revoke"
        let (session, server, people) = try await prepared([:])
        await revoked(revoke, on: server)
        await people.collections.takeOut(item: "5", of: "9", owner: "42", at: Self.host, in: session)
        #expect(session.mastodon.ended.contains(Self.host))
    }

    @Test("The source taking the token back, the read of the reader's own page tells the row; another's unsigned read says nothing of it")
    func thePageFindsItEnded() async throws {
        let (session, server, people) = try await prepared([:])
        await revoked(Self.ownList, on: server)
        let me = try #require(DummyPerson(handle: "@me@m.example", host: Self.host))
        await people.features.opened(me, said: try Self.page(id: "7"), in: session)
        #expect(session.mastodon.ended.contains(Self.host))

        let theirs = "GET /api/v1/accounts/42/collections"
        let (other, secondServer, secondPeople) = try await prepared([theirs: [.init(body: "{}", status: 401)]])
        await secondPeople.features.opened(Self.ada, said: try Self.page(), in: other)
        #expect(await secondServer.arrivals(of: theirs) == 1)
        #expect(!other.mastodon.ended.contains(Self.host))
    }

    @Test("Pressing a row of the reader's own collection reads its people as its owner, those not to be found among them; anyone else's, or without the word, is read unsigned")
    func theOwnCollectionsPeople() async throws {
        let members = "GET /api/v1/collections/9"
        let whole = #"{"collection":\#(Self.collection(found: false, items: Self.item("3", of: "42", state: "pending"))),"accounts":[{"id":"42","username":"ada","acct":"ada","display_name":"Ada"}]}"#
        let owner = Person(source: Self.source, accountID: "7", handle: "me", name: "Me")
        let stranger = Person(source: Self.source, accountID: "42", handle: "ada", name: "Ada")
        let collection = PersonCollection(id: "9", name: "Friends", words: nil, count: 1)

        let (session, server, people) = try await prepared([members: [.init(body: whole)]])
        let own = PeopleList(collection: collection, of: owner)
        await people.lists.opened(own, in: session)
        #expect(await server.bearer(of: members) == "Bearer tok")
        #expect(people.lists.said(of: own, in: session)?.people.count == 1)

        let (secondSession, secondServer, secondPeople) = try await prepared([members: [.init(body: whole)]])
        let theirs = PeopleList(collection: collection, of: stranger)
        await secondPeople.lists.opened(theirs, in: secondSession)
        #expect(await secondServer.bearer(of: members) == nil)

        let (thirdSession, thirdServer, thirdPeople) = try await prepared([members: [.init(body: whole)]], scopes: Self.reading)
        await thirdPeople.lists.opened(own, in: thirdSession)
        #expect(await thirdServer.bearer(of: members) == nil)
    }

    @Test("Not yet told who the reader is, opening asks the source; and told nothing, it says why and opens nothing")
    func anUnknownReader() async throws {
        let (session, server, people) = try await prepared([Self.ownList: [Self.list()]], scopes: nil)
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: Self.whole, asked: Self.whole
        ))
        session.mastodon.refresh()
        await server.set(Self.who, [.init(body: "down", status: 500), .init(body: #"{"id":"7","acct":"me","username":"me"}"#)])
        await people.collections.opening(at: Self.host, in: session)
        #expect(people.collections.said() == nil)
        #expect(session.toast?.text == String(format: L10n.t("collections.noReader"), Self.host))
        await people.collections.opening(at: Self.host, in: session)
        #expect(people.collections.said() != nil)
    }

    @Test("A collection gone is read again and sent to nobody a second time: removing it, or opening it, and its row leaves")
    func goneIsReadAgain() async throws {
        let gone = CollectionsServer.Answer(body: #"{"error":"Record not found"}"#, status: 404)
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection(), Self.collection("8")), Self.list(Self.collection("8")), Self.list()],
            Self.remove9: [gone], "GET /api/v1/collections/8": [gone],
        ])
        await people.collections.opening(at: Self.host, in: session)
        await people.collections.remove("9", in: session)
        #expect(people.collections.said()?.rows.map(\.id) == ["8"] && people.collections.said()?.sentence == L10n.t("collections.gone"))
        #expect(await server.arrivals(of: Self.remove9) == 1)
        await people.collections.openMembers("8", in: session)
        #expect(people.collections.said()?.rows.isEmpty == true && people.collections.said()?.opened == nil)
    }

    @Test("A place gone when the reader takes themselves out is read again, and the row's … leaves")
    func aPlaceGone() async throws {
        let theirs = "GET /api/v1/accounts/42/collections"
        let revoke = "POST /api/v1/collections/9/items/5/revoke"
        let (session, server, people) = try await prepared([
            theirs: [Self.list(Self.collection(items: Self.item("5", of: "7"))), Self.list(Self.collection())],
            revoke: [.init(body: #"{"error":"Record not found"}"#, status: 404)],
        ])
        let page = try Self.page()
        await people.features.opened(Self.ada, said: page, in: session)
        await people.collections.takeOut(item: "5", of: "9", owner: "42", at: Self.host, in: session)
        #expect(people.features.said(of: Self.ada, said: page, own: false, in: session)?.takeOuts.isEmpty == true)
        #expect(await server.arrivals(of: revoke) == 1)
    }

    @Test("Closing does not outrun a write: the sheet stays until it is answered, so no second can be sent")
    func closingDuringAWrite() async throws {
        let (session, server, people) = try await prepared([
            Self.ownList: [Self.list(Self.collection())], Self.remove9: [.init(body: "")],
        ])
        await people.collections.opening(at: Self.host, in: session)
        await server.hold(Self.remove9)
        let work = Task { await people.collections.remove("9", in: session) }
        await met("the removal has arrived", by: work) { await server.arrivals(of: Self.remove9) >= 1 }
        people.collections.close()
        #expect(people.collections.said()?.writing == true)
        await server.release(Self.remove9)
        await work.value
        people.collections.close()
        #expect(people.collections.said() == nil)
    }

    @Test("A stranger's words on the sheet are one line, and bounded")
    func wordsAreCleaned() async throws {
        let long = String(repeating: "x", count: 3_000)
        let (session, _, people) = try await prepared([
            Self.ownList: [.init(body: #"{"collections":[{"id":"9","name":"a\nb","description":"\#(long)","item_count":0,"items":[]}]}"#)],
        ])
        await people.collections.opening(at: Self.host, in: session)
        let row = try #require(people.collections.said()?.rows.first)
        #expect(!row.name.contains("\n"))
        #expect((row.words?.count ?? 0) <= CollectionsSaid.wordsLength + 1)
    }

    // MARK: - Words and shape

    @Test("Every word of the sheet and of the part is in each of the three string tables")
    func everyWord() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        func keys(_ language: String) throws -> Set<String> {
            let table = try String(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"), encoding: .utf8)
            return Set(table.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("\"collections.") || line.hasPrefix("\"part.collections.") else { return nil }
                return line.split(separator: "\"").first.map(String.init)
            })
        }
        let english = try keys("en")
        #expect(english.count > 30)
        #expect(try keys("zh-TW") == english)
        #expect(try keys("zh-Hant") == english)
    }

    @Test("The sheet takes the width it is given at 320 and 720, light and dark, in each of its states; a sentence, a row and a person each add height")
    func theSheetLaidOut() {
        func size(_ said: CollectionsSaid, _ width: CGFloat, _ scheme: ColorScheme) -> CGSize {
            let hosted = NSHostingView(rootView: VStack(spacing: 0) { CollectionsSheetBody(said: said) }.frame(width: width).environment(\.colorScheme, scheme))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize
        }
        let long = String(repeating: "a long name ", count: 4)
        let row = CollectionsSaid.Row(id: "9", name: long, words: long, count: 3, hidden: true, warns: true)
        var held = row
        held.holds = true
        held.waits = true
        let bare = CollectionsSaid(id: "a", source: Self.host)
        let states = [
            bare,
            CollectionsSaid(id: "a", source: Self.host, rows: [row]),
            CollectionsSaid(id: "a", source: Self.host, person: "ada", rows: [row, held]),
            CollectionsSaid(id: "a", source: Self.host, asking: true),
            CollectionsSaid(id: "a", source: Self.host, sentence: long),
            CollectionsSaid(id: "a", source: Self.host, failed: long),
            CollectionsSaid(id: "a", source: Self.host, form: .init(changing: nil, draft: CollectionDraft(name: long, words: long))),
            CollectionsSaid(id: "a", source: Self.host, opened: .init(id: "9", name: long, members: [.init(id: "3", name: long, handle: long, waits: true)])),
        ]
        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (720, .dark), (320, .light), (320, .dark)] {
            for state in states {
                let drawn = size(state, width, scheme)
                #expect(drawn.width == width && drawn.height > 0, "\(state) at \(width)")
            }
            #expect(size(states[4], width, scheme).height > size(bare, width, scheme).height, "a sentence is drawn")
            #expect(size(CollectionsSaid(id: "a", source: Self.host, person: "ada", rows: [row, held]), width, scheme).height
                > size(CollectionsSaid(id: "a", source: Self.host, person: "ada", rows: [row]), width, scheme).height, "each row is drawn")
            let member = CollectionsSaid.Member(id: "3", name: long, handle: long, waits: true)
            #expect(size(CollectionsSaid(id: "a", source: Self.host, opened: .init(id: "9", name: long, members: [member, member])), width, scheme).height
                > size(CollectionsSaid(id: "a", source: Self.host, opened: .init(id: "9", name: long, members: [member])), width, scheme).height, "each person is drawn")
        }
    }
}
