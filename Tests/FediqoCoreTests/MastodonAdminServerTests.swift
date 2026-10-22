import Foundation
import Testing
@testable import FediqoCore

/// #384, in the half of it Core holds: what waits to rise on a server, let rise or kept back; its
/// figures over a span; its rules — from what a real 4.6.6 answered (`MastodonAdminServerCaptures`).
@Suite("Tending a server: what rises on it, how it is doing, and its rules")
struct MastodonAdminServerTests {
    private typealias Captures = MastodonAdminServerCaptures

    private static let token = MastodonToken(host: Captures.host, accessToken: "tok-384", clientID: "cid", clientSecret: "secret")
    private static let trends = MastodonAdminServer.trendsPath

    private func reader(_ routes: [String: PeopleServer.Answer]) throws -> (MastodonAdminServer, PeopleServer) {
        let server = PeopleServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonAdminServer(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server)
    }

    @Test("What rises is read, each kind as the server lists it, each saying whether it waits for review — a hashtag also whether it may rise — and a post as a post of this source")
    func whatRises() async throws {
        let (reader, _) = try reader([
            "\(Self.trends)/tags?limit=20": .json(Captures.tags),
            "\(Self.trends)/links?limit=20": .json(Captures.links),
            "\(Self.trends)/statuses?limit=20": .json(Captures.posts),
        ])
        let tags = try await reader.rising(.tags)
        #expect(tags.next == nil && tags.items.count == 2)
        let waitingTag = try #require(tags.items.last)
        #expect(waitingTag.waiting && waitingTag.rises == false && waitingTag.id == "23")
        guard case .tag(let tag) = waitingTag.what else { Issue.record("not a hashtag"); return }
        #expect(tag.tag.name == "FediqoWaiting")

        let links = try await reader.rising(.links)
        #expect(links.items.map(\.id) == ["1", "2"] && links.items.map(\.waiting) == [false, true])
        guard case .link(let link) = links.items[1].what else { Issue.record("not a link"); return }
        #expect(link.title == "fediqo384seed a story waiting" && link.link.host == "waiting.example")

        let posts = try await reader.rising(.posts)
        #expect(posts.items.count == 2 && posts.items.allSatisfy(\.waiting))
        guard case .post(let note) = posts.items[1].what else { Issue.record("not a post"); return }
        #expect(note.body.contains("fediqo384seed a post waiting") && note.source.host == Captures.host)
    }

    @Test("A full stretch reads on from where it ended; a short one is the last")
    func readsOn() async throws {
        let one = #"{"id":"%d","name":"Tag%d","requires_review":true,"trendable":false,"history":[]}"#
        let full = "[" + (1...20).map { String(format: one, $0, $0) }.joined(separator: ",") + "]"
        let (reader, server) = try reader([
            "\(Self.trends)/tags?limit=20": .json(full),
            "\(Self.trends)/tags?limit=20&offset=20": .json("[" + String(format: one, 21, 21) + "]"),
        ])
        let first = try await reader.rising(.tags)
        #expect(first.items.count == 20 && first.next == 20)
        let second = try await reader.rising(.tags, from: 20)
        #expect(second.items.map(\.id) == ["21"] && second.next == nil)
        #expect(await server.asked.last == "\(Self.trends)/tags?limit=20&offset=20")
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.rising(.tags, from: -1) }
    }

    @Test("Each is let rise or kept back at its own address, answered with what the server holds after: a hashtag says which way; a link or a post only that it no longer waits, so the way asked stands for it")
    func reviewed() async throws {
        let (reader, server) = try reader([
            "\(Self.trends)/tags/23/reject": .json(Captures.tagRejected),
            "\(Self.trends)/tags/23/approve": .json(Captures.tagApproved),
            "\(Self.trends)/links/2/reject": .json(Captures.linkRejected),
            "\(Self.trends)/statuses/117483578385512583/approve": .json(Captures.postApproved),
        ])
        let kept = try await reader.review(.tags, "23", rise: false)
        #expect(!kept.waiting && kept.rises == false)
        #expect(try await reader.review(.tags, "23", rise: true).rises == true)
        let link = try await reader.review(.links, "2", rise: false)
        #expect(!link.waiting && link.rises == false && link.id == "2")
        let post = try await reader.review(.posts, "117483578385512583", rise: true)
        #expect(!post.waiting && post.rises == true)
        #expect(await server.asked.contains("\(Self.trends)/links/2/reject"))
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.review(.tags, "../1", rise: true) }
    }

    @Test("Without the standing it is not allowed; one the server has not is not found; a body that is none is unreadable")
    func refusals() async throws {
        let (reader, _) = try reader([
            MastodonAdminServer.measuresPath: .json(Captures.writerMeasures, status: 403),
            "\(Self.trends)/tags/9/approve": .json(Captures.noTag, status: 404),
            "\(Self.trends)/links?limit=20": .json("{}"),
        ])
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await reader.measures(days: 7) }
        await #expect(throws: MastodonAuthError.http(404)) { _ = try await reader.review(.tags, "9", rise: true) }
        await #expect(throws: MastodonAdminError.unreadable) { _ = try await reader.rising(.links) }
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.measures(days: 0) }
    }

    @Test("The figures are asked over whole days of the server's calendar, ending the day after the last, and said as of when they were read")
    func figures() async throws {
        let (reader, server) = try reader([MastodonAdminServer.measuresPath: .json(Captures.measures)])
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-22T08:30:00Z"))
        let said = try await reader.measures(days: 7, now: now)
        #expect(said.asOf == now && said.days == 7)
        #expect(said.measures.map(\.key) == [.joined, .active, .reported])
        #expect(said.measures.map(\.total) == [51, 49, 2] && said.measures.first?.before == 0)
        let body = try #require(await server.sent.last?.body)
        #expect(body.contains("start_at=2026-10-16") && body.contains("end_at=2026-10-23"))
        #expect(body.contains("keys%5B%5D=new_users") || body.contains("keys[]=new_users"))
    }

    @Test("The rules are the server's, in its order; changing them is its own page's")
    func rules() async throws {
        let (reader, _) = try reader([MastodonReports.rulesPath: .json(Captures.rules)])
        let rules = try await reader.rules()
        #expect(rules.map(\.text) == ["fediqo381seed rule", "fediqo384seed second rule"] && rules[1].hint == "fediqo384seed hint")
        #expect(MastodonAdminServer.rulesPage(host: "m.example")?.absoluteString == "https://m.example/admin/rules")
    }
}
