import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A server that answers an act by path, remembering every request, and holding one path until
/// the test lets it through so a press can be caught on its way. Target-visible, since the answer
/// and the take-back suites ask the same kind of server the same kind of question.
actor ActServer: HTTPSender {
    enum Outcome: Sendable {
        case json(String, status: Int = 200)
        case fail
    }

    private let routes: [String: Outcome]
    private let held: String?
    private let gate: Gate?
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: Outcome], holding held: String? = nil, gate: Gate? = nil) {
        self.routes = routes
        self.held = held
        self.gate = gate
    }

    var paths: [String] { requests.compactMap { $0.url?.path } }

    var methods: [String] { requests.compactMap(\.httpMethod) }

    func form(_ path: String) -> [String: String] {
        guard let request = requests.first(where: { $0.url?.path == path }),
              let body = request.httpBody, let text = String(data: body, encoding: .utf8)
        else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return fields
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let held, request.url?.path == held {
            await gate?.wait()
        }
        guard let url = request.url, let outcome = routes[url.path] else {
            throw FixtureHTTPError.unmapped
        }
        switch outcome {
        case .json(let body, let status):
            return (
                Data(body.utf8),
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        case .fail:
            throw URLError(.notConnectedToInternet)
        }
    }
}

/// A post is boosted to the source it was read through (#106), and favourited there (#107).
///
/// What a test can reach: which posts offer the mark and what the row says where one does not;
/// the glyph and the spoken sentence for each state in all three languages; the key; the press
/// going on its way, failing, being tried again and landing; and that nothing about the press is
/// remembered once the source has answered. What it cannot: that the mark is drawn where the
/// rule says, on a Mac and a phone, in light and dark — that lives in a view body.
@Suite("Boosting and favouriting a post")
@MainActor
struct ActTests {
    init() {
        L10n.language = .english
    }

    private let host = "social.example"
    private let forum = "bbs.example.org"
    private let writing = MastodonOAuth.scopes(writing: true)

