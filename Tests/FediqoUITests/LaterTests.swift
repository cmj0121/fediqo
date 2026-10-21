import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A source that answers by method and path in turn, with its clock in every answer's `Date`
/// header, and keeps every request.
actor LaterSource: HTTPSender {
    private var script: [String: [(body: String, status: Int)]]
    private let ahead: TimeInterval
    private(set) var requests: [URLRequest] = []

    init(_ script: [String: [(body: String, status: Int)]], ahead: TimeInterval = 0) {
        self.script = script
        self.ahead = ahead
    }

    var asked: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" } }

    /// A scripted body that answers with what the last post given a time was sent as.
    static let echo = "<what was sent>"

    static func form(_ request: URLRequest) -> [String: String] {
        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0].removingPercentEncoding ?? parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return fields
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: Date().addingTimeInterval(ahead))
        func answered(_ body: String, _ status: Int) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Date": date])!)
        }
        if url.path == "/api/v1/accounts/verify_credentials" { return answered(#"{"id":"1","acct":"me"}"#, 200) }
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        // What waits, asked for its clock alone (`limit=1`): nothing, unless scripted.
        if key == "GET /api/v1/scheduled_statuses", url.query == "limit=1" { return answered("[]", 200) }
        guard var answers = script[key], !answers.isEmpty else { throw FixtureHTTPError.unmapped }
        let next = answers.count > 1 ? answers.removeFirst() : answers[0]
        script[key] = answers
        // What waits, as the last post given a time was sent: its words, who may read it, its time.
        if next.body == Self.echo, let made = requests.last(where: { $0.httpMethod == "POST" }) {
            let form = Self.form(made)
            return answered(
                #"[{"id":"40","scheduled_at":"\#(form["scheduled_at"] ?? "")","params":{"text":"\#(form["status"] ?? "")","visibility":"\#(form["visibility"] ?? "")"},"media_attachments":[]}]"#,
                next.status
            )
        }
        return answered(next.body, next.status)
    }
}

/// #333 through the session (X0 §2): the composer takes a time to send, judged on the source's
/// clock; the outbox gives the post to its source to hold and says when it goes, with the way to
/// what waits; the list of what waits reads, moves, changes and lets go; D2's pair is flagged.
@MainActor
@Suite("A post sent later, and what waits", .watched)
struct LaterTests {
    init() { L10n.language = .english }

    private static let host = "social.example"

    private static func waiting(_ id: String, _ text: String, at: Date, media: String = "") -> String {
        """
        {"id":"\(id)","scheduled_at":"\(MastodonLater.written(at))","params":{"text":"\(text)","visibility":"public"},"media_attachments":[\(media)]}
        """
    }

