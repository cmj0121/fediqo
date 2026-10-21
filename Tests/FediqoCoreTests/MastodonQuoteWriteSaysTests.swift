import Foundation
import Testing
@testable import FediqoCore

/// #330: what Fediqo makes of quoting on a real Mastodon — held against the one this checkout
/// brings up (`make servers`, Mastodon 4.6.6), every line of `MastodonQuoteWriteCaptures` that a
/// run can ask without leaving anything behind, through this app's own code (`MastodonWrite.post`
/// with a quote and a policy, `quotePolicy`, `revoke`; `MastodonQuotes`; `MastodonHostSays`).
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **This writes, and takes back what it wrote**: a few posts of the writer's and of the second
/// person's, each deleted however the check ends.
///
/// **What no run here can ask**: a quote that waits for its author — this server asks nobody
/// first (`manual` is always empty), so waiting is read from its own spelling alone
/// (`MastodonQuoteWriteTests.waitingAndRevoked`).
@Suite("What a Mastodon says when a post quotes another", .enabled(if: LocalServers.requested), .serialized)
struct MastodonQuoteWriteSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)

    private static func door(_ accessToken: String) throws -> MastodonAuthorized {
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: host, accessToken: accessToken, clientID: "x", clientSecret: "x")
        try tokens.save(token)
        return MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens)
    }

    /// The server asked plainly, for what this app's code does not hand on.
    private func ask(_ path: String, as token: String? = nil, _ method: String = "GET") async throws -> (status: Int, body: Data) {
        guard let url = URL(string: "https://\(Self.host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await LocalHTTP.client().send(request)
        return (response.statusCode, body)
    }

    /// One account's writing, and every post it made taken back at the end.
    private final class Writer: @unchecked Sendable {
        let write: MastodonWrite
        let door: MastodonAuthorized
        var made: [String] = []

        init(_ token: String, store: ItemStore) throws {
            door = try MastodonQuoteWriteSaysTests.door(token)
            write = MastodonWrite(door: door, store: store)
        }

        func post(_ words: String, _ visibility: Audience, quoting: Note? = nil, policy: QuotePolicy? = nil) async throws -> Note {
            let note = try await write.post(words, visibility: visibility, quoting: quoting, quotePolicy: policy)
            if let id = note.statusID { made.append(id) }
            return note
        }

        func takeBack() async {
            for id in made.reversed() { _ = try? await door.delete(path: "/api/v1/statuses/\(id)") }
        }
    }

    @Test("A post is quoted with a policy and the quote is accepted; the quoted post says who may quote it, how many have, and the reader's word — denied unsigned; its policy changed to nobody turns the next quote away in the server's words; its quotes read on to their end; one revoked reads as revoked, and again; the host says it has quotes")
    func quoting() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try LocalServers.seeded()
        let store = ItemStore()
        await store.add(Self.source)
        let writer = try Writer(seeded.writer, store: store), other = try Writer(seeded.other, store: store)
        let thrown: (any Error)?
        do {
            let said = try await MastodonClient(http: try LocalHTTP.client(), host: Self.host).said()
            #expect(said.has.apiVersion == 11 && said.has.has(.quotes) == .present)

            let tag = UUID().uuidString.prefix(8)
            let quoted = try await writer.post("fediqo-330 to quote \(tag)", .unlisted, policy: .anyone)
            #expect(quoted.quoteApproval == QuoteApproval(automatic: ["public"]) && quoted.mayQuote == .automatic)
            let first = try await other.post("fediqo-330 quoting \(tag)", .unlisted, quoting: quoted)
            #expect(first.quote?.state == .accepted && first.quotesReference?.statusID == quoted.statusID)
            let mine = try await writer.post("fediqo-330 quoting my own \(tag)", .unlisted, quoting: quoted, policy: .nobody)
            #expect(mine.quote?.state == .accepted && mine.quoteApproval?.policy == .nobody)

            let id = try #require(quoted.statusID)
            let again = try await MastodonPost(door: other.door).post(id: id, source: Self.source)
            #expect(again.counts.quotes == 2 && again.mayQuote == .automatic && again.quoteApproval?.policy == .anyone)
            let unsigned = try await MastodonPost(http: try LocalHTTP.client(), host: Self.host).post(id: id, source: Self.source)
            #expect(unsigned.mayQuote == nil && unsigned.quoteApproval?.policy == .anyone, "the server tells an unsigned reader denied, and that is no reader's word")
            let plain = try await ask("/api/v1/statuses/\(id)")
            let told = (try JSONSerialization.jsonObject(with: plain.body) as? [String: Any])?["quote_approval"] as? [String: Any]
            #expect(told?["current_user"] as? String == "denied")

            // Media or a poll: refused here, before the server is asked (it answers a poll with a 500).
            await #expect(throws: MastodonQuoteError.carries) {
                try await other.write.post("a poll", visibility: .unlisted, poll: NewPoll(choices: ["a", "b"]), quoting: quoted)
            }

            // Its policy changed: nobody but its author.
            let closed = try await writer.write.quotePolicy(of: quoted, to: .nobody)
            #expect(closed.quoteApproval?.policy == .nobody && closed.mayQuote == .automatic)
            #expect(try await MastodonPost(door: other.door).post(id: id, source: Self.source).mayQuote == .denied)
            await #expect(throws: MastodonQuoteError.notAllowed) {
                try await other.post("fediqo-330 turned away \(tag)", .unlisted, quoting: quoted)
            }
            _ = try await writer.write.quotePolicy(of: quoted, to: .anyone)

            // Its quotes, a stretch of one at a time, to the end.
            let quotes = MastodonQuotes(door: writer.door)
            var read = PostsRead()
            repeat {
                read = try read.readingOn(try await quotes.quotes(of: quoted, after: read.next, limit: 1))
            } while !read.ended
            #expect(Set(read.posts.compactMap(\.statusID)) == Set([first.statusID, mine.statusID].compactMap { $0 }) && read.posts.count == 2)
            #expect(try await ask("/api/v1/statuses/\(id)/quotes").status == 401)

            // One revoked, by the quoted post's author alone.
            let firstID = try #require(first.statusID)
            let notTheirs = try await ask("/api/v1/statuses/\(id)/quotes/\(firstID)/revoke", as: seeded.other, "POST")
            #expect(notTheirs.status == 403 && String(decoding: notTheirs.body, as: UTF8.self) == MastodonQuoteWriteCaptures.notTheirs)
            let revoked = try await writer.write.revoke(first, of: quoted)
            #expect(revoked.quote?.state == .revoked && revoked.quote?.post == nil)
            #expect(try await writer.write.revoke(first, of: quoted).quote?.state == .revoked, "taken back again, the same")
            #expect(try await MastodonPost(door: writer.door).post(id: id, source: Self.source).counts.quotes == 1)

            // There is no way to approve a waiting quote: each address a page of the server's own.
            for path in ["quotes/\(firstID)/approve", "quotes/\(firstID)/accept"] {
                let answer = try await ask("/api/v1/statuses/\(id)/\(path)", as: seeded.writer, "POST")
                #expect(answer.status == 404 && MastodonHostNotFound.isOfTheAddress(status: answer.status, body: answer.body), "\(path)")
            }
            thrown = nil
        } catch {
            thrown = error
        }
        await other.takeBack()
        await writer.takeBack()
        if let thrown { throw thrown }
    }

    @Test("A post only its followers may read is quoted by nobody but its author — its policy stays nobody whatever it is set to — and its author's quote of it is made followers-only")
    func aFollowersOnlyPost() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try LocalServers.seeded()
        let store = ItemStore()
        await store.add(Self.source)
        let writer = try Writer(seeded.writer, store: store)
        let thrown: (any Error)?
        do {
            let tag = UUID().uuidString.prefix(8)
            let kept = try await writer.post("fediqo-330 followers only \(tag)", .followers, policy: .anyone)
            #expect(kept.quoteApproval?.policy == .nobody, "nobody, whatever was asked")
            let changed = try await writer.write.quotePolicy(of: kept, to: .anyone)
            #expect(changed.quoteApproval?.policy == .nobody)
            let own = try await writer.post("fediqo-330 quoting it \(tag)", .everyone, quoting: kept)
            #expect(own.quote?.state == .accepted && own.audience == .followers, "asked for anyone, made followers-only")
            thrown = nil
        } catch {
            thrown = error
        }
        await writer.takeBack()
        if let thrown { throw thrown }
    }
}
