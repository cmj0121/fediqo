import Foundation
import Testing
@testable import FediqoCore

/// A server that answers by method and path, and remembers what it was asked, how, and as whom.
private actor ActServer: HTTPSender {
    enum Answer: Sendable {
        case json(String, status: Int = 200)
        case fail
    }

    private let routes: [String: Answer]
    private(set) var asked: [String] = []
    private(set) var bearers: Set<String> = []
    private(set) var bodies: Set<String> = []

    init(_ routes: [String: Answer]) {
        self.routes = routes
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        let ask = "\(request.httpMethod ?? "") \(url.path)" + (url.query.map { "?\($0)" } ?? "")
        asked.append(ask)
        bearers.insert("\(url.host ?? "") \(request.value(forHTTPHeaderField: "Authorization") ?? "")")
        bodies.insert(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        switch routes[ask] {
        case .json(let body, let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        case .fail:
            throw URLError(.notConnectedToInternet)
        case nil:
            throw FixtureHTTPError.unmapped
        }
    }
}

/// #323, in what Core holds of acting on notices: dismissing one line or all of a source's, and
/// the notices a source holds back — whether there are any, which, letting one through and
/// letting one go. Each request as a real 4.6.6 took it (`MastodonNoticeCaptures`), a refusal
/// that changes nothing, and a source with no held-back notices asked nothing more about them.
@Suite("Dismissing what a source says happened, and what it holds back")
struct MastodonNoticeActsTests {
    private typealias Captures = MastodonNoticeCaptures

    private static let source = Source(host: Captures.host, kind: .mastodon)
    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )
    private static let favourites = "favourite-117402373970258685-497616"
    private static let dismissOne = "POST /api/v1/notifications/11/dismiss"
    private static let dismissLine = "POST /api/v2/notifications/\(favourites)/dismiss"
    private static let clear = "POST " + MastodonNotices.clearPath
    private static let policy = "GET " + MastodonNotices.policyPath
    private static let requests = "GET " + MastodonNotices.requestsPath
    private static let request = "117402380222400467"

    private static let done = ActServer.Answer.json(Captures.done)
    private static let refusal = ActServer.Answer.json(Captures.outsideScope, status: 403)
    private static let missing = ActServer.Answer.json(#"{"error":"Not Found"}"#, status: 404)

    private func acting(
        _ routes: [String: ActServer.Answer]
    ) throws -> (MastodonNotices, ActServer, MemoryMastodonTokens) {
        let server = ActServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        let door = MastodonAuthorized(token: Self.token, sender: server, store: tokens)
        return (MastodonNotices(door: door), server, tokens)
    }

    /// The lines either read brings, as a list somebody holds.
    private func lines(gathered: Bool) async throws -> [Notice] {
        let (notices, _, _) = try acting([
            "GET " + MastodonNotices.gatheredPath: .json(Captures.gathered),
            "GET " + MastodonNotices.singlePath: .json(Captures.single),
        ])
        return try await notices.page(source: Self.source, gathered: gathered).notices
    }

    /// What whoever holds a list does with an act: the line goes once its source has answered,
    /// and not otherwise.
    private func dismissing(_ notice: Notice, from held: [Notice], at notices: MastodonNotices) async -> [Notice] {
        do {
            try await notices.dismiss(notice)
            return held.without(notice)
        } catch {
            return held
        }
    }

    private func one(_ id: String, host: String = Captures.host) -> Notice {
        Notice(
            source: Source(host: host, kind: .mastodon), handle: .one(id: id), kind: .follow, people: [],
            at: Date(timeIntervalSince1970: 0), newestID: id, oldestID: id
        )
    }

    private func line(_ key: String, host: String = Captures.host) -> Notice {
        Notice(
            source: Source(host: host, kind: .mastodon), handle: .gathered(key: key), kind: .favourite, people: [],
            at: Date(timeIntervalSince1970: 0), newestID: "1", oldestID: "1"
        )
    }

    private func held(_ id: String, host: String = Captures.host) -> NoticeRequest {
        NoticeRequest(
            requestID: id, source: Source(host: host, kind: .mastodon), person: NoticePerson(handle: "@ada@mastodon.localhost", name: "Ada"),
            at: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Dismissing

    @Test("A single notice is dismissed by its id: one request, as the signed-in reader, and the line leaves the list")
    func dismissOne() async throws {
        let held = try await lines(gathered: false)
        let newest = try #require(held.first)
        #expect(newest.handle == .one(id: "11"))
        let (notices, server, _) = try acting([Self.dismissOne: Self.done])
        let left = await dismissing(newest, from: held, at: notices)
        #expect(await server.asked == [Self.dismissOne])
        #expect(await server.bearers == ["mastodon.localhost Bearer tok-123"])
        #expect(await server.bodies == [""], "nothing is sent with it but who asks")
        #expect(left == Array(held.dropFirst()) && left.count == 9)
    }

    @Test("A gathered line is dismissed by its key, every notice it stands for at once, and only that line leaves")
    func dismissGathered() async throws {
        let held = try await lines(gathered: true)
        let line = try #require(held.first { $0.handle == .gathered(key: Self.favourites) })
        #expect(line.count == 2)
        let (notices, server, _) = try acting([Self.dismissLine: Self.done])
        let left = await dismissing(line, from: held, at: notices)
        #expect(await server.asked == [Self.dismissLine], "one request for the two of them")
        #expect(left.count == 7 && !left.contains(line))
        #expect(left == held.filter { $0 != line }, "the boosts of the same post stand")
    }

    @Test("A notice the source says is already gone is dismissed, which is what was asked; a gathered line it never had is answered as one it dismissed")
    func alreadyGone() async throws {
        let (notices, server, tokens) = try acting([
            Self.dismissOne: .json(Captures.gone, status: 404),
            "POST /api/v2/notifications/favourite-1-1/dismiss": Self.done,
        ])
        let held = [one("11"), line("favourite-1-1"), one("3")]
        let left = await dismissing(held[0], from: held, at: notices)
        #expect(left == [held[1], held[2]])
        #expect(await dismissing(held[1], from: left, at: notices) == [held[2]])
        #expect(await server.asked == [Self.dismissOne, "POST /api/v2/notifications/favourite-1-1/dismiss"])
        #expect(try tokens.token(host: Captures.host) == Self.token)
    }

    @Test("A dismissal the source refuses, fails or cannot be reached for is an error thrown as it came, asked once, and the list is as it was")
    func refusedDismissal() async throws {
        let held = try await lines(gathered: true) + (try await lines(gathered: false))
        let newest = try #require(held.first { $0.handle == .one(id: "11") })
        let line = try #require(held.first { $0.handle == .gathered(key: Self.favourites) })

        let (refused, asked, tokens) = try acting([Self.dismissOne: Self.refusal, Self.dismissLine: Self.refusal])
        await #expect(throws: MastodonAuthError.http(403)) { try await refused.dismiss(newest) }
        await #expect(throws: MastodonAuthError.http(403)) { try await refused.dismiss(line) }
        #expect(await asked.asked == [Self.dismissOne, Self.dismissLine], "a refusal is not asked again")
        #expect(await dismissing(newest, from: held, at: refused) == held)
        #expect(await dismissing(line, from: held, at: refused) == held)
        #expect(try tokens.token(host: Captures.host) == Self.token, "a 403 signs nobody out")

        let (broken, _, _) = try acting([Self.dismissOne: .json("{}", status: 500), Self.dismissLine: .fail])
        await #expect(throws: MastodonAuthError.http(500)) { try await broken.dismiss(newest) }
        await #expect(throws: URLError.self) { try await broken.dismiss(line) }
        #expect(await dismissing(newest, from: held, at: broken) == held)
        #expect(await dismissing(line, from: held, at: broken) == held)
    }

    @Test("Dismissing all is one request to one source, and takes that source's lines and no other's")
    func dismissAll() async throws {
        let here = try await lines(gathered: true)
        let elsewhere = one("11", host: "other.example")
        let held = [elsewhere] + here
        let (notices, server, _) = try acting([Self.clear: Self.done])
        try await notices.dismissAll()
        #expect(await server.asked == [Self.clear])
        #expect(await server.bearers == ["mastodon.localhost Bearer tok-123"])
        #expect(held.without(all: Self.source) == [elsewhere])
        #expect(held.without(all: elsewhere.source) == here)
    }

    @Test("Dismissing all refused or failed is an error, and not a list emptied: a missing endpoint is not 'already gone'")
    func refusedDismissAll() async throws {
        for (answer, status) in [(Self.refusal, 403), (Self.missing, 404), (.json("{}", status: 500), 500)] {
            let (notices, server, tokens) = try acting([Self.clear: answer])
            await #expect(throws: MastodonAuthError.http(status)) { try await notices.dismissAll() }
            #expect(await server.asked == [Self.clear])
            #expect(try tokens.token(host: Captures.host) == Self.token)
        }
        let (away, _, _) = try acting([Self.clear: .fail])
        await #expect(throws: URLError.self) { try await away.dismissAll() }
    }

    @Test("A name that could not stand in the path as one piece asks nothing; every name a real source gave can")
    func notAName() async throws {
        let (notices, server, _) = try acting([:])
        for id in ["", "9/../clear", "11?x=1", "１１"] {
            await #expect(throws: MastodonRequestError.invalidURL, "\(id)") { try await notices.dismiss(one(id)) }
            await #expect(throws: MastodonRequestError.invalidURL, "\(id)") { try await notices.letThrough(held(id)) }
            await #expect(throws: MastodonRequestError.invalidURL, "\(id)") { try await notices.letGo(held(id)) }
        }
        for key in ["", "..", "../clear", "favourite-1-1/dismiss", ".favourite-1-1", "favourite 1", "favourite-1-1?x"] {
            await #expect(throws: MastodonRequestError.invalidURL, "\(key)") { try await notices.dismiss(line(key)) }
        }
        #expect(await server.asked.isEmpty)
        for key in try await lines(gathered: true).map(\.handle) + [.gathered(key: "admin.sign_up-497616")] {
            guard case .gathered(let key) = key else { continue }
            #expect(MastodonNotices.isGroupKey(key), "\(key)")
        }
    }

    @Test("A gathered line's 404 is not 'already gone' — a line that was never there answers 200 — so it is an error and the line stands; a single notice's 404 is the notice gone")
    func goneOrNoSuchRequest() async throws {
        let (notices, server, _) = try acting([
            Self.dismissOne: .json(Captures.gone, status: 404), Self.dismissLine: Self.missing,
        ])
        let held = [one("11"), line(Self.favourites)]
        await #expect(throws: MastodonAuthError.http(404)) { try await notices.dismiss(held[1]) }
        #expect(await dismissing(held[1], from: held, at: notices) == held)
        #expect(await dismissing(held[0], from: held, at: notices) == [held[1]])
        #expect(await server.asked == [Self.dismissLine, Self.dismissLine, Self.dismissOne])
    }

    @Test("A notice or a held-back request of another source is never asked of this one, where the same number names something else: dismissing, letting through and letting go each send nothing")
    func anotherSources() async throws {
        let (notices, server, _) = try acting([:])
        let other = "other.example"
        await #expect(throws: MastodonNoticeError.elsewhere) { try await notices.dismiss(one("11", host: other)) }
        await #expect(throws: MastodonNoticeError.elsewhere) {
            try await notices.dismiss(line(Self.favourites, host: other))
        }
        await #expect(throws: MastodonNoticeError.elsewhere) {
            try await notices.letThrough(held(Self.request, host: other))
        }
        await #expect(throws: MastodonNoticeError.elsewhere) { try await notices.letGo(held(Self.request, host: other)) }
        #expect(await server.asked.isEmpty)
        // Not named `held`: that is the helper called above, and a local of the same name
        // declared further down this scope takes the name from it on the runner's compiler.
        let both = [one("11", host: other), one("11")]
        #expect(await dismissing(both[0], from: both, at: notices) == both)
        #expect(await server.asked.isEmpty)
    }

    @Test("Two sources' held-back requests under the same name are two requests")
    func requestIdentity() {
        let here = held(Self.request), there = held(Self.request, host: "other.example")
        #expect(here.requestID == there.requestID && here.id != there.id)
        #expect(Set([here, there].map(\.id)).count == 2)
        #expect(here.id == held(Self.request).id)
    }

    // MARK: - What the source holds back

    @Test("Whether a source holds notices back is its policy's summary: how many people's, how many notices — and none is said as none")
    func heldBack() async throws {
        let (holding, server, _) = try acting([Self.policy: .json(Captures.policyHolding)])
        let said = try await holding.held()
        #expect(said == .holds(NoticesHeld(requests: 1, notices: 1)))
        #expect(said.held == NoticesHeld(requests: 1, notices: 1))
        #expect(await server.asked == [Self.policy], "read, and never changed")

        let (fresh, asked, _) = try acting([Self.policy: .json(Captures.policy)])
        let nothing = try await fresh.held()
        #expect(nothing == .holds(NoticesHeld(requests: 0, notices: 0)))
        #expect(nothing.held == nil, "nothing held is nothing to offer")
        // A source that has the policy is asked again: what it holds changes while it runs.
        #expect(try await fresh.held(known: nothing) == nothing)
        #expect(await asked.asked == [Self.policy, Self.policy])

        let counted = #"{"summary":{"pending_requests_count":"2","pending_notifications_count":"many"}}"#
        let (words, _, _) = try acting([Self.policy: .json(counted)])
        #expect(try await words.held() == .holds(NoticesHeld(requests: 2, notices: 0)), "a count in a string is a count")
        #expect(NoticeHolding.unasked.held == nil)
    }

    @Test("A policy whose counts cannot be read at all says nothing of what is held, which is an error and not 'nothing held'")
    func heldBackUncounted() async throws {
        for summary in [
            #"{"pending_requests_count":"many","pending_notifications_count":null}"#, "{}",
            #"{"pending_requests_count":{},"pending_notifications_count":[1]}"#,
        ] {
            let (notices, server, _) = try acting([Self.policy: .json(#"{"summary":\#(summary)}"#)])
            await #expect(throws: MastodonNoticeError.unreadable, "\(summary)") { _ = try await notices.held() }
            #expect(await server.asked == [Self.policy])
        }
    }

    @Test("A source without held-back notices says so once and is asked nothing more about them: not whether, and not which")
    func noHeldBack() async throws {
        let (notices, server, _) = try acting([Self.policy: Self.missing, Self.requests: Self.missing])
        var known = NoticeHolding.unasked
        for _ in 0..<3 {
            known = try await notices.held(known: known)
            #expect(known == .absent && known.held == nil)
            // What whoever draws the page does: the requests are asked for only where some are held.
            if known.held != nil { _ = try await notices.requests(source: Self.source) }
        }
        #expect(await server.asked == [Self.policy], "asked once in three, and its requests never")
    }

    @Test("Only a 404 says a source has no held-back notices: a refusal, a failure or another body is an error, and what was known stands")
    func heldBackUnknown() async throws {
        let known = NoticeHolding.holds(NoticesHeld(requests: 1, notices: 3))
        for (answer, status) in [(Self.refusal, 403), (.json("{}", status: 500), 500)] {
            let (notices, server, tokens) = try acting([Self.policy: answer])
            await #expect(throws: MastodonAuthError.http(status)) { _ = try await notices.held(known: known) }
            #expect(await server.asked == [Self.policy])
            #expect(try tokens.token(host: Captures.host) == Self.token)
        }
        let (away, _, _) = try acting([Self.policy: .fail])
        await #expect(throws: URLError.self) { _ = try await away.held() }
        for body in [Captures.outsideScope, Captures.requests, "{}", "<html>"] {
            let (notices, _, _) = try acting([Self.policy: .json(body)])
            await #expect(throws: MastodonNoticeError.unreadable, "\(body.prefix(12))") { _ = try await notices.held() }
        }
    }

    @Test("A held-back request says whose notices are held, how many, the latest post among them and when — the count read from the string it is sent as")
    func heldRequests() async throws {
        let (notices, server, _) = try acting([Self.requests: .json(Captures.requests)])
        let all = try await notices.requests(source: Self.source)
        #expect(await server.asked == [Self.requests])
        let request = try #require(all.first)
        #expect(all.count == 1 && request.requestID == Self.request && request.source == Self.source)
        #expect(request.id == "mastodon.localhost\u{1e}request\u{1e}\(Self.request)")
        #expect(request.person == NoticePerson(
            handle: "@fediqo_third@mastodon.localhost", name: "fediqo_third",
            avatarURL: URL(string: "https://mastodon.localhost/avatars/original/missing.png")
        ))
        #expect(request.count == 1)
        #expect(request.at == MastodonJSON.date(from: "2026-10-08T00:09:15.260Z"))
        #expect(request.lastPost?.body == "@fediqo a mention that should be held back")
        #expect(request.lastPost?.handle == "@fediqo_third@mastodon.localhost" && request.lastPost?.categories == [])

        let (empty, _, _) = try acting([Self.requests: .json(Captures.noRequests)])
        #expect(try await empty.requests(source: Self.source).isEmpty)
    }

    @Test("A request this build cannot read is that one skipped and never the list; a body that is no list of them is an error")
    func strangeRequests() async throws {
        let ada = #"{"id":"7","username":"ada","acct":"ada","display_name":"Ada"}"#
        let body = """
        [{"id":5,"notifications_count":3,"account":\(ada),"created_at":"2026-10-08T00:00:05.000Z","last_status":{"id":"30"}},
         {"id":"4","notifications_count":"many","account":\(ada),"updated_at":"2026-10-08T00:00:04.000Z","created_at":"2026-10-01T00:00:00.000Z"},
         {"id":"3","account":\(ada)},
         {"id":"2","updated_at":"2026-10-08T00:00:02.000Z"},
         {"account":\(ada),"updated_at":"2026-10-08T00:00:01.000Z"},
         7]
        """
        let (notices, _, _) = try acting([Self.requests: .json(body)])
        let all = try await notices.requests(source: Self.source)
        #expect(all.map(\.requestID) == ["5", "4"], "no moment, nobody or no name is a request nothing can be made of")
        #expect(all.map(\.count) == [3, 1])
        #expect(all.map(\.at) == ["2026-10-08T00:00:05.000Z", "2026-10-08T00:00:04.000Z"].map { MastodonJSON.date(from: $0)! })
        #expect(all.allSatisfy { $0.lastPost == nil && $0.person.name == "Ada" })

        for body in [Captures.policyHolding, Captures.outsideScope, "<html>"] {
            let (other, _, _) = try acting([Self.requests: .json(body)])
            await #expect(throws: MastodonNoticeError.unreadable, "\(body.prefix(12))") {
                _ = try await other.requests(source: Self.source)
            }
        }
        let (refused, _, _) = try acting([Self.requests: Self.refusal])
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await refused.requests(source: Self.source) }
    }

    @Test("Letting a request through and letting one go are one request each, by the request's own name, and nothing waits for the source to move the notices")
    func letThroughAndGo() async throws {
        let accept = "POST /api/v1/notifications/requests/\(Self.request)/accept"
        let dismiss = "POST /api/v1/notifications/requests/\(Self.request)/dismiss"
        let (notices, server, _) = try acting([
            Self.requests: .json(Captures.requests), accept: Self.done, dismiss: Self.done,
        ])
        let request = try #require(try await notices.requests(source: Self.source).first)
        try await notices.letThrough(request)
        #expect(await server.asked == [Self.requests, accept], "the answer is the end of it: nobody is asked whether they have landed")
        try await notices.letGo(request)
        #expect(await server.asked == [Self.requests, accept, dismiss])
        #expect(await server.bearers == ["mastodon.localhost Bearer tok-123"])
        #expect(await server.bodies == [""])
    }

    @Test("A request the source refuses to let through or go, or fails over, is an error asked once, and the sign-in is still held")
    func refusedRequest() async throws {
        let accept = "POST /api/v1/notifications/requests/\(Self.request)/accept"
        let dismiss = "POST /api/v1/notifications/requests/\(Self.request)/dismiss"
        let (notices, server, tokens) = try acting([accept: Self.refusal, dismiss: Self.missing])
        await #expect(throws: MastodonAuthError.http(403)) { try await notices.letThrough(held(Self.request)) }
        await #expect(throws: MastodonAuthError.http(404)) { try await notices.letGo(held(Self.request)) }
        #expect(await server.asked == [accept, dismiss])
        #expect(try tokens.token(host: Captures.host) == Self.token)

        let (away, _, _) = try acting([accept: .fail, dismiss: .json("{}", status: 500)])
        await #expect(throws: URLError.self) { try await away.letThrough(held(Self.request)) }
        await #expect(throws: MastodonAuthError.http(500)) { try await away.letGo(held(Self.request)) }
    }
}
