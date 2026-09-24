import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoPersistence
@testable import FediqoUI

/// #214, on the reader's own post: a quote post held before this build read quotes, read again
/// by `r` in its open thread, and written down.
@MainActor
@Suite("A quote post held from before", .serialized)
struct QuoteHeldBeforeTests {
    private static let host = "g0v.social"
    private static let id = "117322759665402925"

    /// The reader's post on g0v.social (Mastodon 4.7.2), cut to the fields a note is read from.
    /// The whole capture is `MastodonQuoteCaptures.g0v`, in the Core tests.
    private static let status = #"""
    {
     "id": "117322759665402925",
     "uri": "https://g0v.social/users/wancw/statuses/117322759665402925",
     "url": "https://g0v.social/@wancw/117322759665402925",
     "created_at": "2026-09-23T22:40:41.965Z",
     "content": "<p class=\"quote-inline\">RE: <a href=\"https://g0v.social/@wancw/117277361887436248\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">g0v.social/@wancw/117277361887</span><span class=\"invisible\">436248</span></a></p><p>這週上班日四天。請了一天假，剩下三天都是騎腳踏車上班。</p><p>似乎有愈來愈輕鬆？ 🤔</p>",
     "visibility": "public",
     "sensitive": false,
     "spoiler_text": "",
     "account": {"username": "wancw", "acct": "wancw", "display_name": "寫 code 求生的鼯鼠 🦊"},
     "media_attachments": [],
     "emojis": [],
     "quote": {
      "state": "accepted",
      "quoted_status": {
       "id": "117277361887436248",
       "uri": "https://g0v.social/users/wancw/statuses/117277361887436248",
       "url": "https://g0v.social/@wancw/117277361887436248",
       "created_at": "2026-09-15T22:15:26.847Z",
       "content": "<p>騎 YouBike 到公司，跟搭公車的時間差不多。但我大腿快不行了……我已經是騎電動輔助的了。 Orz</p>",
       "visibility": "public",
       "sensitive": false,
       "spoiler_text": "",
       "account": {"username": "wancw", "acct": "wancw", "display_name": "寫 code 求生的鼯鼠 🦊"},
       "media_attachments": [],
       "emojis": [],
       "quote": null
      }
     }
    }
    """#

    /// The row as a build before #214 kept it: read from the home timeline, the `RE:` line in its
    /// words, no quote.
    private static func heldBefore() throws -> Note {
        let json = status.replacingOccurrences(of: #""quote": {"#, with: #""not_a_quote": {"#)
        return try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: Source(host: host, kind: .mastodon), category: .home)
    }

    private func shell(_ old: Note, post: String = status) async -> (ShellSession, ItemStore, FixtureHTTP) {
        let http = FixtureHTTP([
            "/api/v1/statuses/\(Self.id)": .text(post),
            "/api/v1/statuses/\(Self.id)/context": .text(#"{"ancestors":[],"descendants":[]}"#),
        ])
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        await store.ingest([old])
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: HeldBeforeNoSender())
        )
        await session.reloadFromStore()
        return (session, store, http)
    }

    @Test("Opening the thread of a quote post held from before reads the post, and its quote shows")
    func openingReadsTheQuote() async throws {
        let old = try Self.heldBefore()
        let (session, store, http) = await shell(old)
        let row = try #require(session.held(old.key.rowID))

        await session.reload.opened(row, in: session)

        #expect(await http.requested.contains { $0.path == "/api/v1/statuses/\(Self.id)" })
        #expect(await store.note(old.key)?.quote?.state == .accepted)
        #expect(await store.note(old.key)?.body.hasPrefix("RE:") == false)
    }

    @Test("Read again under a keep window, an old quoted post is held, and the quote opens it")
    func oldQuoteUnderTheWindow() async throws {
        let old = try Self.heldBefore()
        let (session, store, _) = await shell(old)
        // A window that keeps the quoting post (23 September) and not the quoted one (15th).
        let now = try #require(MastodonJSON.date(from: "2026-10-20T00:00:00.000Z"))
        await store.setRetention(months: 1, from: now)
        #expect(await store.note(old.key) != nil, "the premise: the quoting post is kept")
        let row = try #require(session.held(old.key.rowID))

        await session.reload.opened(row, in: session)
        await session.reloadFromStore()

        let item = try #require(session.held(old.key.rowID))
        let target = try #require(session.quotedRow(of: item))
        #expect(session.held(target)?.author == "寫 code 求生的鼯鼠 🦊")
        let quotes = ShellQuotes()
        quotes.target = { session.quotedRow(of: $0) }
        #expect(quotes.leads(from: item))
    }

    @Test("A row whose read again still brings no quote is read again once a run, not on every open")
    func readOnceARun() async throws {
        let old = try Self.heldBefore()
        // The server still sends no quote: the row stays one that looks held from before.
        let (session, _, http) = await shell(old, post: Self.status.replacingOccurrences(
            of: #""quote": {"#, with: #""not_a_quote": {"#
        ))
        let row = try #require(session.held(old.key.rowID))
        await session.reload.opened(row, in: session)
        await session.reload.opened(row, in: session)
        let reads = await http.requested.filter { $0.path == "/api/v1/statuses/\(Self.id)" }
        #expect(reads.count == 1, "\(reads.count) reads of the post")
    }

    @Test("Opening any other thread reads its conversation alone, as before")
    func openingAnOrdinaryPostReadsNoMore() async throws {
        let plain = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Self.status.utf8))
            .asNote(source: Source(host: Self.host, kind: .mastodon), category: .home)
        #expect(!ShellReload.heldBeforeQuotes(plain), "a post read with its quote")
        let (session, _, http) = await shell(plain)
        await session.reload.opened(try #require(session.held(plain.key.rowID)), in: session)
        #expect(await http.requested.map(\.path) == ["/api/v1/statuses/\(Self.id)/context"])
    }

    @Test("r in the post's open thread reads the quote in, drops the RE: line, and writes both down")
    func readAgainKeepsTheQuote() async throws {
        let old = try Self.heldBefore()
        #expect(old.quote == nil && old.body.hasPrefix("RE: https://g0v.social/"), "the premise")
        #expect(ShellReload.heldBeforeQuotes(old))
        let (session, store, _) = await shell(old)
        let row = try #require(session.held(old.key.rowID))

        await session.reload.thread(row, in: session)

        let held = try #require(await store.note(old.key))
        #expect(held.quote?.state == .accepted)
        #expect(held.quote?.post?.statusID == "117277361887436248")
        #expect(!held.body.hasPrefix("RE:"))
        #expect(session.held(old.key.rowID)?.quote?.state == .accepted, "the row drawn has it too")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = await store.snapshot()
        try await StoreFile(at: dir).save(sources: snapshot.sources, notes: snapshot.notes)
        let reopened = StoreFile.open(at: dir).notes.first { $0.key == old.key }
        #expect(reopened?.quote?.state == .accepted, "written down, so it shows after a relaunch")
        #expect(reopened?.body.hasPrefix("RE:") == false)
    }
}

/// A signed-in door nobody holds a token for: never reached.
private struct HeldBeforeNoSender: HTTPSender {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw FixtureHTTPError.unmapped
    }
}
