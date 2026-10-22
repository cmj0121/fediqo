import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A source that answers by method and path, remembering every request.
actor ChangeServer: HTTPSender {
    private var routes: [String: [(body: String, status: Int)]]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: [(body: String, status: Int)]]) {
        self.routes = routes
    }

    var puts: [URLRequest] { requests.filter { $0.httpMethod == "PUT" } }

    static func form(_ request: URLRequest) -> [(String, String)] {
        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return [] }
        return text.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0].removingPercentEncoding ?? parts[0], (parts.count > 1 ? parts[1].removingPercentEncoding : "") ?? "")
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        func answered(_ body: String, _ status: Int) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        if url.path == "/api/v1/accounts/verify_credentials" { return answered(#"{"id":"1","acct":"me"}"#, 200) }
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        guard var answers = routes[key], !answers.isEmpty else { throw FixtureHTTPError.unmapped }
        let next = answers.count > 1 ? answers.removeFirst() : answers[0]
        routes[key] = answers
        return answered(next.body, next.status)
    }
}

/// #332 through the session: the own post's `…` offers Change, the sheet opens on what the post
/// was written from, a poll whose choices change warns before votes are lost, and Save hands
/// the change to the outbox — which lands it on the post's own row as a new revision.
@MainActor
@Suite("Changing one's own post", .watched)
struct ChangePostTests {
    init() {
        L10n.language = .english
    }

    private static let host = "social.example"
    private static let uri = "https://social.example/users/me/statuses/9"
    private static let path = "/api/v1/statuses/9"

    private static func poll(ends: String = "2099-01-01T00:00:00.000Z", expired: Bool = false, votes: Int = 2) -> String {
        """
        {"id":"7","expires_at":"\(ends)","expired":\(expired),"multiple":false,"votes_count":\(votes),"voters_count":\(votes),"voted":true,"own_votes":[],
         "options":[{"title":"A","votes_count":\(votes)},{"title":"B","votes_count":0},{"title":"C","votes_count":0}],"emojis":[]}
        """
    }

    private static func status(_ words: String, edited: String? = nil, poll: String = "null", by name: String = "me") -> String {
        """
        {"id":"9","uri":"\(uri)","created_at":"2026-10-01T00:00:00.000Z","content":"<p>\(words)</p>",
         "visibility":"unlisted","language":"en","sensitive":false,"spoiler_text":"",
         "edited_at":\(edited.map { "\"\($0)\"" } ?? "null"),
         "account":{"username":"\(name)","acct":"\(name)","display_name":"\(name)"},
         "media_attachments":[],"poll":\(poll)}
        """
    }

