import Foundation
import Testing
@testable import FediqoCore

/// The only thing between what arrived and what you see. It may add and it may remove;
/// the one thing it must never do is decide where a post sits.
@Suite("A rule may remove a post; it may never move one")
struct TimelineFilterTests {
    private var posts: [Post] {
        [
            makePost(uri: "u3", at: 300, media: ["https://one.example/a.png"]),
            makePost(uri: "u2", at: 200, boostedBy: "someone else"),
            makePost(uri: "u1", at: 100),
        ]
    }

    @Test("Hiding boosts removes them and leaves the rest where they were")
    func withoutBoosts() {
        let filtered = TimelineLoader.apply(showBoosts: false, mediaOnly: false, to: posts)
        #expect(filtered.map(\.uri) == ["u3", "u1"])
    }

    @Test("Asking for media only removes everything without any")
    func mediaOnly() {
        let filtered = TimelineLoader.apply(showBoosts: true, mediaOnly: true, to: posts)
        #expect(filtered.map(\.uri) == ["u3"])
    }

    @Test("With no rule at all, everything is there, in the order it arrived in")
    func withoutRules() {
        let filtered = TimelineLoader.apply(showBoosts: true, mediaOnly: false, to: posts)
        #expect(filtered.map(\.uri) == ["u3", "u2", "u1"])
    }
}
