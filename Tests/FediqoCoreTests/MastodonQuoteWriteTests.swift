import Foundation
import Testing
@testable import FediqoCore

/// #330 in Core: who may quote a post, and the reader's word on it, read off a status; a post
/// written quoting another with a chosen policy, refused before sending where it carries media or
/// a poll; the policy of one's own post changed; the quotes of it read on to their end; one
/// revoked; and the host that has none of it — each as a real Mastodon answers
/// (`MastodonQuoteWriteCaptures`, asked of 4.6.6).
@Suite("A quote written, who may quote a post, and the quotes of one's own")
struct MastodonQuoteWriteTests {
    private static let host = MastodonFixture.host
    private static let source = Source(host: host, kind: .mastodon)

    static func status(
        id: String = "9", approval: String? = #"{"automatic":["public"],"manual":[],"current_user":"automatic"}"#,
        quotes: String? = "0", quote: String? = nil, account: String = "me", signed: Bool = true
    ) -> String {
        let qa = approval.map { #","quote_approval":\#($0)"# } ?? ""
        let qc = quotes.map { #","quotes_count":\#($0)"# } ?? ""
        let q = quote.map { #","quote":\#($0)"# } ?? ""
        // A read made as the reader says what they did; an unsigned one says nothing of it.
        let reader = signed ? #","favourited":false"# : ""
        return """
        {"id":"\(id)","uri":"https://social.example/users/\(account)/statuses/\(id)","created_at":"2024-06-01T00:00:00.000Z",
         "content":"<p>words \(id)</p>","visibility":"public"\(qa)\(qc)\(q)\(reader),
         "account":{"username":"\(account)","acct":"\(account)","display_name":"Somebody"}}
        """
    }

    private static func held(_ json: String, sent: ReadMoment = .now()) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8)).asNote(source: source, category: .home, sent: sent)
    }

