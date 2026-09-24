import Foundation
import Testing
@testable import FediqoCore

/// #214: a post that quotes another, read from what a real Mastodon sent (`MastodonQuoteCaptures`).
@Suite("Mastodon quote posts")
struct MastodonQuoteTests {
    private let source = Source(host: "mastodon.localhost", kind: .mastodon)

    private func note(_ json: String) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: source, category: .public)
    }

    // MARK: - Each state, as a server sent it

    @Test("An accepted quote carries the quoted post whole, and the quoting post's words lose their RE: line")
    func accepted() throws {
        let quoting = try note(MastodonQuoteCaptures.accepted)
        let quote = try #require(quoting.quote)
        #expect(quote.state == .accepted)
        #expect(quote.statusID == "117322969977080442")
        let post = try #require(quote.post)
        #expect(post.id == "https://mastodon.localhost/ap/users/117322968517380917/statuses/117322969977080442")
        #expect(post.statusID == "117322969977080442")
        #expect(post.author == "ada")
        #expect(post.handle == "@ada@mastodon.localhost")
        #expect(post.body == "The first post, by Ada")
        #expect(post.postedAt == MastodonJSON.date(from: "2026-09-23T23:34:11.088Z"))
        #expect(post.url?.absoluteString == "https://mastodon.localhost/@ada/117322969977080442")
        #expect(post.audience == .everyone)
        #expect(post.quoting == nil)
        #expect(quoting.body == "Bob says this is worth reading", "the address of the quote is not drawn twice")
    }

    @Test(
        "A quote that may not be shown keeps its state and nothing of the quoted post",
        arguments: [
            (MastodonQuoteCaptures.pending, Quote.State.pending),
            (MastodonQuoteCaptures.rejected, .rejected),
            (MastodonQuoteCaptures.revoked, .revoked),
            (MastodonQuoteCaptures.deleted, .deleted),
            (MastodonQuoteCaptures.unauthorized, .unauthorized),
            (MastodonQuoteCaptures.mutedAccount, .mutedAccount),
        ]
    )
    func notShown(json: String, state: Quote.State) throws {
        let quote = try #require(try note(json).quote)
        #expect(quote.state == state)
        #expect(quote.post == nil)
        #expect(quote.statusID == nil)
        #expect(!quote.shows)
    }

    @Test("A muted author's post is sent whole, and is still not kept")
    func mutedIsSentAndDropped() throws {
        #expect(MastodonQuoteCaptures.mutedAccount.contains("\"quoted_status\": {"), "the premise: the server sent it")
        let quoting = try note(MastodonQuoteCaptures.mutedAccount)
        #expect(quoting.quote?.post == nil)
        #expect(quoting.quotedNote == nil, "nothing to hold aside")
    }

    @Test("A state this build has not heard of is unknown, and shows nothing")
    func unknownState() throws {
        let json = MastodonQuoteCaptures.accepted
            .replacingOccurrences(of: "\"state\": \"accepted\"", with: "\"state\": \"under_review\"")
        let quote = try #require(try note(json).quote)
        #expect(quote.state == .unknown)
        #expect(quote.post == nil)
    }

    @Test("A quote of a quote keeps one level, and of the next only its state and id")
    func nestedOneLevel() throws {
        let quoting = try note(MastodonQuoteCaptures.nested)
        let post = try #require(quoting.quote?.post)
        #expect(post.author == "bob")
        #expect(post.body == "Bob says this is worth reading")
        #expect(post.quoting == NestedQuote(state: .accepted, statusID: "117322969977080442"))
        // Held aside as a note of its own, its own quote comes along as an id alone.
        let held = try #require(quoting.quotedNote)
        #expect(held.quote == Quote(state: .accepted, statusID: "117322969977080442"))
        #expect(held.quote?.post == nil)
    }

    @Test("A quote a level down from a blocked author says so, with no id to open")
    func nestedBlocked() throws {
        let post = try #require(try note(MastodonQuoteCaptures.blockedAccount).quote?.post)
        #expect(post.quoting == NestedQuote(state: .blockedAccount))
        #expect(post.quoting?.statusID == nil)
    }

    @Test("A covered quoted post keeps its cover, its line and what it carries")
    func coveredQuote() throws {
        let post = try #require(try note(MastodonQuoteCaptures.covered).quote?.post)
        #expect(post.sensitive == true)
        #expect(post.spoiler == "A spoiler")
        #expect(post.covered)
        #expect(post.attachments.count == 1)
        #expect(post.attachments.first?.alt == "A red square")
        #expect(post.attachments.first?.kind == .image)
    }

    @Test("A boost of a quoting post carries the boosted post's quote")
    func boostCarriesTheQuote() throws {
        let boosted = try note(MastodonQuoteCaptures.boost)
        #expect(boosted.boostedBy == "ada")
        #expect(boosted.quote?.post?.body == "The first post, by Ada")
        #expect(boosted.body == "Bob says this is worth reading")
    }

    @Test("A post that only links to another, with no quote, keeps every word")
    func linkOnlyIsUnchanged() throws {
        // The same status as a server with no quotes would send it: the RE: line, and no `quote`.
        let json = MastodonQuoteCaptures.accepted.replacingOccurrences(
            of: #""quote": {"#, with: #""not_a_quote": {"#
        )
        let plain = try note(json)
        #expect(plain.quote == nil)
        #expect(plain.body.hasPrefix("RE: https://mastodon.localhost/@ada/117322969977080442"))
        #expect(plain.body.hasSuffix("Bob says this is worth reading"))
    }

    // MARK: - Held with the quoting post

    @Test("The quoted post is held aside with the quoting one, and All does not grow by it")
    func heldAside() async throws {
        let store = ItemStore()
        await store.add(source)
        let quoting = try note(MastodonQuoteCaptures.accepted)
        await store.ingest([quoting], ifSourceHere: source.host)
        let all = await store.all()
        #expect(all.map(\.key) == [quoting.key], "All is the quoting post alone")
        let key = try #require(quoting.quotedKey)
        let held = try #require(await store.note(key))
        #expect(held.holding == .aside)
        #expect(held.categories.isEmpty)
        #expect(held.body == "The first post, by Ada")
        #expect(await store.aside().map(\.key) == [key])
    }

    @Test("A quoted post a timeline already brought stays in All")
    func heldAsideNeverNarrows() async throws {
        let store = ItemStore()
        await store.add(source)
        let quoting = try note(MastodonQuoteCaptures.accepted)
        let original = try #require(quoting.quotedNote)
        var arrived = original
        arrived.holding = .arrived
        arrived.categories = [.public]
        await store.ingest([arrived])
        await store.ingest([quoting])
        #expect(await store.note(original.key)?.holding == .arrived)
        #expect(await store.all().count == 2)
    }

    @Test("A quote read again holds its quoted post aside too")
    func refreshHoldsTheQuoted() async throws {
        let store = ItemStore()
        await store.add(source)
        let bare = try note(MastodonQuoteCaptures.accepted.replacingOccurrences(
            of: #""quote": {"#, with: #""not_a_quote": {"#
        ))
        await store.ingest([bare])
        let quoting = try note(MastodonQuoteCaptures.accepted)
        #expect(await store.refresh([quoting], ifSourceHere: source.host))
        #expect(await store.note(quoting.key)?.quote?.state == .accepted)
        #expect(await store.note(try #require(quoting.quotedKey))?.holding == .aside)
    }

    @Test("A later copy fills a quote the held one never said, and one that says none leaves it")
    func mergesTheQuote() throws {
        let quoting = try note(MastodonQuoteCaptures.accepted)
        let bare = Note(
            id: quoting.id, source: source, author: quoting.author, handle: quoting.handle,
            body: quoting.body, postedAt: quoting.postedAt, categories: [.public]
        )
        #expect(bare.filled(from: quoting).quote == quoting.quote)
        #expect(quoting.filled(from: bare).quote == quoting.quote, "the held quote stays")
        let revoked = try note(MastodonQuoteCaptures.revoked)
        let taken = Note(
            id: quoting.id, source: source, author: quoting.author, handle: quoting.handle,
            body: quoting.body, postedAt: quoting.postedAt, categories: [], quote: revoked.quote
        )
        #expect(taken.refreshed(over: quoting).quote?.state == .revoked)
        #expect(taken.refreshed(over: quoting).quote?.post == nil, "a quote taken back shows nothing")
        #expect(bare.refreshed(over: quoting).quote == nil, "a Mastodon read with none: the edit took it away")
        let forum = Source(host: source.host, kind: .discourse)
        let never = Note(id: quoting.id, source: forum, author: "", handle: "", body: "", postedAt: quoting.postedAt, categories: [])
        let heldThere = Note(
            id: quoting.id, source: forum, author: "", handle: "", body: "", postedAt: quoting.postedAt,
            categories: [], quote: quoting.quote
        )
        #expect(never.refreshed(over: heldThere).quote == quoting.quote, "a source that never says one leaves it")
    }

    // MARK: - A later copy's quote

    /// The store's row of `key`, after `copies` came in one after the other.
    private func held(after copies: [Note]) async throws -> Note {
        let store = ItemStore()
        await store.add(source)
        for copy in copies { await store.ingest([copy]) }
        return try #require(await store.note(copies[0].key))
    }

    @Test("A quote taken back since: the later copy's state wins, and nothing of the quoted post is kept")
    func acceptedThenRevoked() async throws {
        let accepted = try note(MastodonQuoteCaptures.accepted)
        let revoked = Note(
            id: accepted.id, source: source, author: accepted.author, handle: accepted.handle,
            body: accepted.body, postedAt: accepted.postedAt, categories: [.public],
            quote: Quote(state: .revoked)
        )
        let row = try await held(after: [accepted, revoked])
        #expect(row.quote == Quote(state: .revoked))
        #expect(row.quote?.post == nil)
        #expect(row.quotedKey == nil, "nothing to draw or open")
        for state in [Quote.State.deleted, .blockedAccount, .mutedAccount] {
            let later = Note(
                id: accepted.id, source: source, author: "", handle: "", body: "", postedAt: accepted.postedAt,
                categories: [], quote: Quote(state: state)
            )
            #expect(try await held(after: [accepted, later]).quote?.post == nil, "\(state)")
        }
    }

    @Test("A pending quote becomes accepted when a later copy says so")
    func pendingThenAccepted() async throws {
        let accepted = try note(MastodonQuoteCaptures.accepted)
        let pending = Note(
            id: accepted.id, source: source, author: accepted.author, handle: accepted.handle,
            body: accepted.body, postedAt: accepted.postedAt, categories: [.public],
            quote: Quote(state: .pending)
        )
        let row = try await held(after: [pending, accepted])
        #expect(row.quote == accepted.quote)
        #expect(row.quote?.post != nil)
    }

    @Test("A post held as a quote's id alone takes the quoted post from its own full copy, and keeps it")
    func idOnlyThenFull() async throws {
        // Cyd quotes Bob, who quotes Ada: Bob's post is held aside with Ada's as an id alone.
        let bob = try #require(try note(MastodonQuoteCaptures.nested).quotedNote)
        #expect(bob.quote?.post == nil && bob.quote?.statusID != nil, "the premise")
        let bobFull = try note(MastodonQuoteCaptures.accepted)
        #expect(bob.key == bobFull.key)
        let filled = try await held(after: [bob, bobFull])
        #expect(filled.quote?.post?.body == "The first post, by Ada")
        // And the id alone, arriving again after the full copy, does not take the post away.
        let kept = try await held(after: [bobFull, bob])
        #expect(kept.quote?.post?.body == "The first post, by Ada")
    }

    // MARK: - Kept whatever its age

    @Test("A quoted post older than the keep window is kept while a kept post quotes it")
    func quotedOutlivesTheWindow() async throws {
        let store = ItemStore()
        await store.add(source)
        let quoting = try note(MastodonQuoteCaptures.accepted)
        let key = try #require(quoting.quotedKey)
        // A window that starts between the quoted post and the post quoting it.
        let quotedAt = try #require(quoting.quote?.post?.postedAt)
        let now = quotedAt.addingTimeInterval(40 * 86400)
        await store.setRetention(months: 1, from: now)
        #expect(quotedAt < (KeepPolicy.cutoff(keepingMonths: 1, from: now) ?? .distantPast), "the premise")
        let recent = Note(
            id: quoting.id, source: source, author: quoting.author, handle: quoting.handle, body: quoting.body,
            postedAt: now, categories: [.public], quote: quoting.quote
        )
        await store.ingest([recent])
        #expect(await store.note(key) != nil, "held with the post that quotes it")
        await store.setRetention(months: 1, from: now.addingTimeInterval(86400))
        #expect(await store.note(key) != nil, "and kept by the cut while it is quoted")
        await store.forget(recent.key)
        await store.setRetention(months: 1, from: now.addingTimeInterval(2 * 86400))
        #expect(await store.note(key) == nil, "let go once nothing kept quotes it")
    }

    @Test("A post read again brings in an old quoted post, whatever the keep window says")
    func refreshBringsAnOldQuote() async throws {
        let store = ItemStore()
        await store.add(source)
        let quoting = try note(MastodonQuoteCaptures.accepted)
        let key = try #require(quoting.quotedKey)
        let quotedAt = try #require(quoting.quote?.post?.postedAt)
        let now = quotedAt.addingTimeInterval(40 * 86400)
        await store.setRetention(months: 1, from: now)
        let read = { (quote: Quote?) in
            Note(
                id: quoting.id, source: self.source, author: quoting.author, handle: quoting.handle,
                body: quoting.body, postedAt: now, categories: [.public], quote: quote
            )
        }
        await store.ingest([read(nil)])
        #expect(await store.refresh([read(quoting.quote)], ifSourceHere: source.host))
        #expect(await store.note(key)?.holding == .aside, "held, though older than the window")
    }

    @Test("A quoted post a timeline brought, older than the window, stays while quoted — held aside")
    func arrivedQuotedIsDemotedNotCut() async throws {
        let store = ItemStore()
        await store.add(source)
        let quoting = try note(MastodonQuoteCaptures.accepted)
        var original = try #require(quoting.quotedNote)
        original.holding = .arrived
        original.categories = [.public]
        let quotedAt = original.postedAt
        let now = quotedAt.addingTimeInterval(40 * 86400)
        let recent = Note(
            id: quoting.id, source: source, author: quoting.author, handle: quoting.handle, body: quoting.body,
            postedAt: now, categories: [.public], quote: quoting.quote
        )
        await store.ingest([original, recent])
        #expect(await store.note(original.key)?.holding == .arrived, "the premise")
        await store.setRetention(months: 1, from: now)
        #expect(await store.note(original.key)?.holding == .aside)
        #expect(await store.all().map(\.key) == [recent.key], "out of the timeline's reach")
    }

    @Test("A read again of a post not held brings nothing it quotes in")
    func refreshOfUnheldBringsNothing() async throws {
        let store = ItemStore()
        await store.add(source)
        let quoting = try note(MastodonQuoteCaptures.accepted)
        #expect(await !store.refresh([quoting], ifSourceHere: source.host))
        #expect(await store.note(try #require(quoting.quotedKey)) == nil)
    }

    // MARK: - Read leniently

    @Test("A quote of a shape this build cannot read is no quote, and never costs the page")
    func oddQuoteShape() async throws {
        let odd = MastodonQuoteCaptures.accepted
            .replacingOccurrences(of: #""quote": {"#, with: #""quote": "a string", "was_quote": {"#)
        let http = FixtureHTTP(["/api/v1/timelines/public": .body(Data("[\(odd), \(MastodonQuoteCaptures.pending)]".utf8))])
        let notes = try await MastodonClient(http: http, host: source.host).publicTimeline(source: source)
        #expect(notes.count == 2, "the page read whole")
        #expect(notes[0].quote == nil)
        #expect(notes[0].body.hasPrefix("RE: "), "no quote drawn, so the RE: line stays")
        #expect(notes[1].quote?.state == .pending)
    }

    @Test("A quote that names no state is no quote, and the RE: line stays")
    func quoteWithNoState() throws {
        let stateless = MastodonQuoteCaptures.accepted
            .replacingOccurrences(of: #""state": "accepted","#, with: "")
        let quoting = try note(stateless)
        #expect(quoting.quote == nil)
        #expect(quoting.body.hasPrefix("RE: "))
    }

    // MARK: - The reader's own post (g0v.social, Mastodon 4.7.2)

    private let g0v = Source(host: "g0v.social", kind: .mastodon)

    /// The same status as a build before #214 read it: the `quote` was not a field it knew, so
    /// the note it kept has the `RE:` line in its words and no quote.
    private var heldBefore: String {
        MastodonQuoteCaptures.g0v.replacingOccurrences(of: #""quote": {"#, with: #""not_a_quote": {"#)
    }

    private func page(_ json: String) -> FixtureHTTP {
        FixtureHTTP(["/api/v1/timelines/public": .body(Data("[\(json)]".utf8))])
    }

    @Test("The reader's quote post decodes whole: accepted, the quoted post, and no RE: line")
    func g0vDecodes() throws {
        let note = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(MastodonQuoteCaptures.g0v.utf8))
            .asNote(source: g0v, category: .home)
        let quote = try #require(note.quote)
        #expect(quote.state == .accepted)
        #expect(quote.post?.statusID == "117277361887436248")
        #expect(!note.body.hasPrefix("RE:"))
    }

    @Test("A row held before quotes were read takes the quote, and loses the RE: line, from the next copy a timeline brings")
    func heldBeforeIsFilledByATimeline() async throws {
        let store = ItemStore()
        await store.add(g0v)
        let old = try await MastodonClient(http: page(heldBefore), host: g0v.host).publicTimeline(source: g0v)
        await store.ingest(old, ifSourceHere: g0v.host)
        let key = try #require(old.first?.key)
        #expect(await store.note(key)?.body.hasPrefix("RE: https://g0v.social/") == true, "the premise")
        #expect(await store.note(key)?.quote == nil, "the premise")

        let now = try await MastodonClient(http: page(MastodonQuoteCaptures.g0v), host: g0v.host)
            .publicTimeline(source: g0v)
        await store.ingest(now, ifSourceHere: g0v.host)
        let held = try #require(await store.note(key))
        #expect(held.quote?.state == .accepted)
        #expect(!held.body.hasPrefix("RE:"), "the quote is not drawn twice")
        #expect(await store.note(try #require(held.quotedKey))?.holding == .aside)
    }

    @Test("A row held before quotes were read takes them from a read of the post itself")
    func heldBeforeIsFilledByAReadAgain() throws {
        let old = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(heldBefore.utf8))
            .asNote(source: g0v, categories: [])
        let now = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(MastodonQuoteCaptures.g0v.utf8))
            .asNote(source: g0v, categories: [])
        let refreshed = now.refreshed(over: old)
        #expect(refreshed.quote?.state == .accepted)
        #expect(!refreshed.body.hasPrefix("RE:"))
    }
}
