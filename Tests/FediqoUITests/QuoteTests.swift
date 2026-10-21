import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #330 through the session (X0 §3): the quote mark live where the source lets the reader, dim
/// with the author's reason or the lock's words where not, none where the host has no quotes; a
/// quote begun in the composer's own draft, carrying no files nor poll; who may quote the post,
/// picked when writing and changed from one's own post's `…`; the quotes of one's own post, each
/// taken back behind a question; a waiting quote said; and a quote sent later carrying its quote.
@MainActor
@Suite("Quoting a post", .watched)
struct QuoteTests {
    init() { L10n.language = .english }

    private static let host = "social.example"

    /// A status of `name`'s, saying what the reader may do with quoting it.
    private static func status(
        _ id: String, by name: String = "ada", reader: String = "automatic", visibility: String = "public", quotes: Int = 0,
        quote: String = "null"
    ) -> String {
        """
        {"id":"\(id)","uri":"https://social.example/users/\(name)/statuses/\(id)","created_at":"2026-10-01T00:00:00.000Z",
         "content":"<p>post \(id)</p>","visibility":"\(visibility)","favourited":false,"quotes_count":\(quotes),
         "account":{"username":"\(name)","acct":"\(name)","display_name":"\(name)"},
         "quote_approval":{"automatic":["public"],"manual":[],"current_user":"\(reader)"},"quote":\(quote)}
        """
    }

