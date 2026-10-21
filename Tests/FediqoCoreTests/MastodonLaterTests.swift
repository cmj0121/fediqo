import Foundation
import Testing
@testable import FediqoCore

/// A source that answers each method and path in turn as the test scripted it — a body and a
/// status, or a connection lost — with its own clock in every answer's `Date` header, and keeps
/// every request.
private actor LaterServer: HTTPSender {
    enum Answer: Sendable {
        case json(String, status: Int = 200)
        case lost
    }

    private var script: [String: [Answer]]
    /// How far the source's clock is ahead of this device's.
    private let ahead: TimeInterval
    private(set) var requests: [URLRequest] = []

    init(_ script: [String: [Answer]], ahead: TimeInterval = 0) {
        self.script = script
        self.ahead = ahead
    }

    var asked: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" } }
    var keys: [String?] { requests.map { $0.value(forHTTPHeaderField: MastodonWrite.idempotencyKey) } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: Date().addingTimeInterval(ahead))
        // What waits, asked for its clock: nothing, where the test scripted nothing else.
        guard var answers = script[key], !answers.isEmpty else {
            guard key == "GET /api/v1/scheduled_statuses" else { throw FixtureHTTPError.unmapped }
            return (Data("[]".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Date": date])!)
        }
        let next = answers.removeFirst()
        script[key] = answers
        switch next {
        case .lost:
            throw URLError(.networkConnectionLost)
        case .json(let body, let status):
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Date": date])!)
        }
    }
}

/// A post sent later (#333): given a time judged by its source's clock and held by its source,
/// what waits read on to its end, moved, changed by making the new one first and letting the old
/// go only once the new one is known to wait (Decision 2), and let go — none of it held on this
/// device — each against what Mastodon 4.6.6 answered (`MastodonLaterCaptures`).
@Suite("A post sent later")
struct MastodonLaterTests {
    private typealias Captures = MastodonLaterCaptures
    private let source = Source(host: MastodonFixture.host, kind: .mastodon)
    private static let now = Date(timeIntervalSince1970: 1_792_000_000)
    private static let at = now.addingTimeInterval(3600)
    private static let list = "/api/v1/scheduled_statuses"

    private func writer(_ server: LaterServer) async throws -> (MastodonWrite, ItemStore) {
        let store = ItemStore()
        await store.add(source)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
        return (MastodonWrite(door: door, store: store), store)
    }

    private static func pairs(_ request: URLRequest?) -> [(String, String)] {
        guard let body = request?.httpBody, let text = String(data: body, encoding: .utf8) else { return [] }
        return text.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0].removingPercentEncoding ?? parts[0], (parts.count > 1 ? parts[1].removingPercentEncoding : "") ?? "")
        }
    }

    private static func waiting(_ json: String) throws -> WaitingPost {
        try #require(WaitingDTO.one(from: Data(json.utf8)))
    }

    /// A waiting post as the source answers one, at `at`, saying `text`.
    private static func made(_ id: String, _ text: String, at: Date = at, visibility: String = "public", answering: String = "117476930889022363") -> String {
        """
        {"id":"\(id)","scheduled_at":"\(MastodonLater.written(at))","params":{"text":"\(text)","visibility":"\(visibility)","in_reply_to_id":\(answering)},"media_attachments":[]}
        """
    }

    // MARK: - What waits, read

    @Test("A waiting post reads as the source kept it — words, cover, covered as a string, language, who may read it, its file with its description, a poll of strings, what it answers as a bare number — and the keys it names twice cost nothing")
    func readsAsKept() throws {
        let media = try Self.waiting(Captures.withMedia)
        #expect(media.id == "1" && media.at == MastodonJSON.date(from: "2026-10-21T05:09:20.000Z"))
        #expect(media.text == "later with media" && media.spoiler == "cw" && media.sensitive && media.language == "de")
        #expect(media.audience == .unlisted && media.answering == nil && media.poll == nil)
        #expect(media.media.map(\.id) == ["117476934325177381"] && media.media.map(\.description) == ["alt one"])

        let poll = try Self.waiting(Captures.withPoll)
        #expect(poll.poll == NewPoll(choices: ["A", "B"], multiple: true, runs: 3600, hidesTotals: false))
        #expect(poll.audience == .followers && !poll.sensitive && poll.spoiler == "" && poll.language == nil)

        #expect(try Self.waiting(Captures.answer).answering == "117476930889022363", "every digit of an id too large for a double")
        let huge = try Self.waiting(Self.made("4", "x", answering: "123456789012345678901234567890"))
        #expect(huge.answering == "123456789012345678901234567890", "an id past every integer type, kept as its digits")
    }

    @Test("A waiting quote reads what it quotes and who may quote it from the last of the keys its source names twice — the id as a string, the policy as its word — in either order; a post that quotes nothing quotes nothing")
    func aWaitingQuote() async throws {
        let quote = try Self.waiting(Captures.quote)
        #expect(quote.quoting == "117477716262721165" && quote.quotePolicy == .followers, "the last: a string id, every digit, and the word")
        #expect(try Self.waiting(Captures.quoteNobody).quotePolicy == .nobody)
        #expect(try Self.waiting(Captures.withMedia).quoting == nil && Self.waiting(Captures.withMedia).quotePolicy == .anyone)
        let server = LaterServer(["GET \(Self.list)": [.json(Captures.quoteListed)]])
        let (write, _) = try await writer(server)
        let listed = try await write.waiting()
        #expect(listed.posts.map(\.quoting) == ["117477716262721165"] && listed.posts.map(\.quotePolicy) == [.followers], "listed, in the list's own order")

        // The reader keeps every key named twice, and reads nothing from what is not JSON.
        var reader = LastSaid(Array(#"{"a":1,"b":"x\"\u00e9\ud83d\ude00","a":null,"c":[true,{}]}"#.utf8))
        let value = reader.value()
        let read = try #require(value)
        #expect(read.last("a") == .scalar(nil) && read.last("b")?.text == "x\"é😀")
        var broken = LastSaid(Array(#"{"a":1,"#.utf8))
        let none = broken.value()
        #expect(none == nil)
        #expect(WaitingDTO.quotes(in: Data("not json".utf8)).isEmpty)
    }

    @Test("A waiting quote changed stays a quote: the new one quotes the same post by its id, with who may quote it as sent, and the old is let go after")
    func aQuoteChanged() async throws {
        let old = try Self.waiting(Captures.quote)
        let server = LaterServer([
            "POST /api/v1/statuses": [
                .json(Captures.quote.replacingOccurrences(of: #""id":"148""#, with: #""id":"151""#)), .json(Captures.quote), .json(Captures.quote),
                .json(Captures.quote),
            ],
            "DELETE /api/v1/scheduled_statuses/148": [.json("{}"), .json("{}"), .json("{}"), .json("{}")],
        ])
        let (write, _) = try await writer(server)
        let changed = try await write.change(old, to: "changed", visibility: .everyone, at: Self.at, sourceNow: Self.now, quotePolicy: old.quotePolicy)
        #expect(changed.new?.quoting == "117477716262721165" && changed.new?.quotePolicy == .followers && !changed.oldStays)
        let sent = Self.pairs(await server.requests.first)
        #expect(sent.contains { $0 == ("quoted_status_id", "117477716262721165") } && sent.contains { $0 == ("quote_approval_policy", "followers") })

        // Who may quote it as chosen; nothing inside it, the account's own and nothing sent.
        _ = try await write.change(old, to: "changed", visibility: .everyone, at: Self.at, sourceNow: Self.now, quotePolicy: .anyone)
        var chosen = Self.pairs(await server.requests.filter { $0.httpMethod == "POST" }.last)
        #expect(chosen.contains { $0 == ("quote_approval_policy", "public") })
        _ = try await write.change(old, to: "changed", visibility: .everyone, at: Self.at, sourceNow: Self.now, quotePolicy: nil)
        chosen = Self.pairs(await server.requests.filter { $0.httpMethod == "POST" }.last)
        #expect(!chosen.contains { $0.0 == "quote_approval_policy" } && chosen.contains { $0 == ("quoted_status_id", "117477716262721165") })

        // A quote carries no file nor poll; an id that is no source's is not sent.
        let bare = LaterServer([:])
        let (none, _) = try await writer(bare)
        await #expect(throws: MastodonQuoteError.carries) {
            _ = try await none.change(old, to: "x", visibility: .everyone, at: Self.at, mediaIDs: ["m1"], sourceNow: Self.now)
        }
        await #expect(throws: MastodonQuoteError.unfindable) {
            _ = try await none.postLater("x", visibility: .everyone, at: Self.at, sourceNow: Self.now, quoting: "../1")
        }
        #expect(await bare.asked.allSatisfy { !$0.hasPrefix("POST") }, "nothing sent")
    }

    @Test("What waits is read on by the id cursor, and an entry that cannot be read costs no other")
    func readOn() async throws {
        let server = LaterServer([
            "GET \(Self.list)": [.json("[\(Captures.answer),{\"id\":\"9\"},\(Captures.withPoll)]"), .json("[\(Captures.withMedia)]")],
        ])
        let (write, store) = try await writer(server)
        let first = try await write.waiting()
        #expect(first.posts.map(\.id) == ["3", "2"] && first.next == nil)
        let onward = try await write.waiting(after: "2")
        #expect(onward.posts.map(\.id) == ["1"])
        #expect(await server.requests.map { $0.url?.query } == ["limit=40", "limit=40&max_id=2"])
        #expect(await store.all().isEmpty, "nothing waiting is held here")
        await #expect(throws: MastodonWriteError.unfindable) { _ = try await write.waiting(after: "../x") }
    }

    // MARK: - Given a time, by the source's clock

    @Test("A post given a time is sent with it, in whole seconds, under its key, and comes back waiting — not held here")
    func postLater() async throws {
        let server = LaterServer(["POST /api/v1/statuses": [.json(Captures.withPoll)]])
        let (write, store) = try await writer(server)
        let key = UUID()
        let waiting = try await write.postLater(
            "later with poll", visibility: .followers, at: Self.at, key: key,
            poll: NewPoll(choices: ["A", "B"], multiple: true, runs: 3600), sourceNow: Self.now
        )
        #expect(waiting.id == "2")
        let request = try #require(await server.requests.first)
        #expect(request.value(forHTTPHeaderField: MastodonWrite.idempotencyKey) == key.uuidString)
        #expect(Self.pairs(request).last.map { "\($0.0)=\($0.1)" } == "scheduled_at=2026-10-14T18:46:40Z")
        #expect(await store.all().isEmpty)
    }

    @Test("A device ten minutes behind its source: a time eight minutes ahead by the device is two by the source, and is refused here, with the first the source would take — nothing is sent")
    func judgedByTheSourcesClock() async throws {
        let server = LaterServer([:], ahead: 600)
        let (write, _) = try await writer(server)
        let sourceNow = try await write.sourceNow()
        #expect(abs(sourceNow.timeIntervalSinceNow - 600) < 3, "the source's clock, from its Date")
        do {
            _ = try await write.postLater("x", visibility: .everyone, at: Date().addingTimeInterval(480))
            Issue.record("not refused")
        } catch MastodonLaterError.tooSoon(let earliest) {
            #expect(earliest.timeIntervalSinceNow > 600 + MastodonLater.least)
        }
        #expect(await server.asked.allSatisfy { $0 == "GET \(Self.list)" }, "only its clock was asked")
        #expect(MastodonLater.sendable(Date().addingTimeInterval(480), now: sourceNow).moved)
    }

    @Test("Where the source published the post at once all the same, it is said as a failure — sent now, not later — and held as any written post is")
    func sentNowIsAFailure() async throws {
        let status = #"{"id":"77","uri":"https://social.example/users/me/statuses/77","created_at":"2026-10-21T04:09:21.246Z","content":"<p>past</p>","visibility":"public","account":{"username":"me","acct":"me","display_name":"Me"}}"#
        let (write, store) = try await writer(LaterServer(["POST /api/v1/statuses": [.json(status)]]))
        do {
            _ = try await write.postLater("past", visibility: .everyone, at: Self.at, sourceNow: Self.now)
            Issue.record("taken for waiting")
        } catch MastodonLaterError.sentNow(let note) {
            #expect(note.statusID == "77")
        }
        #expect(await store.all().map(\.statusID) == ["77"])
    }

    @Test("A time the source finds too near or a day full is its own words; the same post again under a used key is one that may have been made")
    func theSourcesRefusals() async throws {
        let (write, _) = try await writer(LaterServer([
            "POST /api/v1/statuses": [.json(Captures.dayFull, status: 422), .json(Captures.notFound, status: 404)],
        ]))
        await #expect(throws: MastodonUnprocessable(body: Data(Captures.dayFull.utf8))) {
            _ = try await write.postLater("x", visibility: .everyone, at: Self.at, sourceNow: Self.now)
        }
        await #expect(throws: MastodonLaterError.mayHaveBeenMade) {
            _ = try await write.postLater("x", visibility: .everyone, at: Self.at, key: UUID(), sourceNow: Self.now)
        }
        #expect(MastodonLater.earliest(now: Self.now) == Date(timeIntervalSince1970: 1_792_000_380), "six minutes on, up to the minute")
        #expect(MastodonLater.sendable(Self.at, now: Self.now) == (Self.at, false))
    }

    // MARK: - Moved, let go

    @Test("A waiting post is moved by its time alone, and comes back at the time the source says; one gone is gone as asked when let go")
    func movedAndLetGo() async throws {
        let old = try Self.waiting(Captures.withMedia)
        let server = LaterServer([
            "PUT /api/v1/scheduled_statuses/1": [.json(Captures.withMedia)],
            "DELETE /api/v1/scheduled_statuses/1": [.json(Captures.notFound, status: 404)],
        ])
        let (write, _) = try await writer(server)
        _ = try await write.move(old, to: Self.at.addingTimeInterval(3600), sourceNow: Self.now)
        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "PUT" && Self.pairs(request).map(\.0) == ["scheduled_at"])
        await #expect(throws: MastodonLaterError.tooSoon(earliest: MastodonLater.earliest(now: Self.now))) {
            _ = try await write.move(old, to: Self.now, sourceNow: Self.now)
        }
        try await write.withdraw(old)
    }

    // MARK: - Changed: the new one first

    @Test("A change makes the new one first, keeping what it answers, and lets the old go after")
    func aChange() async throws {
        let old = try Self.waiting(Self.made("3", "before"))
        let server = LaterServer([
            "POST /api/v1/statuses": [.json(Self.made("5", "after"))],
            "DELETE /api/v1/scheduled_statuses/3": [.json("{}")],
        ])
        let (write, _) = try await writer(server)
        let changed = try await write.change(old, to: "after", visibility: .everyone, at: Self.at, sourceNow: Self.now)
        #expect(changed.new?.id == "5" && !changed.oldStays)
        #expect(await server.asked == ["POST /api/v1/statuses", "DELETE /api/v1/scheduled_statuses/3"])
        let sent = await server.requests.first
        #expect(Self.pairs(sent).contains { $0 == ("in_reply_to_id", "117476930889022363") }, "what it answers stays")
    }

    @Test("The new one's answer lost: asked again under the same key, answered no such record, looked for among what waits — found, the old is let go")
    func lostThenFound() async throws {
        let old = try Self.waiting(Self.made("3", "before"))
        let server = LaterServer([
            "POST /api/v1/statuses": [.lost, .json(Captures.notFound, status: 404)],
            "GET \(Self.list)": [.json("[\(Self.made("5", "after")),\(Self.made("3", "before"))]")],
            "DELETE /api/v1/scheduled_statuses/3": [.json("{}")],
        ])
        let (write, _) = try await writer(server)
        let changed = try await write.change(old, to: "after", visibility: .everyone, at: Self.at, sourceNow: Self.now)
        #expect(changed.new?.id == "5" && !changed.oldStays)
        #expect(await server.asked == [
            "POST /api/v1/statuses", "POST /api/v1/statuses", "GET \(Self.list)", "DELETE /api/v1/scheduled_statuses/3",
        ])
        let keys = await server.keys
        #expect(keys[0] != nil && keys[0] == keys[1], "asked again under the same key, never a fresh one")
    }

    @Test("The new one's answer lost and it is not found among what waits: nothing is let go, and the pair is said — the new one may wait")
    func lostAndNotFound() async throws {
        let old = try Self.waiting(Self.made("3", "before"))
        let server = LaterServer([
            "POST /api/v1/statuses": [.lost, .lost],
            "GET \(Self.list)": [.json("[\(Self.made("3", "before"))]")],
        ])
        let (write, _) = try await writer(server)
        let changed = try await write.change(old, to: "after", visibility: .everyone, at: Self.at, sourceNow: Self.now)
        #expect(changed.new == nil && changed.oldStays)
        #expect(await server.asked.allSatisfy { !$0.hasPrefix("DELETE") })
    }

    @Test("A near twin among what waits — the same words and time, another cover, poll or file — is not the new one, and the old is not let go")
    func aNearTwinIsNotIt() async throws {
        let old = try Self.waiting(Self.made("3", "before"))
        let twin = """
        {"id":"6","scheduled_at":"\(MastodonLater.written(Self.at))","params":{"text":"after","visibility":"public","in_reply_to_id":117476930889022363,"spoiler_text":"another cover"},"media_attachments":[]}
        """
        let server = LaterServer([
            "POST /api/v1/statuses": [.lost, .lost],
            "GET \(Self.list)": [.json("[\(twin)]")],
        ])
        let (write, _) = try await writer(server)
        let changed = try await write.change(old, to: "after", visibility: .everyone, at: Self.at, sourceNow: Self.now)
        #expect(changed.new == nil && changed.oldStays)
        #expect(await server.asked.allSatisfy { !$0.hasPrefix("DELETE") })
    }

    @Test("The old one still waiting after the new took its files is said to have lost them; one whose files the new did not take has not")
    func theOldLosesItsFiles() async throws {
        let old = try Self.waiting(Captures.withMedia)
        let stuck = LaterServer([
            "POST /api/v1/statuses": [.json(Self.made("5", "after")), .json(Self.made("6", "after"))],
            "DELETE /api/v1/scheduled_statuses/1": [.lost, .lost],
        ])
        let (write, _) = try await writer(stuck)
        let took = try await write.change(
            old, to: "after", visibility: .everyone, at: Self.at, mediaIDs: ["117476934325177381"], sourceNow: Self.now
        )
        #expect(took.oldStays && took.oldLostMedia)
        let kept = try await write.change(old, to: "after", visibility: .everyone, at: Self.at, sourceNow: Self.now)
        #expect(kept.oldStays && !kept.oldLostMedia)
    }

    @Test("Where the old one cannot be let go both wait, and that is said; where the new one is refused, the old one is not touched")
    func stuckOrRefused() async throws {
        let old = try Self.waiting(Self.made("3", "before"))
        let stuck = LaterServer([
            "POST /api/v1/statuses": [.json(Self.made("5", "after"))],
            "DELETE /api/v1/scheduled_statuses/3": [.lost],
        ])
        let (write, _) = try await writer(stuck)
        let pair = try await write.change(old, to: "after", visibility: .everyone, at: Self.at, sourceNow: Self.now)
        #expect(pair.new?.id == "5" && pair.oldStays)

        let refused = LaterServer(["POST /api/v1/statuses": [.json(Captures.dayFull, status: 422)]])
        let (refusing, _) = try await writer(refused)
        await #expect(throws: MastodonUnprocessable.self) {
            _ = try await refusing.change(old, to: "after", visibility: .everyone, at: Self.at, sourceNow: Self.now)
        }
        #expect(await refused.asked == ["POST /api/v1/statuses"])
    }
}
