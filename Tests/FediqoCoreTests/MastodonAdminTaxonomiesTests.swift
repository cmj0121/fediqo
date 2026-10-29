import Foundation
import Testing
@testable import FediqoCore

/// #419, in the half of it Core holds: every hashtag a server knows, let rise or kept back, let be
/// used and listed or not; and the sites its links come from, let rise or kept back — from what a
/// real 4.6.6 answered (`MastodonAdminTaxonomiesCaptures`).
@Suite("Tending a server: the hashtags it knows and the sites its links come from")
struct MastodonAdminTaxonomiesTests {
    private typealias Captures = MastodonAdminTaxonomiesCaptures

    private static let token = MastodonToken(host: Captures.host, accessToken: "tok-419", clientID: "cid", clientSecret: "secret")
    private static let tags = MastodonAdminTaxonomies.tagsPath
    private static let sites = MastodonAdminTaxonomies.sitesPath

    private func reader(_ routes: [String: PeopleServer.Answer]) throws -> (MastodonAdminTaxonomies, PeopleServer) {
        let server = PeopleServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonAdminTaxonomies(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server)
    }

    @Test("Every hashtag the server knows is read, newest first, each with its use day by day, whether it may rise, be used and be listed, and whether it waits; a stretch with more after it says where the next begins")
    func theHashtags() async throws {
        let (reader, server) = try reader([
            Self.tags: .json(Captures.tags, link: Captures.tagsLink),
            "\(Self.tags)?max_id=3": .json(Captures.tagsFirst, link: Captures.tagsFirstLink),
            "\(Self.tags)/3": .json(Captures.tag),
        ])
        let all = try await reader.tags()
        #expect(all.items.map(\.tag.tag.name) == ["Fediqo419", "FediqoWaiting", "FediqoRising"] && all.next == nil)
        let waiting = all.items[0], rising = all.items[2]
        #expect(waiting.id == "3" && waiting.waiting && !waiting.rises && waiting.usable && waiting.listable)
        #expect(rising.rises && rising.tag.use != .unsaid)
        let more = try await reader.tags(after: "3")
        #expect(more.items.map(\.id) == ["2"] && more.next == "2")
        #expect(await server.asked.contains("\(Self.tags)?max_id=3"))
        #expect(try await reader.tag("3") == waiting)
    }

    @Test("A hashtag is kept back, unused and unlisted, then let rise, used and listed, at its own address with only what was named: each answered as the server then holds it, no longer waiting")
    func aHashtagChanged() async throws {
        let (back, server) = try reader(["\(Self.tags)/3": .json(Captures.tagKeptBack)])
        let kept = try await back.changeTag("3", rises: false, usable: false, listable: false)
        #expect(!kept.rises && !kept.usable && !kept.listable && !kept.waiting)
        let sent = try #require(await server.sent.last)
        #expect(sent.method == "PUT" && sent.body == "trendable=false&usable=false&listable=false")

        let (rise, risen) = try reader(["\(Self.tags)/3": .json(Captures.tagLetRise)])
        let letRise = try await rise.changeTag("3", rises: true)
        #expect(letRise.rises && letRise.usable && letRise.listable && !letRise.waiting)
        #expect(await risen.sent.last?.body == "trendable=true")
    }

    @Test("Each site the server's links come from is read with whether its links may rise — nothing where nobody has said — and let rise or kept back at its own address, answered as the server then holds it")
    func theSites() async throws {
        let (reader, server) = try reader([
            Self.sites: .json(Captures.sites, link: Captures.sitesLink),
            "\(Self.sites)/1/approve": .json(Captures.siteApproved),
            "\(Self.sites)/1/reject": .json(Captures.siteRejected),
        ])
        let listed = try await reader.sites()
        let site = try #require(listed.items.first)
        #expect(listed.items.count == 1 && listed.next == nil)
        #expect(site.id == "1" && site.domain == "fediqo419.example" && site.rises == nil && site.waiting && site.reviewedAt == nil)
        let approved = try await reader.reviewSite("1", rise: true)
        #expect(approved.rises == true && !approved.waiting && approved.reviewedAt != nil)
        let rejected = try await reader.reviewSite("1", rise: false)
        #expect(rejected.rises == false && !rejected.waiting)
        #expect(await server.asked.suffix(2) == ["\(Self.sites)/1/approve", "\(Self.sites)/1/reject"])
        #expect(await server.sent.last?.method == "POST")
    }

    @Test("Without the standing it is not allowed; one the server has not is not found; a body that is none is unreadable; an id that cannot stand in a path, or a change of nothing, is asked nothing")
    func refusals() async throws {
        let (reader, server) = try reader([
            Self.sites: .json(Captures.writerSites, status: 403),
            "\(Self.sites)/999/reject": .json(Captures.noSite, status: 404),
            "\(Self.tags)/99999": .json(Captures.noTag, status: 404),
            Self.tags: .json("{}"),
        ])
        await #expect(throws: MastodonAdminError.notAllowed) { _ = try await reader.sites() }
        await #expect(throws: MastodonAuthError.http(404)) { _ = try await reader.reviewSite("999", rise: false) }
        await #expect(throws: MastodonAuthError.http(404)) { _ = try await reader.tag("99999") }
        await #expect(throws: MastodonAdminError.unreadable) { _ = try await reader.tags() }
        let before = await server.asked.count
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.changeTag("3") }
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.changeTag("../3", rises: true) }
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.reviewSite("1/x", rise: true) }
        await #expect(throws: MastodonAdminError.invalid) { _ = try await reader.tag("") }
        #expect(await server.asked.count == before)
    }
}