    private static func door(_ routes: [String: FeatureServer.Answer]) throws -> (MastodonAuthorized, FeatureServer) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let server = FeatureServer(routes)
        return (MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens), server)
    }

    private static func writing(holding notes: [Note], _ routes: [String: FeatureServer.Answer]) async throws -> (MastodonWrite, ItemStore, FeatureServer) {
        let store = ItemStore()
        await store.add(source)
        await store.ingest(notes)
        let (door, server) = try door(routes)
        return (MastodonWrite(door: door, store: store), store, server)
    }

    // MARK: - What a status says

    @Test("Who may quote a post and how many do are read off it: the policy its lists say; the reader's word only from a read made as them — unknown and any word this build does not know read as denied — and never from an unsigned one, which is told denied of every post; nothing where the status says nothing; a figure below none is none")
    func readOffAStatus() throws {
        let anyone = try Self.held(Self.status(quotes: "3"))
        #expect(anyone.quoteApproval?.policy == .anyone && anyone.mayQuote == .automatic && anyone.saysReader)
        #expect(anyone.counts.quotes == 3)
        let followers = try Self.held(Self.status(approval: #"{"automatic":["followers"],"manual":[],"current_user":"denied"}"#))
        #expect(followers.quoteApproval?.policy == .followers && followers.mayQuote == .denied)
        #expect(try Self.held(Self.status(approval: #"{"automatic":[],"manual":[],"current_user":"automatic"}"#)).quoteApproval?.policy == .nobody)
        let asked = try Self.held(Self.status(approval: #"{"automatic":[],"manual":["public"],"current_user":"manual"}"#))
        #expect(asked.quoteApproval?.policy == .anyone && asked.mayQuote == .manual)
        for odd in [#"{"current_user":"unknown"}"#, #"{"current_user":"maybe"}"#, #"{"automatic":"public","current_user":7}"#] {
            #expect(try Self.held(Self.status(approval: odd)).mayQuote == .denied, "\(odd)")
        }
        let unsigned = try Self.held(Self.status(approval: #"{"automatic":["public"],"manual":[],"current_user":"denied"}"#, signed: false))
        #expect(unsigned.quoteApproval?.policy == .anyone && unsigned.mayQuote == nil, "the post's lists, and nothing of a reader nobody was")
        let silent = try Self.held(Self.status(approval: nil, quotes: nil))
        #expect(silent.quoteApproval == nil && silent.mayQuote == nil && silent.counts.quotes == nil)
        #expect(try Self.held(Self.status(quotes: "-1")).counts.quotes == nil)
        #expect(try Self.held(Self.status(approval: #""no""#)).body == "words 9", "a word of another shape costs it, never the post")
    }

    @Test("A quote that waits for its author reads as waiting, one taken back as revoked")
    func waitingAndRevoked() throws {
        let waiting = try Self.held(Self.status(quote: #"{"state":"pending","quoted_status":null}"#))
        #expect(waiting.quote?.state == .pending)
        let taken = try Self.held(Self.status(quote: MastodonQuoteWriteCaptures.revoked))
        #expect(taken.quote?.state == .revoked && taken.quote?.post == nil)
    }

    @Test("A later copy's word on who may quote wins, as its counts do; a read that says nothing leaves it; an unsigned read never takes the reader's word away; a sign-in that ends takes it, and leaves who may quote")
    func keptAsCounts() async throws {
        let held = try Self.held(Self.status())
        let later = try Self.held(Self.status(approval: #"{"automatic":[],"manual":[],"current_user":"automatic"}"#, quotes: "2"))
        #expect(later.refreshed(over: held).quoteApproval?.policy == .nobody && later.refreshed(over: held).counts.quotes == 2)
        #expect(try Self.held(Self.status(approval: nil, quotes: nil)).refreshed(over: held).quoteApproval == held.quoteApproval)
        #expect(held.filled(from: later).quoteApproval?.policy == .nobody)
        let unsigned = try Self.held(Self.status(approval: #"{"automatic":["public"],"manual":[],"current_user":"denied"}"#, signed: false))
        #expect(unsigned.refreshed(over: held).mayQuote == .automatic && held.filled(from: unsigned).mayQuote == .automatic)
        #expect(held.withoutReaderMarks().mayQuote == nil && held.withoutReaderMarks().quoteApproval == held.quoteApproval)

        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest([held])
        #expect(await store.forgetReaderMarks(host: Self.host))
        let after = await store.note(held.key)
        #expect(after?.mayQuote == nil && after?.quoteApproval == held.quoteApproval)
    }

    @Test("A read sent before the reader changed who may quote their post, and one sent before they revoked a quote of it, land after their answers and put neither back")
    func aReadOnItsWay() async throws {
        let early = ReadMoment.now()
        let own = try Self.held(Self.status(id: "7"))
        let quoting = try Self.held(Self.status(id: "20", quote: #"{"state":"accepted","quoted_status":\#(Self.status(id: "7"))}"#, account: "bob"))
        let (write, store, _) = try await Self.writing(holding: [own, quoting], [
            "PUT /api/v1/statuses/7/interaction_policy": .init(body: Self.status(id: "7", approval: #"{"automatic":[],"manual":[],"current_user":"automatic"}"#)),
            "POST /api/v1/statuses/7/quotes/20/revoke": .init(body: Self.status(id: "20", quote: MastodonQuoteWriteCaptures.revoked, account: "bob")),
        ])
        _ = try await write.quotePolicy(of: own, to: .nobody)
        _ = try await write.withdrawQuote(quoting, of: own)
        // Both were read before either act, and land now.
        let staleOwn = try Self.held(Self.status(id: "7"), sent: early)
        let staleQuoting = try Self.held(Self.status(id: "20", quote: #"{"state":"accepted","quoted_status":\#(Self.status(id: "7"))}"#, account: "bob"), sent: early)
        await store.refresh([staleOwn, staleQuoting], ifSourceHere: Self.host)
        #expect(await store.note(own.key)?.quoteApproval?.policy == .nobody)
        #expect(await store.note(quoting.key)?.quote?.state == .revoked)
        // A read sent after them is their word, as any read is.
        await store.refresh([try Self.held(Self.status(id: "7"))], ifSourceHere: Self.host)
        #expect(await store.note(own.key)?.quoteApproval?.policy == .anyone)
    }

    // MARK: - Writing a quote

    @Test("A post is sent quoting another by its own id with the policy chosen; with media or a poll it is refused before anything is sent; a post of another source cannot be quoted from here; a quote the source does not allow says so")
    func writingAQuote() async throws {
        let quoted = try Self.held(Self.status(id: "7", account: "ada"))
        let answer = Self.status(id: "10", quote: #"{"state":"accepted","quoted_status":\#(Self.status(id: "7", account: "ada"))}"#)
        let (write, _, server) = try await Self.writing(holding: [quoted], ["POST /api/v1/statuses": .init(body: answer)])
        let made = try await write.post("see this", visibility: .everyone, quoting: quoted, quotePolicy: .followers)
        #expect(made.quote?.state == .accepted && made.quotesReference?.statusID == "7")
        let form = await server.form()
        #expect(form.contains("quoted_status_id=7") && form.contains("quote_approval_policy=followers"))

        let (bare, _, bareServer) = try await Self.writing(holding: [quoted], ["POST /api/v1/statuses": .init(body: Self.status(id: "11"))])
        _ = try await bare.post("no quote", visibility: .everyone)
        let plain = await bareServer.form()
        #expect(!plain.contains("quoted_status_id") && !plain.contains("quote_approval_policy"), "no quote and no policy where none was chosen")

        await #expect(throws: MastodonQuoteError.carries) {
            try await write.post("a picture", visibility: .everyone, mediaIDs: ["m1"], quoting: quoted)
        }
        await #expect(throws: MastodonQuoteError.carries) {
            try await write.post("a poll", visibility: .everyone, poll: NewPoll(choices: ["a", "b"]), quoting: quoted)
        }
        let elsewhere = Note(id: "x", source: Source(host: "other.example", kind: .mastodon), author: "B", handle: "@b@other.example",
                             body: "b", postedAt: Date(), categories: [], statusID: "3")
        await #expect(throws: MastodonQuoteError.unfindable) { try await write.post("there", visibility: .everyone, quoting: elsewhere) }
        #expect(await server.asked == ["POST /api/v1/statuses"], "nothing more was sent")

        let (refused, _, _) = try await Self.writing(holding: [quoted], [
            "POST /api/v1/statuses": .init(body: MastodonQuoteWriteCaptures.notAllowed, status: 404),
        ])
        await #expect(throws: MastodonQuoteError.notAllowed) { try await refused.post("no", visibility: .everyone, quoting: quoted) }
        await #expect(throws: MastodonQuoteError.notAllowed, "a first try's 404 under a key is not allowed") {
            try await refused.post("no", visibility: .everyone, key: UUID(), quoting: quoted)
        }
        // A repeat under a used key: its 404 says nothing of the first, which may have landed.
        await #expect(throws: MastodonAuthError.http(404)) {
            try await refused.post("no", visibility: .everyone, key: UUID(), quoting: quoted, again: true)
        }
        // Sent later: a first try's 404 is the quote not allowed; a repeat's, under its used key,
        // is one that may already wait there.
        let clock = Date(timeIntervalSince1970: 1_792_000_000)
        let at = clock.addingTimeInterval(3600)
        await #expect(throws: MastodonQuoteError.notAllowed) {
            _ = try await refused.postLater("no", visibility: .everyone, at: at, key: UUID(), sourceNow: clock, quoting: try refused.quotedID(of: quoted))
        }
        await #expect(throws: MastodonLaterError.mayHaveBeenMade) {
            _ = try await refused.postLater("no", visibility: .everyone, at: at, key: UUID(), sourceNow: clock, quoting: try refused.quotedID(of: quoted), again: true)
        }
    }

    @Test("Who may quote one's own post is changed by its policy and lands on its row; quotes of it are read on by the source's next to the end, none twice; one revoked reads as revoked")
    func policyQuotesAndRevoke() async throws {
        let own = try Self.held(Self.status(id: "7"))
        let quoting = try Self.held(Self.status(id: "20", quote: #"{"state":"accepted","quoted_status":\#(Self.status(id: "7"))}"#, account: "bob"))
        let path = "/api/v1/statuses/7/quotes"
        let (write, store, server) = try await Self.writing(holding: [own, quoting], [
            "PUT /api/v1/statuses/7/interaction_policy": .init(body: Self.status(id: "7", approval: #"{"automatic":[],"manual":[],"current_user":"automatic"}"#)),
            "POST /api/v1/statuses/7/quotes/20/revoke": .init(body: Self.status(id: "20", quote: MastodonQuoteWriteCaptures.revoked, account: "bob")),
            "GET \(path)?limit=1": .init(body: "[\(Self.status(id: "20", account: "bob"))]", link: #"<https://\#(Self.host)\#(path)?limit=1&max_id=55>; rel="next""#),
            "GET \(path)?limit=1&max_id=55": .init(body: "[\(Self.status(id: "20", account: "bob")),\(Self.status(id: "21", account: "cy"))]"),
        ])
        let changed = try await write.quotePolicy(of: own, to: .nobody)
        #expect(changed.quoteApproval?.policy == .nobody)
        #expect(await store.note(own.key)?.quoteApproval?.policy == .nobody)
        #expect(await server.form(at: 0) == "quote_approval_policy=nobody")

        let (door, _) = try Self.door([
            "GET \(path)?limit=1": .init(body: "[\(Self.status(id: "20", account: "bob"))]", link: #"<https://\#(Self.host)\#(path)?limit=1&max_id=55>; rel="next""#),
            "GET \(path)?limit=1&max_id=55": .init(body: "[\(Self.status(id: "20", account: "bob")),\(Self.status(id: "21", account: "cy"))]"),
        ])
        let quotes = MastodonQuotes(door: door)
        let first = try await quotes.quotes(of: own, limit: 1)
        #expect(first.next == "55", "the quote's own id, not the post's")
        var read = try PostsRead().readingOn(first)
        read = try read.readingOn(try await quotes.quotes(of: own, after: read.next, limit: 1))
        #expect(read.posts.map(\.statusID) == ["20", "21"] && read.ended)

        let revoked = try await write.withdrawQuote(quoting, of: own)
        #expect(revoked.quote?.state == .revoked)
        #expect(await store.note(quoting.key)?.quote?.state == .revoked)
    }

    @Test("A policy changed and a quote revoked go only through the source they belong to: a post of another source cannot be named here, and a source gone asks nothing")
    func onlyItsOwnSource() async throws {
        let elsewhere = Source(host: "other.example", kind: .mastodon)
        func foreign(_ id: String) -> Note {
            Note(id: "https://other.example/\(id)", source: elsewhere, author: "B", handle: "@b@other.example",
                 body: "b", postedAt: Date(), categories: [], statusID: id)
        }
        let own = try Self.held(Self.status(id: "7"))
        let quoting = try Self.held(Self.status(id: "20", account: "bob"))
        let (write, store, server) = try await Self.writing(holding: [own, quoting], [:])
        await #expect(throws: MastodonQuoteError.unfindable) { try await write.quotePolicy(of: foreign("7"), to: .nobody) }
        await #expect(throws: MastodonQuoteError.unfindable) { try await write.withdrawQuote(foreign("20"), of: own) }
        await #expect(throws: MastodonQuoteError.unfindable) { try await write.withdrawQuote(quoting, of: foreign("7")) }
        await store.remove(host: Self.host)
        await #expect(throws: MastodonWriteError.noSource) { try await write.quotePolicy(of: own, to: .nobody) }
        await #expect(throws: MastodonWriteError.noSource) { try await write.withdrawQuote(quoting, of: own) }
        #expect(await server.asked.isEmpty)
    }

    @Test("A list of who may quote is kept as the wire's is wherever it comes from: no empty word, none past a word's length, no more than are kept")
    func oneFilter() {
        let long = String(repeating: "x", count: 33)
        #expect(QuoteApproval.kept(["public", "", long, "followers"]) == ["public", "followers"])
        #expect(QuoteApproval.kept((1...20).map { "w\($0)" }).count == 8)
    }

    // MARK: - The host

    @Test("A host says whether it has quotes by its own word for its API: 7 or more has them, less has none, none said or another shape says nothing")
    func theHostSays() {
        func says(_ api: String) -> MastodonHostSays { MastodonHostSays(document: Data(#"{"api_versions":\#(api)}"#.utf8)) }
        #expect(says(#"{"mastodon":11}"#).has(.quotes) == .present && says(#"{"mastodon":11}"#).apiVersion == 11)
        #expect(says(#"{"mastodon":7}"#).has(.quotes) == .present)
        #expect(says(#"{"mastodon":6}"#).has(.quotes) == .absent)
        for silent in [#"{}"#, #"{"mastodon":"11"}"#, #""11""#, "null"] {
            #expect(says(silent).has(.quotes) == .unsaid, "\(silent)")
        }
        #expect(MastodonHostSays(document: Data(MastodonHostCaptures.document.utf8)).has(.quotes) == .present)
    }
}
