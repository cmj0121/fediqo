import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// A mark that is still on its way to somebody else's machine.
///
/// The press answers at once and the server does not, and the row has to be able to say which
/// of those two it is showing. Nothing here is about the animation itself — a package cannot
/// execute a view body — but the answer the animation is drawn from is decided here, and it is
/// the part that can be wrong: the wrong control working, one that never stops, or one that
/// pulses at a write that never left the machine.
@Suite("A mark still on its way")
@MainActor
struct MarkInFlightTests {
    private func post(_ id: String) -> Post {
        Post(uri: "https://one.example/api/v1/statuses/\(id)",
             originURI: "https://one.example/users/a/statuses/\(id)",
             socialProtocol: .mastodon, sourceURL: "https://one.example",
             createdAt: Date(timeIntervalSince1970: 100), authorId: "https://one.example/@a",
             authorName: "A", authorHandle: "@a@one.example", text: id,
             counts: Counts(replies: 0, reblogs: 1, favourites: 3))
    }

    /// The control that was pressed is the one that says it is working, and it is the only one.
    @Test("While the write is out, the mark that was pressed is the one working")
    func onlyThePressedMark() async throws {
        let gate = Gate()
        let posts = [post("a")]
        let app = try await signedInApp("flight-one", posts: posts, client: WriteDouble(gate: gate))

        let acting = Task { await app.act(.favourite, on: posts[0]) }
        await gate.waitUntilEntered()

        #expect(app.isActing(.favourite, on: posts[0]))
        #expect(app.isActing(.reblog, on: posts[0]) == false)
        #expect(app.isActing(.bookmark, on: posts[0]) == false)

        await gate.open()
        await acting.value
    }

    /// And it stops when the server answers. A control that went on working after the answer
    /// would be saying the app is waiting for something it already has.
    @Test("When the write lands, nothing is working any more")
    func itStopsWhenItLands() async throws {
        let posts = [post("a")]
        let app = try await signedInApp("flight-lands", posts: posts, client: WriteDouble())

        await app.act(.favourite, on: posts[0])

        #expect(app.isActing(.favourite, on: posts[0]) == false)
        #expect(app.actingOn.isEmpty)
    }

    /// A refusal stops it too. The star goes back and the control stops — the two together are
    /// what says the press did not take, and either alone would be a half-told story.
    @Test("A refused write stops working and puts the mark back")
    func arefusalStopsIt() async throws {
        let posts = [post("a")]
        let app = try await signedInApp("flight-refused", posts: posts,
                                        client: WriteDouble(refusing: true))

        await app.act(.favourite, on: posts[0])

        #expect(app.isActing(.favourite, on: posts[0]) == false)
        #expect(app.actingOn.isEmpty)
        #expect(app.marks(of: posts[0]).favourited == nil)
    }

    /// Two marks out on one post at once are two controls working. This is why it is kept by
    /// action rather than by post: a reader who boosts and then stars should not see the boost
    /// speak for the star.
    @Test("Two marks out on one post are two controls working")
    func twoAtOnce() async throws {
        let gate = Gate()
        let posts = [post("a")]
        let app = try await signedInApp("flight-two", posts: posts, client: WriteDouble(gate: gate))

        let boosting = Task { await app.act(.reblog, on: posts[0]) }
        let starring = Task { await app.act(.favourite, on: posts[0]) }
        await gate.waitUntilEntered(2)

        #expect(app.isActing(.reblog, on: posts[0]))
        #expect(app.isActing(.favourite, on: posts[0]))
        #expect(app.isActing(.bookmark, on: posts[0]) == false)

        await gate.open()
        await boosting.value
        await starring.value
        #expect(app.actingOn.isEmpty)
    }

    /// Keeping never goes anywhere, so it never waits for anything. A control that pulsed at a
    /// write to this machine's own database would be inventing a wait to show the reader.
    @Test("Keeping a post is nobody's round trip and never says it is working")
    func keepingNeverWaits() async throws {
        let posts = [post("a")]
        let app = try await signedInApp("flight-keep", posts: posts, client: WriteDouble())

        await app.keep(posts[0])

        #expect(app.isKept(posts[0]))
        #expect(app.actingOn.isEmpty)
    }

    /// A press with no account behind it never leaves, so nothing is ever left working. The
    /// refusal is immediate and the control has to be back where it started.
    @Test("A press with nobody to act as leaves no control working")
    func noAccountLeavesNothingWorking() async throws {
        let app = freshApp("flight-signed-out")
        let post = post("a")

        await app.act(.favourite, on: post)

        #expect(app.actionFailure != nil)
        #expect(app.isActing(.favourite, on: post) == false)
        #expect(app.actingOn.isEmpty)
    }
}
