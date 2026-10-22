import Foundation
import Testing
@testable import FediqoCore

/// #379, in the half of it Core holds: the posts a source says share a link rising on it, read a
/// stretch at a time by the source's own word for what is next. Read from what a real 4.6.6
/// answered (`MastodonLinkPostsCaptures`).
@Suite("The posts that share a rising link, read on")
struct MastodonLinkPostsTests {
    private typealias Captures = MastodonLinkPostsCaptures

    private static let source = Source(host: Captures.host, kind: .mastodon)
    private static let token = MastodonToken(
        host: Captures.host, accessToken: "tok-379", clientID: "cid", clientSecret: "csecret"
    )
    /// The seed's three posts carrying the link, newest first.
    private static let listed = ["117481809727843904", "117481809727127212", "117481809726483045"]

    /// What the reader asks, as the request will spell it: the link, the length, and where it reads on from.
    private static func ask(after next: String? = nil, link: String = Captures.link) throws -> String {
        let query = [URLQueryItem(name: "url", value: link), URLQueryItem(name: "limit", value: "40")]
            + (next.map { [URLQueryItem(name: "max_id", value: $0)] } ?? [])
        let url = try #require(Host.httpsURL(host: Captures.host, path: MastodonLinkPosts.path, query: query))
        return url.path + "?" + (url.query ?? "")
    }

    private static func link(_ text: String = Captures.link) throws -> PostLink {
        try #require(PostLink(text))
    }

    private func unsigned(_ routes: [String: PeopleServer.Answer]) -> (MastodonLinkPosts, PeopleServer) {
        let server = PeopleServer(routes)
        return (MastodonLinkPosts(http: server, host: Captures.host), server)
    }

    private func signedIn(_ routes: [String: PeopleServer.Answer]) throws -> (MastodonLinkPosts, PeopleServer) {
        let server = PeopleServer(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token)
        return (MastodonLinkPosts(door: MastodonAuthorized(token: Self.token, sender: server, store: tokens)), server)
    }

    @Test("The posts a real server listed for the link are read newest first, each a post of that source through no category; asked once, by the link as the source wrote it and for forty, at that host — and signed in, the same posts, with the reader's token beside them")
    func whatARealServerSent() async throws {
        let ask = try Self.ask()
        let (reader, server) = unsigned([ask: .json(Captures.all, link: Captures.allLink)])
        let stretch = try await reader.posts(sharing: try Self.link(), source: Self.source)
        #expect(stretch.posts.map(\.statusID) == Self.listed)
        #expect(stretch.posts.allSatisfy { $0.source == Self.source && $0.categories.isEmpty && $0.handle == "@far@elsewhere.example" })
        #expect(stretch.carried.isEmpty && stretch.next == Self.listed.last, "a short stretch names a next all the same")
        let (asked, hosts, bearers) = (await server.asked, await server.hosts, await server.bearers)
        #expect(asked == [ask] && hosts == [Captures.host] && bearers.isEmpty)
        #expect(ask.contains("url=https://elsewhere.example/stories/rising") && MastodonLinkPosts.stretch == 40)

        let (asReader, signed) = try signedIn([ask: .json(Captures.allSignedIn, link: Captures.allSignedInLink)])
        let theirs = try await asReader.posts(sharing: try Self.link(), source: Self.source)
        #expect(theirs.posts.map(\.statusID) == Self.listed && theirs.next == stretch.next)
        #expect(await signed.bearers == ["Bearer tok-379"])
    }

    @Test("Read on by the source's own next, a stretch at a time, until a stretch names none: every post once, newest first, and the list then ended")
    func readOn() async throws {
        let first = try MastodonLink.next(in: Captures.firstTwoLink)
        let second = try MastodonLink.next(in: Captures.lastOneLink)
        let (reader, server) = unsigned([
            try Self.ask(): .json(Captures.firstTwo, link: Captures.firstTwoLink),
            try Self.ask(after: first): .json(Captures.lastOne, link: Captures.lastOneLink),
            try Self.ask(after: second): .json(Captures.pastTheEnd),
        ])
        var read = try PostsRead().readingOn(try await reader.posts(sharing: try Self.link(), source: Self.source))
        #expect(read.posts.count == 2 && read.next == first && !read.ended)
        while let next = read.next {
            read = try read.readingOn(try await reader.posts(sharing: try Self.link(), source: Self.source, after: next))
        }
        #expect(read.posts.map(\.statusID) == Self.listed && read.ended)
        #expect(await server.asked.count == 3)
    }

