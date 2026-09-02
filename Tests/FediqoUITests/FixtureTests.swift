import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// The invented world a screenshot is taken of. What is asked here is not that it looks good
/// — a picture is judged by looking at it — but that it is the same world every run, that it
/// holds what the screenshots need, and that nothing in it could reach anybody's machine.
@Suite("A timeline worth photographing")
struct FixtureTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var everyPost: [Post] {
        Fixture.hosts.flatMap { Fixture.timeline(of: $0, now: Self.now) }
    }

    @Test("One variable turns it on, and only that one spelling of it")
    func theVariable() {
        #expect(LaunchOptions.fromEnvironment(["FEDIQO_FIXTURE": "1"]).fixture)
        #expect(LaunchOptions.fromEnvironment(["FEDIQO_FIXTURE": "yes"]).fixture == false)
        #expect(LaunchOptions.fromEnvironment([:]).fixture == false)
    }

    @Test("It is orthogonal to the screen: a fixture can open anywhere")
    func alongsideTheOtherVariables() {
        let options = LaunchOptions.fromEnvironment(["FEDIQO_FIXTURE": "1", "FEDIQO_RAIL": "trending"])
        #expect(options.fixture)
        #expect(options.railItem == .timeline)
        #expect(options.timeline == BaseSource.trend.rawValue)
    }

    @Test("The same world every run: same rows, same order, same words")
    func theSameEveryTime() {
        let once = everyPost
        let again = everyPost
        #expect(once.map(\.mergeKey) == again.map(\.mergeKey))
        #expect(once.map(\.text) == again.map(\.text))
        #expect(once.map(\.createdAt) == again.map(\.createdAt))
    }

    @Test("Every server is one no resolver will ever answer")
    func nothingReachable() {
        for post in everyPost {
            #expect(post.sourceURL.hasSuffix(".example"))
            #expect(post.sources.allSatisfy { $0.hasSuffix(".example") })
            #expect(post.webURL?.host()?.hasSuffix(".example") == true)
        }
        #expect(Fixture.servers.allSatisfy { $0.host.hasSuffix(".example") })
        #expect(Fixture.servers.count >= 3)
    }

    /// Not written as an already-merged row: two servers hand over one post, one of them
    /// naming the other as where it was written, and the merge above the fixture does the
    /// rest. A test that asserted `sources.count == 2` on a hand-made row would prove nothing
    /// about the app.
    @Test("One post carried by two servers is one row, and says both")
    func carriedByTwo() {
        let carried = everyPost.filter { $0.mergeKey.contains("carried-by-two") }
        #expect(carried.count == 2)
        #expect(Set(carried.map(\.mergeKey)).count == 1)
        #expect(Set(carried.map(\.sourceURL)).count == 2)

        let merged = carried.merged()
        #expect(merged.count == 1)
        #expect(merged.first?.sources.count == 2)
    }

    @Test("Something came attached, and it is a deck rather than one picture")
    func somethingAttached() {
        let withMedia = everyPost.filter { !$0.attachments.isEmpty }
        #expect(withMedia.count >= 2)
        #expect(withMedia.contains { $0.attachments.count >= 3 })
        #expect(withMedia.allSatisfy { $0.attachments.allSatisfy { !$0.isEmpty } })
    }

    @Test("The pictures are files this app drew, not addresses on somebody's server")
    func picturesAreDrawn() throws {
        let attachments = everyPost.flatMap(\.attachments)
        #expect(!attachments.isEmpty)
        for attachment in attachments {
            let url = try #require(attachment.displayURL)
            #expect(url.isFileURL)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("A post arrives covered, so the cover has something to be lifted from")
    func somethingCovered() {
        #expect(everyPost.contains { $0.sensitive == true && $0.spoiler?.isEmpty == false })
    }

    @Test("One post is a boost, and one has no counts at all")
    func theEdges() {
        #expect(everyPost.contains { $0.isBoost })
        #expect(everyPost.contains { $0.counts.areKnown == false })
    }

    /// One post has a conversation around it, and it has a **shape** — a way up as well as a
    /// way down, and a step in each. A flat fan of three replies to one post cannot show that
    /// a page draws the relationship (#75); it draws the same on a page that has learned to
    /// and a page that never did.
    @Test("One post has a conversation around it, and the conversation has a shape")
    func theConversation() throws {
        let head = try #require(everyPost.first { $0.mergeKey.hasSuffix("statuses/the-thread") })
        let thread = Fixture.conversation(around: head, now: Self.now)
        #expect(thread.isAlone == false)

        // Two above, in a chain: the second answers the first, and the post answers the second.
        #expect(thread.ancestors.count == 2)
        #expect(thread.ancestors[1].inReplyToURI == thread.ancestors[0].uri)
        #expect(head.inReplyToURI == thread.ancestors[1].uri)
        #expect(thread.climbed().map(\.depth) == [0, 1])
        #expect(thread.depthOfPost == 2)

        // Three below, and not all of them at the same depth.
        #expect(thread.descendants.count == 3)
        #expect(Set(thread.laidOut().map(\.depth)) == [1, 2])

        let plain = try #require(everyPost.first { $0.mergeKey.hasSuffix("the-plain-one") })
        #expect(Fixture.conversation(around: plain, now: Self.now).isAlone)
    }

    /// The client is the seam the app reads through, so it is asked the questions the app
    /// asks: one page and no history behind it, no home for an account nobody has, and a
    /// post that is never reconciled away.
    @Test("The source answers a page, and nothing behind it")
    func theSource() async throws {
        let source = FixtureSource()
        let first = try await source.timeline(host: Fixture.hosts[0], limit: 40, before: nil, after: nil, token: nil)
        #expect(!first.isEmpty)

        let older = try await source.timeline(host: Fixture.hosts[0], limit: 40, before: first.last, after: nil, token: nil)
        #expect(older.isEmpty)

        let home = try await source.home(host: Fixture.hosts[0], limit: 40, before: nil, after: nil, token: "t")
        #expect(home.isEmpty)

        #expect(try await source.stillHas(first[0], host: Fixture.hosts[0], token: nil))
        #expect(try await source.trending(host: Fixture.hosts[0], limit: 40, token: nil).isEmpty == false)
    }
}
