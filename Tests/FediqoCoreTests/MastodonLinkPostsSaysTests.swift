import Foundation
import Testing
@testable import FediqoCore

/// #379: what Fediqo believes a Mastodon says of the posts that share a link rising on it, held
/// against the real one this checkout brings up (`make servers`, Mastodon 4.6.6) — read through
/// this app's own reader, `MastodonLinkPosts`, of the link its own reader of what is rising
/// gives (`MastodonRising`).
///
/// **Passed over where the servers are not up**: the same trait, and `requireHealthy()` is the
/// first line of every check.
///
/// **Everything read here is seeded** (`servers/mastodon/seed.rb` makes one link rise, and the
/// three posts that reached it from somebody of another server who chose to be found carry it,
/// in public). Nothing here writes or switches anything.
///
/// **Asked gently.** A run makes some ten requests and no registration.
@Suite("What a Mastodon says of the posts sharing a rising link", .enabled(if: LocalServers.requested), .serialized)
struct MastodonLinkPostsSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)

    private static func seeded() throws -> LocalServers.Seeded.People {
        try #require(
            try LocalServers.seeded().people,
            "servers/.run/mastodon-tokens.json was seeded before people were: run `make servers` again"
        )
    }

    private static func signedIn() throws -> MastodonLinkPosts {
        let token = MastodonToken(host: host, accessToken: try LocalServers.writerToken(), clientID: "x", clientSecret: "x")
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        return MastodonLinkPosts(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
    }

    /// The link the server says is rising, as this app's reader of what is rising gives it.
    private static func rising() async throws -> PostLink {
        try #require(try await MastodonRising(http: try LocalHTTP.client(), host: host).links().first).link
    }

    @Test("The rising link's posts are the seeded ones, newest first, to anyone and to the writer alike, each a post of this source; read on by the source's own next, a stretch that brings nothing and names no next is the end")
    func theSeededPosts() async throws {
        try await LocalServers.requireHealthy()
        let seeded = try Self.seeded()
        let link = try await Self.rising()
        let reader = MastodonLinkPosts(http: try LocalHTTP.client(), host: Self.host)
        let first = try await reader.posts(sharing: link, source: Self.source)
        #expect(first.posts.map(\.statusID) == seeded.farPosts.reversed())
        #expect(first.posts.allSatisfy { $0.source == Self.source && $0.handle == "@\(seeded.far.acct)" && $0.categories.isEmpty })
        #expect(first.posts.map(\.postedAt) == first.posts.map(\.postedAt).sorted(by: >), "newest first")
        #expect(first.next == seeded.farPosts.first, "a short stretch names a next all the same")

        var read = try PostsRead().readingOn(first)
        while let next = read.next {
            read = try read.readingOn(try await reader.posts(sharing: link, source: Self.source, after: next))
        }
        #expect(read.ended && read.posts.map(\.statusID) == seeded.farPosts.reversed())

        let theirs = try await Self.signedIn().posts(sharing: link, source: Self.source)
        #expect(theirs.posts.map(\.statusID) == first.posts.map(\.statusID))
    }

    @Test("A link not rising there is not listed — to anyone and to the writer — and the server's own document says it has the address, by the version of its API it names")
    func whatItDoesNotList() async throws {
        try await LocalServers.requireHealthy()
        let other = try #require(PostLink("https://elsewhere.example/stories/not-rising"))
        let reader = MastodonLinkPosts(http: try LocalHTTP.client(), host: Self.host)
        await #expect(throws: LinkPostsError.notListed) { try await reader.posts(sharing: other, source: Self.source) }
        await #expect(throws: LinkPostsError.notListed) { try await Self.signedIn().posts(sharing: other, source: Self.source) }

        let said = try await MastodonClient(http: try LocalHTTP.client(), host: Self.host).said()
        #expect(said.has.has(.linkPosts) == .present)
    }
}
