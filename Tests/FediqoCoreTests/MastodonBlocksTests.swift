import Foundation
import Testing
@testable import FediqoCore

/// A server that answers by method and address, and keeps what each request sent: its form too.
actor FormServer: HTTPSender {
    struct Answer: Sendable {
        let body: String
        var link: String?
        var status = 200
        var authenticate: String?
    }

    struct Asked: Equatable, Sendable {
        let method: String
        let address: String
        let form: String
        let bearer: String?
    }

    private let routes: [String: Answer]
    private(set) var asked: [Asked] = []

    init(_ routes: [String: Answer]) {
        self.routes = routes
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        let method = request.httpMethod ?? "GET"
        asked.append(Asked(
            method: method, address: url.absoluteString, form: String(decoding: request.httpBody ?? Data(), as: UTF8.self),
            bearer: request.value(forHTTPHeaderField: "Authorization")
        ))
        guard let answer = routes["\(method) \(url.path)" + (url.query.map { "?\($0)" } ?? "")] else {
            throw FixtureHTTPError.unmapped
        }
        var headers: [String: String] = [:]
        if let link = answer.link { headers["Link"] = link }
        if let authenticate = answer.authenticate { headers["WWW-Authenticate"] = authenticate }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(answer.body.utf8), response)
    }
}

/// #314, in the half of it Core holds: muting and blocking somebody, blocking a whole server, and
/// the three lists read on — read from what a real 4.6.6 answered (`MastodonBlocksCaptures`).
@Suite("Muting and blocking at a Mastodon, and the lists of them read on")
struct MastodonBlocksTests {
    private typealias Captures = MastodonBlocksCaptures