    private func note(_ json: String) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: Source(host: Self.host, kind: .mastodon), category: .home, sent: .now())
    }

    private func run(
        _ server: any HTTPSender, holding notes: [Note], scopes: String = MastodonOAuth.scopes(writing: true),
        hosts: ShellHostsKnown? = nil
    ) async throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.host, accessToken: "tok-1", clientID: "c", clientSecret: "s", scopes: scopes))
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        await store.ingest(notes)
        let session = ShellSession(http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server))
        session.said.announce = { _ in }
        session.mastodon.deadlineSleep = TurnedClock().sleep
        session.quoting.hosts = hosts
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        await session.reloadFromStore()
        session.prepareCompose()
        return session
    }

    private func row(_ id: String, in session: ShellSession) throws -> DummyItem {
        try #require(session.notes.first { $0.statusID == id }.flatMap { session.held($0.key.rowID) })
    }

    // MARK: - The mark

    @Test("The quote mark is live where the source lets the reader quote, live and saying so where the author is asked first, and dim with the author's reason where not")
    func theMark() async throws {
        let session = try await run(LaterSource([:]), holding: [
            try note(Self.status("1")), try note(Self.status("2", reader: "manual")), try note(Self.status("3", reader: "denied")),
        ])
        let live = try #require(session.quoteOffer(on: try row("1", in: session)))
        #expect(live.look == .live && live.why == nil && live.press != nil)
        let manual = try #require(session.quoteOffer(on: try row("2", in: session)))
        #expect(manual.look == .live && manual.why == "@ada@social.example is asked first; your post says so until they allow it.")
        let denied = try #require(session.quoteOffer(on: try row("3", in: session)))
        #expect(denied.look == .dim(.notNow) && denied.why == "@ada@social.example does not let you quote this post.")

        var acting = session.acting(on: try row("3", in: session))
        acting.quote = denied
        let mark = try #require(ItemActs.marks(on: try row("3", in: session), acting: acting).first { $0.kind == .quote })
        #expect(mark.mark.look == .dim(.notNow) && mark.label.contains("does not let you quote"))
    }

    @Test("A host whose own account of itself has no quotes draws the mark dim saying so; a sign-in that only reads draws it dim with the lock's words, and its press asks")
    func hostAndLock() async throws {
        let hosts = ShellHostsKnown(errands: PageErrands())
        hosts.notFound(.quotes, at: Self.host, round: hosts.round(at: Self.host))
        let none = try await run(LaterSource([:]), holding: [try note(Self.status("1"))], hosts: hosts)
        #expect(none.quotesOffered(host: Self.host) == false)
        let mark = try #require(none.quoteOffer(on: try row("1", in: none)))
        #expect(mark.look == .dim(.never) && mark.why == "social.example does not take quotes.")

        let reading = try await run(LaterSource([:]), holding: [try note(Self.status("1"))], scopes: MastodonOAuth.scopes(writing: false))
        let locked = try #require(reading.quoteOffer(on: try row("1", in: reading)))
        #expect(locked.look == .dim(.askAgain) && locked.press != nil && locked.why?.isEmpty == false)
    }

    // MARK: - In the composer

    @Test("A quote opens the composer's own draft with the quote in it; with files or a poll in the draft it asks first, and the yes drops them and keeps the words; the quote can go only without them")
    func aQuoteBegun() async throws {
        let session = try await run(LaterSource([:]), holding: [try note(Self.status("1"))])
        let item = try row("1", in: session)
        session.composeDraft.text = "my words"
        session.composeDraft.poll = NewPoll(choices: ["A", "B"])
        session.quoting.start(item, in: session)
        #expect(session.quoting.asking?.poll == true && session.composeDraft.quoting == nil)
        session.quoting.dropAndQuote(item, in: session)
        #expect(session.composeDraft.poll == nil && session.composeDraft.text == "my words")
        #expect(session.composeDraft.quoting?.statusID == "1" && session.quoting.composeRequest == 1)
        #expect(DraftControls.composer(session, limit: 500).quoteBlocks == "A quote cannot carry media or a poll.")
        session.composeDraft.poll = NewPoll(choices: ["A", "B"])
        #expect(!session.canPost)
        session.composeDraft.poll = nil
        #expect(session.canPost)
        session.composeDraft.quoting = nil
        #expect(DraftControls.composer(session, limit: 500).quoteBlocks == nil, "Don't quote it gives the post back plain")
    }

    @Test("A quote is sent with the quoted post by its id and who may quote it as chosen; nothing chosen sends nothing; a post only followers read sends nobody")
    func aQuoteSent() async throws {
        let server = LaterSource(["POST /api/v1/statuses": [(Self.status("9", by: "me"), 200)]])
        let session = try await run(server, holding: [try note(Self.status("1"))])
        session.quoting.start(try row("1", in: session), in: session)
        session.composeDraft.text = "quoting"
        session.composeDraft.quotePolicy = .followers
        #expect(session.send())
        await session.outbox.settled()
        var posts = await server.requests.filter { $0.httpMethod == "POST" }
        #expect(LaterSource.form(posts[0])["quoted_status_id"] == "1" && LaterSource.form(posts[0])["quote_approval_policy"] == "followers")
        #expect(session.composeDraft.quoting == nil, "the next post starts without a quote")

        // Who may quote it stays for the next post, as who may read it does; set back to the
        // account's own, it sends nothing.
        #expect(session.composeDraft.quotePolicy == .followers)
        session.composeDraft.quotePolicy = nil
        session.composeDraft.text = "plain"
        #expect(session.send())
        await session.outbox.settled()
        posts = await server.requests.filter { $0.httpMethod == "POST" }
        #expect(LaterSource.form(posts[1])["quote_approval_policy"] == nil, "the account's own, and nothing sent")

        var draft = PostDraft(quotePolicy: .anyone)
        draft.audience = .followers
        #expect(draft.quotePolicySent == .nobody)
    }

    @Test("A quote sent later carries its quote")
    func aQuoteSentLater() async throws {
        let waiting = #"{"id":"5","scheduled_at":"2099-01-01T00:00:00.000Z","params":{"text":"later","visibility":"public"},"media_attachments":[]}"#
        let server = LaterSource(["POST /api/v1/statuses": [(waiting, 200)]])
        let session = try await run(server, holding: [try note(Self.status("1"))])
        session.quoting.start(try row("1", in: session), in: session)
        session.composeDraft.text = "later"
        session.composeDraft.at = Date().addingTimeInterval(3600)
        #expect(session.send())
        await session.outbox.settled()
        let post = try #require(await server.requests.first { $0.httpMethod == "POST" })
        #expect(LaterSource.form(post)["quoted_status_id"] == "1" && LaterSource.form(post)["scheduled_at"] != nil)
    }

    @Test("A quote whose author is asked first lands and says so")
    func aWaitingQuoteSaysSo() async throws {
        let pending = Self.status("9", by: "me", quote: #"{"state":"pending","quoted_status_id":"1"}"#)
        let session = try await run(LaterSource(["POST /api/v1/statuses": [(pending, 200)]]), holding: [try note(Self.status("2", reader: "manual"))])
        session.quoting.start(try row("2", in: session), in: session)
        session.composeDraft.text = "asked"
        #expect(session.send())
        await session.outbox.settled()
        #expect(session.said.lines.first?.words() == "Your post is up. @ada@social.example is asked whether it may quote theirs.")
    }

    @Test("A quote sent later whose quoted post goes while its source's clock is asked is not sent at all, and its line says why")
    func quotedGoneBeforeTheRequest() async throws {
        let inner = LaterSource(["POST /api/v1/statuses": [(#"{"id":"5","scheduled_at":"2099-01-01T00:00:00.000Z","params":{"text":"later","visibility":"public"},"media_attachments":[]}"#, 200)]])
        let server = HeldClock(inner)
        let session = try await run(server, holding: [try note(Self.status("1"))])
        var spoken: [String] = []
        session.said.announce = { spoken.append($0) }
        let quoted = try #require(session.notes.first { $0.statusID == "1" })
        session.quoting.start(try row("1", in: session), in: session)
        session.composeDraft.text = "later"
        session.composeDraft.at = Date().addingTimeInterval(3600)
        #expect(session.send())
        // Past every hold and `ready()`, waiting on the source's clock: the quoted post goes now.
        await server.reached()
        await session.markGone(quoted.key)
        await server.release()
        await session.outbox.settled()
        #expect(await inner.requests.filter { $0.httpMethod == "POST" }.isEmpty, "no plain post the person never wrote")
        let held = try #require(session.outbox.sendings.first)
        #expect(session.outbox.hold(held, in: session) == .quotedGone)
        #expect(spoken.contains { $0.contains("The post it quotes is gone at social.example") }, "\(spoken)")
    }

    @Test("A quote sent later whose first try is answered 404 is one not allowed, and nothing is looked for; a repeat under its used key answered 404 is looked for among what waits, found, and waits")
    func aLaterQuotesNotFound() async throws {
        let refused = LaterSource([
            "POST /api/v1/statuses": [(#"{"error":"The post you are trying to quote does not appear to exist."}"#, 404)],
        ])
        let first = try await run(refused, holding: [try note(Self.status("1"))])
        first.quoting.start(try row("1", in: first), in: first)
        first.composeDraft.text = "later"
        first.composeDraft.at = Date().addingTimeInterval(3600)
        #expect(first.send())
        await first.outbox.settled()
        #expect(first.outbox.sendings.first?.standing == .failed(.declined), "not allowed")
        let looks = await refused.requests.filter { $0.url?.path == "/api/v1/scheduled_statuses" && $0.url?.query != "limit=1" }
        #expect(looks.isEmpty, "nothing looked for")

        let server = LaterSource([
            "POST /api/v1/statuses": [(#"{"error":"busy"}"#, 500), (#"{"error":"Record not found"}"#, 404)],
            "GET /api/v1/scheduled_statuses": [("[]", 200), (LaterSource.echo, 200)],
        ])
        let session = try await run(server, holding: [try note(Self.status("1"))])
        session.quoting.start(try row("1", in: session), in: session)
        session.composeDraft.text = "later"
        session.composeDraft.at = Date().addingTimeInterval(3600)
        #expect(session.send())
        await session.outbox.settled()
        let id = try #require(session.outbox.sendings.first?.id)
        #expect(session.outbox.sendings.first?.standing == .unconfirmed, "its answer lost")
        #expect(session.outbox.again(id, in: session))
        await session.outbox.settled()
        let posts = await server.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 2 && posts.allSatisfy { LaterSource.form($0)["quoted_status_id"] == "1" })
        let later = session.said.lines.compactMap { line -> Said.Later? in
            if case .later(_, let later) = line.what { return later }
            return nil
        }.first
        guard case .waits? = later else { Issue.record("not found among what waits: \(session.said.lines)"); return }
        #expect(session.outbox.sendings.isEmpty, "found, and no line says it may be written again")
    }

    // MARK: - One's own post

    @Test("One's own post offers who may quote it, the one it is set to ticked, changed at once and sent; a post only followers read is fixed at nobody; its quotes are listed, and one is taken back behind a question")
    func ownPost() async throws {
        let revoked = Self.status("7", quote: #"{"state":"revoked","quoted_status_id":"1"}"#)
        let server = LaterSource([
            "PUT /api/v1/statuses/1/interaction_policy": [(Self.status("1", by: "me", quotes: 1), 200)],
            "GET /api/v1/statuses/1/quotes": [("[\(Self.status("7", quote: #"{"state":"accepted","quoted_status_id":"1"}"#))]", 200)],
            "POST /api/v1/statuses/1/quotes/7/revoke": [(revoked, 200)],
        ])
        let session = try await run(server, holding: [
            try note(Self.status("1", by: "me", quotes: 1)), try note(Self.status("4", by: "me", visibility: "private")),
        ])
        let own = try #require(session.ownQuotesOffer(on: try row("1", in: session)))
        #expect(own.policy == .anyone && !own.fixed && own.count == 1)
        let items = ItemActs.quoteItems(own).items
        #expect(items.map(\.name) == ["Who may quote it: Anyone", "Who may quote it: Your followers", "Who may quote it: Only you", "Quotes of it (1)"])
        own.choose(.followers)
        #expect(session.ownQuotesOffer(on: try row("1", in: session))?.policy == .followers, "shown at once")
        await session.quoting.settled()
        #expect(await server.asked.contains("PUT /api/v1/statuses/1/interaction_policy"))

        let fixed = try #require(session.ownQuotesOffer(on: try row("4", in: session)))
        #expect(fixed.fixed && fixed.policy == .nobody)
        #expect(ItemActs.quoteItems(fixed).items.prefix(2).allSatisfy { $0.look == .dim(.never) })

        own.openQuotes?()
        await session.quoting.settled()
        let quoting = try #require(session.quoting.rows.first)
        #expect(session.quoting.open != nil && !QuoteWords.revoked(quoting))
        #expect(QuoteWords.revokeQuestion(quoting).warns)
        session.quoting.withdrawQuote(quoting, of: try #require(session.quoting.open?.post), in: session)
        await session.quoting.settled()
        #expect(session.quoting.rows.first.map(QuoteWords.revoked) == true)
    }

    @Test("Somebody else's post offers none of who may quote it")
    func notOwn() async throws {
        let session = try await run(LaterSource([:]), holding: [try note(Self.status("1"))])
        #expect(session.ownQuotesOffer(on: try row("1", in: session)) == nil)
    }
}

/// A source whose clock (`GET /api/v1/scheduled_statuses?limit=1`) is held until released: the
/// window between what the outbox asked before the wait and the request after it.
actor HeldClock: HTTPSender {
    private let inner: LaterSource
    private var held: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?
    private var holding = false

    init(_ inner: LaterSource) { self.inner = inner }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if !holding, request.url?.path == "/api/v1/scheduled_statuses", request.url?.query == "limit=1" {
            holding = true
            arrived?.resume()
            arrived = nil
            await withCheckedContinuation { held = $0 }
        }
        return try await inner.send(request)
    }

    /// Returns once the clock is asked and held.
    func reached() async {
        if holding { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