    static func status(reblogged: Bool? = nil, favourited: Bool? = nil) -> String {
        let flag = (reblogged.map { #","reblogged":\#($0)"# } ?? "")
            + (favourited.map { #","favourited":\#($0)"# } ?? "")
        return """
        {"id":"9","uri":"https://social.example/users/ada/statuses/9",
         "created_at":"2024-06-01T00:00:00.000Z","content":"<p>hello</p>",
         "visibility":"public"\(flag),
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private func note(
        boosted: Bool?, favourited: Bool? = nil, statusID: String? = "9", host: String? = nil
    ) -> Note {
        Note(
            id: "https://social.example/users/ada/statuses/9",
            source: Source(host: host ?? self.host, kind: .mastodon),
            author: "Ada", handle: "@ada@social.example", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home],
            boosted: boosted, favourited: favourited, statusID: statusID
        )
    }

    private func shell(
        scopes: String?,
        holding: Note,
        routes: [String: ActServer.Outcome] = [:],
        held path: String? = nil,
        gate: Gate? = nil
    ) async throws -> (ShellSession, ActServer) {
        let tokens = MemoryMastodonTokens()
        if let scopes {
            try tokens.save(MastodonToken(
                host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
                scopes: scopes
            ))
        }
        let server = ActServer(routes, holding: path, gate: gate)
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon))
        await store.add(Source(host: forum, kind: .discuz))
        await store.ingest([holding])
        let session = ShellSession(
            http: FixtureHTTP(), store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        return (session, server)
    }

    private func row(_ session: ShellSession) throws -> DummyItem {
        DummyItem(try #require(session.notes.first))
    }

    // MARK: - Offered, or said why not

    @Test("Only a post on a source signed in with writing offers the mark; the rest say why")
    func whoOffersTheMark() async throws {
        let (writes, _) = try await shell(scopes: writing, holding: note(boosted: false))
        #expect(writes.acts(on: try row(writes)).offers(.boost))

        let (reads, _) = try await shell(scopes: MastodonOAuth.reading, holding: note(boosted: false))
        #expect(reads.acts(on: try row(reads)) == PostActs(offered: [], refused: .notSignedIn))

        let (unsigned, _) = try await shell(scopes: nil, holding: note(boosted: nil))
        #expect(unsigned.acts(on: try row(unsigned)).refused == .notSignedIn)

        let (refused, _) = try await shell(scopes: writing, holding: note(boosted: false))
        refused.mastodon.refusedWrite(host: host)
        #expect(refused.acts(on: try row(refused)).refused == .turnedAway)

        let (bare, _) = try await shell(scopes: writing, holding: note(boosted: nil, statusID: nil))
        #expect(bare.acts(on: try row(bare)).refused == .unnameable)

        let forumPost = Note(
            id: "t1", source: Source(host: forum, kind: .discuz), author: "Bo", handle: "Bo",
            body: "hi", postedAt: Date(timeIntervalSince1970: 0), categories: []
        )
        #expect(writes.acts(on: DummyItem(forumPost)).refused == .protocolCannot)
    }

    @Test("Every reason a row gives is a sentence in every language")
    func everyRefusalIsWorded() {
        for language in [DummyLanguage.english, .taiwanese] {
            var said: Set<String> = []
            for refusal in PostActRefusal.allCases {
                let line = ItemActs.refusalLine(refusal, language: language)
                #expect(!line.hasPrefix("item.act."), "\(refusal) has no words in \(language)")
                said.insert(line)
            }
            #expect(said.count == PostActRefusal.allCases.count, "two reasons read the same")
        }
    }

    // MARK: - The mark, and what it says

    @Test("The mark shows on its way and a failure by shape, not only by colour")
    func theMarkChangesShape() {
        let settled = ItemActs.symbol(.boost, done: false, standing: nil)
        #expect(ItemActs.symbol(.boost, done: true, standing: nil) == settled)
        #expect(ItemActs.symbol(.boost, done: false, standing: .onItsWay) != settled)
        #expect(ItemActs.symbol(.boost, done: false, standing: .failed) != settled)
        #expect(ItemActs.symbol(.boost, done: false, standing: .failed)
            != ItemActs.symbol(.boost, done: false, standing: .onItsWay))
    }

    @Test("VoiceOver hears the mark, which way a press goes, and where the last press got to")
    func theMarkIsSpoken() {
        #expect(ItemActs.spoken(.boost, done: false, standing: nil) == "Boost")
        #expect(ItemActs.spoken(.boost, done: true, standing: nil) == "Take the boost back")
        #expect(ItemActs.spoken(.boost, done: false, standing: .onItsWay) == "Boost on its way")
        #expect(ItemActs.spoken(.boost, done: false, standing: .failed)
            == "Boost did not arrive. Press to try again.")
        for language in [DummyLanguage.english, .taiwanese] {
            for done in [false, true] {
                for standing in [nil, ShellActStanding.onItsWay, .failed] {
                    let said = ItemActs.spoken(.boost, done: done, standing: standing, language: language)
                    #expect(!said.contains("item.act."), "untranslated in \(language): \(said)")
                }
            }
        }
    }

    @Test("b boosts, and is the draft's while composing")
    func theKey() {
        #expect(DummyCommand.from("b") == .boost)
        #expect(DummyCommand.from("b", typing: true) == nil)
        #expect(DummyCommand.from("b", fieldFocused: true) == nil)
        #expect(DummyShortcut.all.contains { $0.commands == [.boost] && $0.group == .timeline })
    }

    // MARK: - The press

    @Test("A press is on its way until the source answers, and a second press sends nothing more",
          .timeLimit(.minutes(1)))
    func onItsWay() async throws {
        let gate = Gate()
        let (session, server) = try await shell(
            scopes: writing, holding: note(boosted: false),
            routes: ["/api/v1/statuses/9/reblog": .json(Self.status(reblogged: true))],
            held: "/api/v1/statuses/9/reblog", gate: gate
        )
        let item = try row(session)
        let watchdog = hangGuard(gate)
        let first = Task { await session.boost(item) }
        #expect(await spun { await server.paths.count == 1 })
        #expect(session.acts.isOnItsWay(item.id, .boost))
        await session.boost(item)
        #expect(await server.paths == ["/api/v1/statuses/9/reblog"], "one act, not two")
        await gate.open()
        await first.value
        watchdog.cancel()
        #expect(session.acts.standing(of: item.id, .boost) == nil)
        #expect(session.notes.first?.boosted == true)
    }

    @Test("A failure leaves the post as it was, says so, and the same press tries again")
    func aFailureCanBeTriedAgain() async throws {
        let (session, server) = try await shell(
            scopes: writing, holding: note(boosted: false),
            routes: ["/api/v1/statuses/9/reblog": .fail]
        )
        let item = try row(session)
        await session.boost(item)
        #expect(session.acts.standing(of: item.id, .boost) == .failed)
        #expect(session.notes.first?.boosted == false)
        #expect(session.acts(on: item).offers(.boost), "a miss is not a refusal; the mark stays")

        await session.boost(item)
        #expect(await server.paths.count == 2, "pressing again asks again")
    }

    @Test("A refusal marks the source as turning writes away, and the post is unchanged")
    func aRefusalIsSaid() async throws {
        let (session, _) = try await shell(
            scopes: writing, holding: note(boosted: false),
            routes: ["/api/v1/statuses/9/reblog": .json("{}", status: 403)]
        )
        let item = try row(session)
        await session.boost(item)
        #expect(session.acts.standing(of: item.id, .boost) == .failed)
        #expect(session.notes.first?.boosted == false)
        #expect(session.acts(on: item).refused == .turnedAway)
    }

    @Test("Taking a boost back is the same press, read off what the source last said")
    func unboostIsTheSamePress() async throws {
        let (session, server) = try await shell(
            scopes: writing, holding: note(boosted: true),
            routes: ["/api/v1/statuses/9/unreblog": .json(Self.status(reblogged: false))]
        )
        await session.boost(try row(session))
        #expect(await server.paths == ["/api/v1/statuses/9/unreblog"])
        #expect(session.notes.first?.boosted == false)
    }

    @Test("A post that does not offer the mark sends nothing when pressed")
    func aRefusedPostSendsNothing() async throws {
        let (session, server) = try await shell(scopes: MastodonOAuth.reading, holding: note(boosted: false))
        await session.boost(try row(session))
        #expect(await server.paths.isEmpty)
        #expect(session.acts.standings.isEmpty)
    }

    // MARK: - Not remembered by this device

    @Test("What landed is the source's answer; nothing about the press is kept")
    func nothingIsRemembered() async throws {
        let (session, _) = try await shell(
            scopes: writing, holding: note(boosted: false),
            routes: ["/api/v1/statuses/9/reblog": .json(Self.status(reblogged: true))]
        )
        await session.boost(try row(session))
        #expect(session.acts.standings.isEmpty, "a landed act leaves no record of its own")
        #expect(try row(session).boosted == true)

        // A fresh session over a store that only holds what a fetch said draws the same thing —
        // a boost made in another app, and this one after a relaunch, read alike.
        let (relaunched, _) = try await shell(scopes: writing, holding: note(boosted: true))
        #expect(relaunched.acts.standings.isEmpty)
        #expect(try row(relaunched).boosted == true)
    }

    @Test("A Clear lets go of acts on that source")
    func clearForgetsActs() {
        let acts = ShellActs()
        let here = NoteKey(host: host, id: "a").rowID
        let there = NoteKey(host: "other.example", id: "a").rowID
        acts.failed(here, .boost)
        acts.failed(there, .boost)
        acts.forget(host: host)
        #expect(acts.standing(of: here, .boost) == nil)
        #expect(acts.standing(of: there, .boost) == .failed)
    }

    // MARK: - Favouriting (#107)

    @Test("The star is offered exactly where the boost is, and says why exactly where it does")
    func theStarIsOfferedLikeTheBoost() async throws {
        for scopes in [writing, MastodonOAuth.reading, nil] {
            let (session, _) = try await shell(scopes: scopes, holding: note(boosted: false, favourited: false))
            let acts = session.acts(on: try row(session))
            #expect(acts.offers(.favourite) == acts.offers(.boost))
        }
    }

    @Test("The star fills when the source says it is done, and changes shape on its way")
    func theStar() {
        #expect(ItemActs.symbol(.favourite, done: false, standing: nil) == "star")
        #expect(ItemActs.symbol(.favourite, done: true, standing: nil) == "star.fill")
        #expect(ItemActs.symbol(.favourite, done: true, standing: .onItsWay) != "star.fill")
        #expect(ItemActs.symbol(.favourite, done: false, standing: .failed) != "star")
        #expect(ItemActs.spoken(.favourite, done: false, standing: nil) == "Favourite")
        #expect(ItemActs.spoken(.favourite, done: true, standing: nil) == "Take the favourite back")
        #expect(ItemActs.spoken(.favourite, done: false, standing: .failed)
            == "Favourite did not arrive. Press to try again.")
        for done in [false, true] {
            let said = ItemActs.spoken(.favourite, done: done, standing: .onItsWay, language: .taiwanese)
            #expect(!said.contains("item.act."), "untranslated: \(said)")
        }
    }

    @Test("f favourites, and is the draft's while composing")
    func theFavouriteKey() {
        #expect(DummyCommand.from("f") == .favourite)
        #expect(DummyCommand.from("f", typing: true) == nil)
    }

    @Test("A favourite lands as the source's answer and leaves the boost alone")
    func aFavouriteLands() async throws {
        let (session, server) = try await shell(
            scopes: writing, holding: note(boosted: false, favourited: false),
            routes: ["/api/v1/statuses/9/favourite": .json(Self.status(reblogged: false, favourited: true))]
        )
        await session.favourite(try row(session))
        #expect(await server.paths == ["/api/v1/statuses/9/favourite"])
        #expect(session.notes.first?.favourited == true)
        #expect(session.notes.first?.boosted == false)
        #expect(session.acts.standings.isEmpty, "nothing about the press is kept")
    }

    @Test("A failed favourite leaves the post as it was and the same press tries again")
    func aFailedFavourite() async throws {
        let (session, server) = try await shell(
            scopes: writing, holding: note(boosted: false, favourited: true),
            routes: ["/api/v1/statuses/9/unfavourite": .fail]
        )
        let item = try row(session)
        await session.favourite(item)
        #expect(session.acts.standing(of: item.id, .favourite) == .failed)
        #expect(session.acts.standing(of: item.id, .boost) == nil, "one act's failure is not another's")
        #expect(session.notes.first?.favourited == true)
        await session.favourite(item)
        #expect(await server.paths == ["/api/v1/statuses/9/unfavourite", "/api/v1/statuses/9/unfavourite"])
    }

    @Test("A favourite held by another app reads as done here; this device keeps no list of its own")
    func noLocalFavourites() async throws {
        let (session, _) = try await shell(scopes: writing, holding: note(boosted: false, favourited: true))
        #expect(try row(session).favourited == true)
        #expect(DummyMarks() == DummyMarks(bookmarked: false, kept: false),
                "the device-local marks no longer carry a favourite")
    }

    // MARK: - An answer read inside a conversation

    static func answer(id: String, favourited: Bool? = nil) -> String {
        let flag = favourited.map { #","favourited":\#($0)"# } ?? ""
        return """
        {"id":"\(id)","uri":"https://social.example/users/bo/statuses/\(id)",
         "created_at":"2024-06-01T01:00:00.000Z","content":"<p>an answer</p>",
         "visibility":"public","in_reply_to_id":"9"\(flag),
         "account":{"username":"bo","acct":"bo","display_name":"Bo"}}
        """
    }

    @Test("An act on an answer read in an open conversation reaches the source and the thread says so")
    func anActOnAnAnswerInAThread() async throws {
        let (session, server) = try await shell(
            scopes: writing, holding: note(boosted: false, favourited: false),
            routes: [
                "/api/v1/statuses/9/context": .json(
                    #"{"ancestors":[],"descendants":["# + Self.answer(id: "12", favourited: false) + "]}"
                ),
                "/api/v1/statuses/12/favourite": .json(Self.answer(id: "12", favourited: true)),
            ]
        )
        let root = try row(session)
        await session.conversations.open(root, in: session)
        let reply = try #require(session.conversations.conversation(around: root).descendants.first?.item)
        #expect(!session.notes.contains { $0.key.rowID == reply.id }, "the answer is not a store row")
        #expect(session.acts(on: reply).offers(.favourite))

        await session.favourite(reply)
        #expect(await server.paths.last == "/api/v1/statuses/12/favourite")
        #expect(session.acts.standings.isEmpty)
        let after = try #require(session.conversations.conversation(around: root).descendants.first?.item)
        #expect(after.favourited == true, "the thread draws what the source answered")
    }
}