    @Test("A link the source lists no posts of — one not rising there, none asked by — is not listed; an address the host does not serve is its having no such address; any refusal, a 422 among them, is the door's, and an answer that is no list, or a next that cannot be read, is unreadable")
    func whatIsNotAnswered() async throws {
        for (body, status) in [(Captures.notRising, 404), (Captures.noAddress, 404)] {
            let (reader, _) = unsigned([try Self.ask(): .json(body, status: status)])
            await #expect(throws: LinkPostsError.notListed) { try await reader.posts(sharing: try Self.link(), source: Self.source) }
            let (asReader, _) = try signedIn([try Self.ask(): .json(body, status: status)])
            await #expect(throws: LinkPostsError.notListed) { try await asReader.posts(sharing: try Self.link(), source: Self.source) }
        }
        for body in ["", MastodonHostCaptures.noSuchAddress, MastodonHostCaptures.noMeansForIt] {
            let (reader, _) = unsigned([try Self.ask(): .json(body, status: 404)])
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await reader.posts(sharing: try Self.link(), source: Self.source) }
            let (asReader, _) = try signedIn([try Self.ask(): .json(body, status: 404)])
            await #expect(throws: MastodonHostMoreError.noSuchAddress) { try await asReader.posts(sharing: try Self.link(), source: Self.source) }
        }
        // A refusal — 422 among them — is the door's: it says nothing of whether the link has posts.
        for status in [403, 422, 429, 500] {
            let refusal = #"{"error":"Validation failed"}"#
            let (reader, _) = unsigned([try Self.ask(): .json(refusal, status: status)])
            await #expect(throws: MastodonRequestError.http(status)) { try await reader.posts(sharing: try Self.link(), source: Self.source) }
            let (asReader, _) = try signedIn([try Self.ask(): .json(refusal, status: status)])
            await #expect(throws: MastodonAuthError.http(status)) { try await asReader.posts(sharing: try Self.link(), source: Self.source) }
        }
        for body in ["", "{}", "null", "<html>"] {
            let (reader, _) = unsigned([try Self.ask(): .json(body)])
            await #expect(throws: LinkPostsError.unreadable) { try await reader.posts(sharing: try Self.link(), source: Self.source) }
        }
        let (noWayOn, _) = unsigned([try Self.ask(): .json("[]", link: #"<https://mastodon.localhost/api/v1/timelines/link>; rel="next""#)])
        await #expect(throws: LinkPostsError.unreadable) { try await noWayOn.posts(sharing: try Self.link(), source: Self.source) }
    }

    @Test("A source naming as next the place just read is not paging; a post it cannot read is that post alone; and a source other than the door's host is asked nothing")
    func guarded() async throws {
        let (same, _) = unsigned([try Self.ask(after: "5"): .json("[]", link: #"<https://mastodon.localhost/api/v1/timelines/link?max_id=5>; rel="next""#)])
        await #expect(throws: PagingError.notPaging) { try await same.posts(sharing: try Self.link(), source: Self.source, after: "5") }

        let posts = try #require(try JSONSerialization.jsonObject(with: Data(Captures.all.utf8)) as? [Any])
        let mixed = String(decoding: try JSONSerialization.data(withJSONObject: [posts[0], ["id": 7], posts[2]]), as: UTF8.self)
        let (reader, _) = unsigned([try Self.ask(): .json(mixed)])
        let read = try await reader.posts(sharing: try Self.link(), source: Self.source)
        #expect(read.posts.map(\.statusID) == [Self.listed[0], Self.listed[2]] && read.next == nil)

        let (elsewhere, server) = unsigned([:])
        await #expect(throws: MastodonRequestError.invalidURL) {
            try await elsewhere.posts(sharing: try Self.link(), source: Source(host: "other.example", kind: .mastodon))
        }
        #expect(await server.asked.isEmpty)
    }

    @Test("Whether a host has the posts of a link is its document's word for its API: any version it names from the one the address came with, and none before; a document that names none says nothing")
    func whoHasIt() {
        #expect(MastodonHostSays(featuredTagLimit: nil, apiVersion: 11).has(.linkPosts) == .present)
        #expect(MastodonHostSays(featuredTagLimit: nil, apiVersion: MastodonHostSays.linkPostsFrom).has(.linkPosts) == .present)
        #expect(MastodonHostSays(featuredTagLimit: nil, apiVersion: 1).has(.linkPosts) == .absent)
        #expect(MastodonHostSays(featuredTagLimit: nil).has(.linkPosts) == .unsaid)
        #expect(MastodonHostSays.linkPostsFrom == 2)
    }
}