    private func run(_ server: LaterSource, scopes: String = MastodonOAuth.scopes(writing: true)) async throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.host, accessToken: "tok-1", clientID: "c", clientSecret: "s", scopes: scopes))
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        let session = ShellSession(http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server))
        session.said.announce = { _ in }
        session.mastodon.deadlineSleep = TurnedClock().sleep
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        await session.reloadFromStore()
        session.prepareCompose()
        session.composeHost = Self.host
        return session
    }

    private func laterLine(_ session: ShellSession) -> Said.Later? {
        session.said.lines.compactMap { line -> Said.Later? in
            if case .later(_, let later) = line.what { return later }
            return nil
        }.first
    }

    // MARK: - The composer

    @Test("The time to send is offered where the sign-in may write, and dim with the lock's words where it only reads; Post later sends with the time, and the next post starts without one")
    func theTimeToSend() async throws {
        let session = try await run(LaterSource(["POST /api/v1/statuses": [(Self.waiting("1", "later", at: Date().addingTimeInterval(3600)), 200)]]))
        #expect(session.laterSlot(host: Self.host) == DraftControls.LaterSlot())
        let start = LaterWords.start(now: Date(timeIntervalSince1970: 1_792_000_000))
        #expect(start == Date(timeIntervalSince1970: 1_792_003_800), "an hour on, at the next five minutes")

        let reading = try await run(LaterSource([:]), scopes: MastodonOAuth.scopes(writing: false))
        let locked = try #require(reading.laterSlot(host: Self.host)?.locked)
        #expect(!locked.isEmpty)
        reading.composeDraft.at = Date().addingTimeInterval(3600)
        reading.composeDraft.text = "x"
        #expect(!reading.canPost)

        session.composeDraft.text = "later"
        session.composeDraft.at = Date().addingTimeInterval(3600)
        #expect(session.send())
        #expect(session.composeDraft.at == nil && session.composeDraft.text.isEmpty)
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty, "it waits at its source, not here")
        #expect(session.notes.isEmpty, "no item")
        guard case .waits(_, let moved)? = laterLine(session) else { Issue.record("not said to wait"); return }
        #expect(!moved)
    }

    @Test("A time come too near by the source's clock — the device ten minutes behind it — is moved forward to the first the source takes, and said")
    func movedForward() async throws {
        let server = LaterSource(["POST /api/v1/statuses": [(Self.waiting("1", "near", at: Date().addingTimeInterval(1000)), 200)]], ahead: 600)
        let session = try await run(server)
        session.composeDraft.text = "near"
        session.composeDraft.at = Date().addingTimeInterval(480)
        #expect(session.send())
        await session.outbox.settled()
        let post = try #require(await server.requests.first { $0.httpMethod == "POST" })
        let sent = try #require(LaterSource.form(post)["scheduled_at"].flatMap(MastodonJSON.date(from:)))
        #expect(sent.timeIntervalSinceNow > 600 + MastodonLater.least, "after the source's own five minutes")
        guard case .waits(_, let moved)? = laterLine(session) else { Issue.record("not said to wait"); return }
        #expect(moved)
        #expect(session.said.lines.first?.words().contains("moved forward") == true)
    }

    @Test("A post the source sent now instead is said, not hidden, and stands as a post")
    func sentNowIsSaid() async throws {
        let status = #"{"id":"77","uri":"https://social.example/users/me/statuses/77","created_at":"2026-10-21T04:09:21.246Z","content":"<p>now</p>","visibility":"public","account":{"username":"me","acct":"me","display_name":"Me"}}"#
        let session = try await run(LaterSource(["POST /api/v1/statuses": [(status, 200)]]))
        session.composeDraft.text = "now"
        session.composeDraft.at = Date().addingTimeInterval(3600)
        #expect(session.send())
        await session.outbox.settled()
        #expect(laterLine(session) == .sentNow)
        #expect(session.notes.map(\.statusID) == ["77"])
    }

    @Test("A time the source refuses is said in its own words, and the post stays here, every word")
    func refusedInItsWords() async throws {
        let full = #"{"error":"Validation failed: You have exceeded the limit of 25 scheduled posts for today"}"#
        let session = try await run(LaterSource(["POST /api/v1/statuses": [(full, 422)]]))
        session.composeDraft.text = "too many"
        session.composeDraft.at = Date().addingTimeInterval(3600)
        #expect(session.send())
        await session.outbox.settled()
        #expect(laterLine(session) == .refused("Validation failed: You have exceeded the limit of 25 scheduled posts for today"))
        #expect(session.outbox.sendings.map(\.unsent.text) == ["too many"] && session.outbox.sendings.first?.standing == .failed(.declined))
    }

    // MARK: - What waits

    @Test("What waits is read soonest first, moved by its time and let go; a row's `…` asks before it lets one go")
    func theList() async throws {
        let soon = Date().addingTimeInterval(7200)
        let later = Date().addingTimeInterval(9000)
        let server = LaterSource([
            "GET /api/v1/scheduled_statuses": [("[\(Self.waiting("2", "second", at: later)),\(Self.waiting("1", "first", at: soon))]", 200)],
            "PUT /api/v1/scheduled_statuses/2": [(Self.waiting("2", "second", at: later.addingTimeInterval(3600)), 200)],
            "DELETE /api/v1/scheduled_statuses/1": [("{}", 200)],
        ])
        let session = try await run(server)
        session.later.show(host: Self.host, in: session)
        await session.later.settled()
        let said = try #require(session.later.said(in: session))
        #expect(said.rows.map(\.id) == ["1", "2"] && said.line() == nil && said.foot()?.contains("No more") == true)
        #expect(LaterWords.spoken(said.rows[0]).hasPrefix("Goes "))

        session.later.move(said.rows[1], to: later.addingTimeInterval(3600), at: Self.host, in: session)
        #expect(session.later.said(in: session)?.moving == ["2"])
        await session.later.settled()
        #expect(session.later.posts.first { $0.id == "2" }?.at == MastodonJSON.date(from: MastodonLater.written(later.addingTimeInterval(3600))))

        let more = WaitingSheet.more(said.rows[0], host: Self.host, change: { _ in }, move: { _ in }, withdraw: { _ in })
        #expect(more.dangers.count == 1 && more.ordinary.count == 2)
        session.later.withdraw(said.rows[0], at: "elsewhere.example", in: session)
        await session.later.settled()
        #expect(session.later.posts.map(\.id) == ["1", "2"], "a row of another source's list is not let go here")
        session.later.withdraw(said.rows[0], at: Self.host, in: session)
        await session.later.settled()
        #expect(session.later.posts.map(\.id) == ["2"])
    }

    @Test("A time moved forward on the source's clock is the text's from then: its answer lost, the post is looked for at the time sent, found, and waits; Send again after looks first")
    func lookedForAtTheTimeSent() async throws {
        let server = LaterSource([
            "POST /api/v1/statuses": [(#"{"error":"Record not found"}"#, 404)],
            "GET /api/v1/scheduled_statuses": [(LaterSource.echo, 200)],
        ], ahead: 600)
        let session = try await run(server)
        session.composeDraft.text = "near"
        session.composeDraft.at = Date().addingTimeInterval(480)
        #expect(session.send())
        await session.outbox.settled()
        guard case .waits(_, false)? = laterLine(session) else { Issue.record("not found at the time sent: \(session.said.lines)"); return }
        #expect(session.outbox.sendings.isEmpty)
    }

    @Test("A move whose time came too near says it was moved forward; a change the source refuses opens the sheet again on what was typed, saying why")
    func movedOrRefused() async throws {
        let at = Date().addingTimeInterval(7200)
        let full = #"{"error":"Validation failed: You have exceeded the limit of 25 scheduled posts for today"}"#
        let server = LaterSource([
            "GET /api/v1/scheduled_statuses": [("[\(Self.waiting("1", "before", at: at))]", 200)],
            "PUT /api/v1/scheduled_statuses/1": [(Self.waiting("1", "before", at: Date().addingTimeInterval(900)), 200)],
            "POST /api/v1/statuses": [(full, 422)],
        ], ahead: 600)
        let session = try await run(server)
        session.later.show(host: Self.host, in: session)
        await session.later.settled()
        let old = try #require(session.later.posts.first)
        session.later.move(old, to: Date().addingTimeInterval(60), at: Self.host, in: session)
        await session.later.settled()
        #expect(session.later.said(in: session)?.told?.contains("too near") == true)

        session.changes.startWaiting(old, host: Self.host, in: session)
        session.changes.draft.text = "typed and kept"
        #expect(session.changes.save(in: session))
        await session.later.settled()
        #expect(session.changes.waiting != nil && session.changes.draft.text == "typed and kept")
        #expect(session.changes.mediaNote?.contains("25 scheduled posts") == true)
    }

    @Test("A waiting post is changed through the change sheet, its time and who may read it among what changes: the new one first, the old let go after; where the old cannot go both are flagged, the one before said to wait without its files")
    func changedAndPaired() async throws {
        let at = Date().addingTimeInterval(7200)
        let file = #"{"id":"117","type":"image","url":"https://social.example/a.png","preview_url":"https://social.example/a.png","description":"alt"}"#
        let server = LaterSource([
            "GET /api/v1/scheduled_statuses": [("[\(Self.waiting("1", "before", at: at, media: file))]", 200)],
            "POST /api/v1/statuses": [(Self.waiting("2", "after", at: at, media: file), 200)],
            "DELETE /api/v1/scheduled_statuses/1": [("{}", 500)],
        ])
        let session = try await run(server)
        session.later.show(host: Self.host, in: session)
        await session.later.settled()
        let old = try #require(session.later.posts.first)

        session.changes.startWaiting(old, host: Self.host, in: session)
        #expect(session.changes.shown != nil && session.changes.phase == .ready)
        #expect(session.changes.draft.at == old.at && session.changes.draft.media.map(\.remoteID) == ["117"])
        #expect(session.changes.controls(in: session).later?.optional == false, "a waiting post's time is not taken off")
        session.changes.draft.text = "after"
        session.changes.draft.audience = .unlisted
        #expect(session.changes.save(in: session))
        #expect(session.changes.shown == nil)
        await session.later.settled()

        let post = try #require(await server.requests.first { $0.httpMethod == "POST" })
        #expect(LaterSource.form(post)["status"] == "after" && LaterSource.form(post)["visibility"] == "unlisted")
        let pair = try #require(session.later.pairs[Self.host]?.first)
        #expect(pair.old == "1" && pair.lostMedia)
        #expect(LaterWords.pair(pair).contains("without its files"))
    }

    @Test("Your own page at the source has the line to what waits; a sign-in that only reads draws it dim with the lock's words")
    func theWayIn() async throws {
        let session = try await run(LaterSource([:]))
        let me = try #require(DummyPerson(handle: "@me@social.example", host: Self.host))
        if ShellPersonPages.own(at: Self.host, in: session) != nil {
            #expect(session.waitingEntry(of: me)?.locked == nil)
            #expect(session.waitingEntry(of: me)?.words() == "Posts waiting to be sent")
        }
        let someone = try #require(DummyPerson(handle: "@ada@social.example", host: Self.host))
        #expect(session.waitingEntry(of: someone) == nil)
    }
}