    private static let origin = "https://\(Captures.host)"
    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret"
    )
    private static let source = Source(host: Captures.host, kind: .mastodon)

    private func door(_ routes: [String: FormServer.Answer]) throws -> (MastodonAuthorized, FormServer) {
        let server = FormServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonAuthorized(token: Self.token, sender: server, store: tokens), server)
    }

    @Test("A mute is one post to their own address, as the person, saying whether their notices go too and for how long — none for good; it hands back what the real server said: muted, with its notices and its end where there is one")
    func muting() async throws {
        let (door, server) = try door([
            "POST /api/v1/accounts/\(Captures.first)/mute": .init(body: Captures.mutedForGood),
            "POST /api/v1/accounts/\(Captures.third)/mute": .init(body: Captures.mutedForAnHour),
        ])
        let stands = MastodonStanding(door: door)
        let forGood = try await stands.mute(Captures.first)
        #expect(forGood.muting && forGood.mutedUntil == nil && forGood.mutesNotices == true)
        let forAnHour = try await stands.mute(Captures.third, notices: false, for: 3600)
        #expect(forAnHour.muting && forAnHour.mutesNotices == false && forAnHour.mutedUntil != nil)
        #expect(await server.asked == [
            .init(method: "POST", address: "\(Self.origin)/api/v1/accounts/\(Captures.first)/mute", form: "notifications=true&duration=0", bearer: "Bearer tok-123"),
            .init(method: "POST", address: "\(Self.origin)/api/v1/accounts/\(Captures.third)/mute", form: "notifications=false&duration=3600", bearer: "Bearer tok-123"),
        ])
    }

    @Test("Unmuting, blocking and unblocking are one post each to their own address, with nothing in the form, and hand back the standing the server said: unmuted, blocked, unblocked")
    func unmutingAndBlocking() async throws {
        let (door, server) = try door([
            "POST /api/v1/accounts/\(Captures.first)/unmute": .init(body: Captures.unmuted),
            "POST /api/v1/accounts/\(Captures.third)/block": .init(body: Captures.blocked),
            "POST /api/v1/accounts/\(Captures.third)/unblock": .init(body: Captures.unblocked),
        ])
        let stands = MastodonStanding(door: door)
        let unmuted = try await stands.unmute(Captures.first)
        #expect(!unmuted.muting && unmuted.mutesNotices == nil)
        #expect(try await stands.block(Captures.third).blocking)
        #expect(try await !stands.block(Captures.third, false).blocking)
        #expect(await server.asked.map { "\($0.method) \($0.address) [\($0.form)]" } == [
            "POST \(Self.origin)/api/v1/accounts/\(Captures.first)/unmute []",
            "POST \(Self.origin)/api/v1/accounts/\(Captures.third)/block []",
            "POST \(Self.origin)/api/v1/accounts/\(Captures.third)/unblock []",
        ])
    }

    @Test("An id that is no one segment of a path, and a mute for no time or less, are refused before anything is asked; an answer about somebody else, or no standing, is not one to go by")
    func refusedBeforeAsking() async throws {
        let (door, server) = try door([
            "POST /api/v1/accounts/\(Captures.first)/mute": .init(body: Captures.blocked),
            "POST /api/v1/accounts/\(Captures.third)/block": .init(body: "{}"),
        ])
        let stands = MastodonStanding(door: door)
        for id in ["", "1/follow", "../1"] {
            await #expect(throws: MastodonRequestError.invalidURL) { _ = try await stands.mute(id) }
            await #expect(throws: MastodonRequestError.invalidURL) { _ = try await stands.block(id) }
            await #expect(throws: MastodonRequestError.invalidURL) { _ = try await stands.unmute(id) }
        }
        await #expect(throws: MastodonRequestError.invalidURL) { _ = try await stands.mute(Captures.first, for: 0) }
        #expect(await server.asked.isEmpty)
        await #expect(throws: MastodonStandingError.unreadable) { _ = try await stands.mute(Captures.first) }
        await #expect(throws: MastodonStandingError.unreadable) { _ = try await stands.block(Captures.third) }
    }

    @Test("A sign-in without the word is refused by the server, and that is thrown as the door threw it: nothing is concluded of the sign-in")
    func refusedForWantOfTheWord() async throws {
        let (door, _) = try door([
            "POST /api/v1/accounts/\(Captures.first)/mute": .init(
                body: Captures.muteRefused, status: 403, authenticate: Captures.muteRefusedAuthenticate
            ),
            "GET /api/v1/mutes": .init(body: Captures.mutesRefused, status: 403),
            "GET /api/v1/domain_blocks": .init(body: Captures.serversRefused, status: 403),
        ])
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await MastodonStanding(door: door).mute(Captures.first) }
        await #expect(throws: MastodonAuthError.http(403)) {
            _ = try await MastodonPeople(door: door).stretch(.muted, source: Self.source)
        }
        await #expect(throws: MastodonAuthError.http(403)) { _ = try await MastodonServerBlocks(door: door).stretch() }
    }

    @Test("How the reader stands to somebody of a server they block says so, and is otherwise as it was; a source that leaves it out has blocked no server")
    func aServerBlockedInTheStanding() throws {
        let read = try #require(try MastodonStanding.standing(to: Captures.far, in: Data(Captures.farStanding.utf8)))
        #expect(read.serverBlocked && !read.blocking && !read.muting && !read.following)
        let without = Captures.farStanding.replacingOccurrences(of: #""domain_blocking":true,"#, with: "")
        #expect(try MastodonStanding.standing(to: Captures.far, in: Data(without.utf8))?.serverBlocked == false)
    }

    @Test("Whom the reader mutes is read a stretch at a time, as the person, by the source's own next — which names the mute, never the account — to a stretch with nobody; whom they block, the same, where one stretch is all")
    func theListsOfPeople() async throws {
        let (door, server) = try door([
            "GET /api/v1/mutes?limit=2": .init(body: Captures.mutesFirst, link: Captures.mutesFirstLink),
            "GET /api/v1/mutes?limit=2&max_id=4": .init(body: Captures.mutesNext, link: Captures.mutesNextLink),
            "GET /api/v1/mutes?limit=2&max_id=1": .init(body: "[]"),
            "GET /api/v1/blocks": .init(body: Captures.blocks, link: Captures.blocksLink),
        ])
        let people = MastodonPeople(door: door)
        let first = try await people.stretch(.muted, source: Self.source, limit: 2)
        #expect(first.people.map(\.accountID) == [Captures.third, Captures.first] && first.next == "4")
        let next = try await people.stretch(.muted, source: Self.source, after: "4", limit: 2)
        #expect(next.people.map(\.accountID) == [Captures.second, Captures.seeded] && next.next == "1")
        let last = try await people.stretch(.muted, source: Self.source, after: "1", limit: 2)
        #expect(last.people.isEmpty && last.next == nil)
        let blocked = try await people.stretch(.blocked, source: Self.source)
        #expect(blocked.people.count == 2 && blocked.next == nil && blocked.people.allSatisfy { $0.source == Self.source })
        #expect(await server.asked.allSatisfy { $0.bearer == "Bearer tok-123" && $0.method == "GET" })
    }

    @Test("The servers the reader blocks are read a stretch at a time, as the person, by the source's own next, each a host and each once: an entry that is no host is that one entry not listed, and a body that is no list of names is not read")
    func theServers() async throws {
        let (door, server) = try door([
            "GET /api/v1/domain_blocks?limit=2": .init(body: Captures.serversFirst, link: Captures.serversFirstLink),
            "GET /api/v1/domain_blocks?limit=2&max_id=3": .init(body: Captures.serversNext, link: Captures.serversNextLink),
            // Made up: a name twice, a name in capitals, an address, a number and a handle.
            "GET /api/v1/domain_blocks": .init(body: #"["Spam.Example","spam.example","https://x.example/a",7,"a@b.example"]"#),
            "GET /api/v1/domain_blocks?limit=1": .init(body: #"{"error":"x"}"#),
            "GET /api/v1/domain_blocks?limit=3": .init(body: "[]", link: #"<https://mastodon.localhost/api/v1/domain_blocks?limit=3>; rel="next""#),
        ])
        let servers = MastodonServerBlocks(door: door)
        let first = try await servers.stretch(limit: 2)
        #expect(first == ServersStretch(servers: ["spam.example", "third.example"], next: "3"))
        #expect(try await servers.stretch(after: "3", limit: 2) == ServersStretch(servers: ["elsewhere.example"], next: nil))
        #expect(try await servers.stretch() == ServersStretch(servers: ["spam.example"], next: nil))
        await #expect(throws: MastodonBlocksError.unreadable) { _ = try await servers.stretch(limit: 1) }
        await #expect(throws: MastodonBlocksError.unreadable, "a next that names no place to go on from") {
            _ = try await servers.stretch(limit: 3)
        }
        #expect(await server.asked.first?.address == "\(Self.origin)/api/v1/domain_blocks?limit=2")
    }

    @Test("Blocking a server is one post naming it in the form, and taking it back one delete naming it in the form — as the person, of the one host; a name that is no host is refused before anything is asked, and one the server refuses is thrown as the door threw it")
    func blockingAServer() async throws {
        let (door, server) = try door([
            "POST /api/v1/domain_blocks": .init(body: Captures.serverBlocked),
            "DELETE /api/v1/domain_blocks": .init(body: Captures.serverUnblocked),
        ])
        let servers = MastodonServerBlocks(door: door)
        try await servers.block("Spam.Example")
        try await servers.unblock("spam.example")
        for name in ["", "https://bad.example/x", "a@b.example", "a b.example", "x.example/p"] {
            await #expect(throws: MastodonRequestError.invalidURL, "\(name)") { try await servers.block(name) }
            await #expect(throws: MastodonRequestError.invalidURL, "\(name)") { try await servers.unblock(name) }
        }
        #expect(await server.asked == [
            .init(method: "POST", address: "\(Self.origin)/api/v1/domain_blocks", form: "domain=spam.example", bearer: "Bearer tok-123"),
            .init(method: "DELETE", address: "\(Self.origin)/api/v1/domain_blocks", form: "domain=spam.example", bearer: "Bearer tok-123"),
        ])
        let (refusing, _) = try self.door(["POST /api/v1/domain_blocks": .init(body: Captures.serverInvalid, status: 422)])
        await #expect(throws: MastodonAuthError.http(422)) { try await MastodonServerBlocks(door: refusing).block("odd.example") }
    }

    @Test("Muting and blocking is a part of its own: the four words, standing without acting, asked of no question by itself, in two halves — the one that sees and the one that changes — and every act of it needs it")
    func thePart() {
        let part = MastodonPart.blocks
        #expect(part.words == ["read:mutes", "write:mutes", "read:blocks", "write:blocks"])
        #expect(!part.rider && !part.needsActing && part.wordsBesideActing.isEmpty)
        #expect(MastodonParts.half(of: .blocks, in: "read:mutes read:blocks") == .seeing)
        #expect(MastodonParts.half(of: .blocks, in: "write:mutes write:blocks") == .changing)
        #expect(MastodonParts.half(of: .blocks, in: "read:mutes write:mutes") == nil)
        #expect(MastodonGrant.of(scopes: "read:statuses read:lists read:accounts read:mutes write:mutes read:blocks write:blocks") == .reading)
        for act in PersonAct.allCases where act.isMuteOrBlock { #expect(act.needs == .blocks, "\(act)") }
        #expect(PersonAct.allCases.filter(\.isMuteOrBlock) == [.mute, .unmute, .block, .unblock, .blockServer, .unblockServer])
        #expect(MastodonParts.everything.contains("read:mutes write:mutes read:blocks write:blocks"))
    }
}