    private static func source(_ text: String) -> String { #"{"id":"9","text":"\#(text)","spoiler_text":""}"# }

    private func note(_ json: String) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: Source(host: Self.host, kind: .mastodon), category: .home, sent: .now())
    }

    /// A session signed in to the source as `@me`, holding `notes`.
    private func run(
        _ server: ChangeServer, holding notes: [Note], scopes: String = MastodonOAuth.scopes(writing: true)
    ) async throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.host, accessToken: "tok-1", clientID: "c", clientSecret: "s", scopes: scopes))
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        await store.ingest(notes)
        let session = ShellSession(http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server))
        session.said.announce = { _ in }
        session.mastodon.deadlineSleep = TurnedClock().sleep
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        await session.reloadFromStore()
        return session
    }

    private func row(_ session: ShellSession) throws -> DummyItem {
        try #require(session.notes.first { $0.statusID == "9" }.flatMap { session.held($0.key.rowID) })
    }

    // MARK: - The item

    @Test("The own post's `…` offers Change it…, after the marks and the way out and before Report and taking back; somebody else's post offers none")
    func offered() async throws {
        let session = try await run(ChangeServer([:]), holding: [try note(Self.status("mine"))])
        let item = try row(session)
        var acting = session.acting(on: item)
        acting.change = ItemActing.Change(lock: nil) {}
        let menu = ItemActs.more(on: item, acting: acting, leave: {})
        let names = menu.items.map(\.name)
        let change = try #require(names.firstIndex(of: "Change it…"))
        #expect(names.firstIndex(of: item.outwardName).map { $0 < change } == true)
        #expect(menu.items[change].symbol == "pencil" && menu.items[change].look == .live)
        #expect(session.changeOffer(on: item)?.lock == nil)

        let theirs = try await run(ChangeServer([:]), holding: [try note(Self.status("theirs", by: "ada"))])
        #expect(theirs.changeOffer(on: try row(theirs)) == nil)
    }

    @Test("A sign-in that only reads draws Change dim with the lock, says the lock's words in the head, and its press asks")
    func lockedWithoutWriting() async throws {
        let session = try await run(ChangeServer([:]), holding: [try note(Self.status("mine"))], scopes: MastodonOAuth.scopes(writing: false))
        let item = try row(session)
        let offer = try #require(session.changeOffer(on: item))
        let lock = try #require(offer.lock)
        var acting = ItemActing()
        acting.change = ItemActing.Change(lock: lock) {}
        let own = ItemActs.ownItems(on: item, acting: acting)
        #expect(own.items.count == 1 && own.items[0].look == .dim(.askAgain) && own.items[0].symbol == SourceRow.permissionSymbol)
        #expect(own.reasons == [lock.line() ?? String(format: L10n.t(lock.place.key), Self.host)] && !own.reasons[0].isEmpty)
    }

    // MARK: - The sheet, and Save

    @Test("The sheet opens on what the post was written from, with who may read it fixed; Save hands the change to the outbox, which sends it as a change and lands it on the same row as a new revision")
    func aChangeLands() async throws {
        let server = ChangeServer([
            "GET \(Self.path)/source": [(Self.source("before, as typed"), 200)],
            "GET \(Self.path)": [(Self.status("before"), 200)],
            "PUT \(Self.path)": [(Self.status("after", edited: "2026-10-02T00:00:00.000Z"), 200)],
        ])
        let session = try await run(server, holding: [try note(Self.status("before"))])
        let item = try row(session)
        session.changes.start(item, in: session)
        await session.changes.settled()
        #expect(session.changes.phase == .ready)
        #expect(session.changes.draft.text == "before, as typed" && session.changes.draft.audience == .unlisted)
        #expect(session.changes.open?.audience == .unlisted)
        #expect(ChangeWords.whereLine(host: Self.host, audience: .unlisted, answering: nil) == "At social.example · unlisted")
        #expect(!session.changes.touched)

        session.changes.draft.text = "after"
        #expect(session.changes.save(in: session))
        #expect(session.changes.open == nil, "the sheet closes at the press")
        await session.outbox.settled()

        let put = try #require(await server.puts.first)
        #expect(put.value(forHTTPHeaderField: "Idempotency-Key") == nil)
        #expect(ChangeServer.form(put).first { $0.0 == "status" }?.1 == "after")
        #expect(ChangeServer.form(put).allSatisfy { $0.0 != "visibility" })
        let after = try row(session)
        #expect(after.id == item.id && after.body == "after" && after.earlier.map(\.body) == ["before"])
        #expect(session.notes.filter { $0.statusID == "9" }.count == 1, "no new row")
        #expect(session.outbox.sendings.isEmpty)
    }

    @Test("Changing the poll's choices warns, and Save asks first where the poll has votes — nothing is taken until the yes; a run or figures hidden changed asks nothing")
    func votesAreAskedAbout() async throws {
        let server = ChangeServer([
            "GET \(Self.path)/source": [(Self.source("which?"), 200)],
            "GET \(Self.path)": [(Self.status("which?", poll: Self.poll()), 200)],
        ])
        let session = try await run(server, holding: [try note(Self.status("which?", poll: Self.poll()))])
        session.changes.start(try row(session), in: session)
        await session.changes.settled()
        var poll = try #require(session.changes.draft.poll)
        #expect(!session.changes.resets)
        poll.hidesTotals = true
        poll.runs = 7200
        session.changes.draft.poll = poll
        #expect(!session.changes.resets)

        poll.choices = ["B", "A", "C"]
        session.changes.draft.poll = poll
        #expect(session.changes.resets)
        let source = try #require(session.changes.source)
        #expect(ChangeWords.resetLine(source) == "Changing the choices, or whether more than one may be chosen, starts the poll again: its 2 votes are lost.")
        #expect(!session.changes.save(in: session), "asked first")
        #expect(session.changes.askingVotes != nil && session.outbox.sendings.isEmpty)
        let question = ChangeWords.question(source, host: Self.host)
        #expect(question.warns && question.line.contains("2 votes"))
        #expect(session.changes.commit(in: session))
        #expect(session.outbox.sendings.count == 1 && session.outbox.sendings[0].unsent.changes?.statusID == "9")
    }

    @Test("An ended poll asks for a run again, or for the poll to go: Save waits until one is chosen")
    func anEndedPoll() async throws {
        let ended = Self.poll(ends: "2026-10-01T01:00:00.000Z", expired: true)
        let server = ChangeServer([
            "GET \(Self.path)/source": [(Self.source("which?"), 200)],
            "GET \(Self.path)": [(Self.status("which?", poll: ended), 200)],
        ])
        let session = try await run(server, holding: [try note(Self.status("which?", poll: ended))])
        session.changes.start(try row(session), in: session)
        await session.changes.settled()
        #expect(session.changes.draft.poll?.runs == 0)
        #expect(session.changes.pollSays(in: session) == ChangeWords.endedLine())
        #expect(!session.changes.canSave(in: session))
        session.changes.draft.poll?.runs = 3600
        #expect(session.changes.canSave(in: session))
        session.changes.draft.poll = nil
        #expect(session.changes.canSave(in: session))
    }

    @Test("A source that cannot say what the post was written from draws no editor, and Try again asks again")
    func readFailed() async throws {
        let server = ChangeServer([
            "GET \(Self.path)/source": [("{}", 500), (Self.source("again"), 200)],
            "GET \(Self.path)": [(Self.status("before"), 200)],
        ])
        let session = try await run(server, holding: [try note(Self.status("before"))])
        session.changes.start(try row(session), in: session)
        await session.changes.settled()
        #expect(session.changes.phase == .failed && !session.changes.canSave(in: session))
        session.changes.retry(in: session)
        await session.changes.settled()
        #expect(session.changes.phase == .ready && session.changes.draft.text == "again")
    }

    @Test("Cancel over nothing changed closes; over a change typed, it asks first")
    func cancelAsks() async throws {
        let server = ChangeServer([
            "GET \(Self.path)/source": [(Self.source("before"), 200)],
            "GET \(Self.path)": [(Self.status("before"), 200)],
        ])
        let session = try await run(server, holding: [try note(Self.status("before"))])
        session.changes.start(try row(session), in: session)
        await session.changes.settled()
        #expect(!ChangeSheet.holdsOnSwipe(session.changes), "nothing typed: a swipe closes it")
        session.changes.draft.text = "typed"
        #expect(ChangeSheet.holdsOnSwipe(session.changes), "typed: a swipe does not take it")
        #expect(!session.changes.cancel())
        #expect(session.changes.askingDiscard == Self.host && session.changes.open != nil)
        session.changes.draft.text = "before"
        session.changes.askingDiscard = nil
        #expect(session.changes.cancel())
        #expect(session.changes.open == nil)
    }

    // MARK: - In the outbox

    @Test("A post gone at its source holds the change as having nowhere to go, with Discard alone; one change a post — a second Save replaces one that waits")
    func goneAndReplaced() async throws {
        let server = ChangeServer([
            "GET \(Self.path)/source": [(Self.source("before"), 200)],
            "GET \(Self.path)": [(Self.status("before"), 200)],
            "PUT \(Self.path)": [("{}", 500), (#"{"error":"Record not found"}"#, 404)],
        ])
        let session = try await run(server, holding: [try note(Self.status("before"))])
        let item = try row(session)
        session.changes.start(item, in: session)
        await session.changes.settled()
        session.changes.draft.text = "first"
        #expect(session.changes.save(in: session))
        await session.outbox.settled()
        let first = try #require(session.outbox.sendings.first)
        #expect(first.standing == .unconfirmed)
        #expect(OutboxWords.line(first, hold: nil, whom: nil) == "social.example did not say whether it took the change. Send again sends the same change.")

        session.changes.start(item, in: session)
        await session.changes.settled()
        session.changes.draft.text = "second"
        #expect(session.changes.save(in: session))
        await session.outbox.settled()
        #expect(session.outbox.sendings.count == 1 && session.outbox.sendings[0].unsent.text == "second")
        let gone = try #require(session.outbox.sendings.first)
        let hold = session.outbox.hold(gone, in: session)
        #expect(hold == .changeGone)
        #expect(OutboxWords.presses(gone, hold: hold) == [.discard])
        #expect(OutboxWords.line(gone, hold: hold, whom: nil) == "The post is gone at social.example, so the change has nowhere to go.")
    }

    @Test("A change waiting for a post whose row was let go for room still goes to it: the post is kept for the change, and Send again sends it")
    func aRowLetGoForRoom() async throws {
        let server = ChangeServer([
            "GET \(Self.path)/source": [(Self.source("before"), 200)],
            "GET \(Self.path)": [(Self.status("before"), 200)],
            "PUT \(Self.path)": [("{}", 500), (Self.status("after", edited: "2026-10-02T00:00:00.000Z"), 200)],
        ])
        let session = try await run(server, holding: [try note(Self.status("before"))])
        session.changes.start(try row(session), in: session)
        await session.changes.settled()
        session.changes.draft.text = "after"
        #expect(session.changes.save(in: session))
        await session.outbox.settled()
        let waiting = try #require(session.outbox.sendings.first)
        _ = await session.store.letGoOldest(count: 1)
        await session.reloadFromStore()
        #expect(session.notes.isEmpty, "the premise: the row went for room")
        #expect(session.outbox.hold(waiting, in: session) == nil)
        #expect(session.outbox.again(waiting.id, in: session))
        await session.outbox.settled()
        #expect(await server.puts.count == 2 && session.outbox.sendings.isEmpty)
    }

    @Test("Save asks again whether the post is one to change: one taken back while the sheet was up takes nothing")
    func saveAsksAgain() async throws {
        let server = ChangeServer([
            "GET \(Self.path)/source": [(Self.source("before"), 200)],
            "GET \(Self.path)": [(Self.status("before"), 200)],
        ])
        let session = try await run(server, holding: [try note(Self.status("before"))])
        let item = try row(session)
        session.changes.start(item, in: session)
        await session.changes.settled()
        session.changes.draft.text = "after"
        await session.store.forget(try #require(session.notes.first).key)
        await session.reloadFromStore()
        #expect(!session.changes.commit(in: session))
        #expect(session.outbox.sendings.isEmpty)
    }

    // MARK: - What it said before

    @Test("Earlier wordings from the source begin with the post as first written; each line is one thing VoiceOver reads")
    func earlierWordings() throws {
        var item = DummyItem(try note(Self.status("now", edited: "2026-10-02T00:00:00.000Z")))
        let until = try #require(MastodonJSON.date(from: "2026-10-01T12:00:00.000Z"))
        item.earlier = [Wording(body: "first", until: until), Wording(body: "second", until: until.addingTimeInterval(60))]
        let device = EarlierWordings.lines(of: item, lifted: false)
        #expect(device.allSatisfy { $0.until.hasPrefix("Until ") })
        item.earlierFromSource = true
        let lines = EarlierWordings.lines(of: item, lifted: false)
        #expect(lines.first?.until.hasPrefix("As first written, ") == true && lines.last?.until.hasPrefix("Until ") == true)
        #expect(EarlierWordings.spoken(lines[1]) == "\(lines[1].until): second")
    }
}
