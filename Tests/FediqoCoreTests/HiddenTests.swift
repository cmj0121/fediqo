import Foundation
import Testing
@testable import FediqoCore

/// Why a post that arrived is not on the screen.
///
/// #6's last promise, and the only one of its six that is about being wrong: the others are
/// rules the app follows silently — timestamp order, add or remove but never move, no rules
/// means everything — and this is the one that says a reader must be able to hold it to them.
@Suite("Which rule hid it")
struct HiddenTests {
    private func post(_ id: String, tags: [String] = [], media: [String] = [],
                      boostedBy: String? = nil) -> Post {
        makePost(uri: id, at: 1, boostedBy: boostedBy, tags: tags, media: media)
    }

    /// The rule that turned it away is named, and it is the rule the reader wrote rather than
    /// some description of what happened.
    @Test("A post a rule removed says which rule")
    func aRuleNamesItself() {
        let rule = TimelineFilter(kind: .tag, value: "swift", negate: true)
        let query = TimelineQuery(source: .public, filters: [rule])

        let sifted = query.sifted([post("a", tags: ["swift"]), post("b", tags: ["coffee"])])

        #expect(sifted.admitted.map(\.uri) == ["b"])
        #expect(sifted.hidden.count == 1)
        #expect(sifted.hidden[0].post.uri == "a")
        #expect(sifted.hidden[0].because == .rule(rule))
    }

    /// **The first rule that refused it, not all of them.** A post has to satisfy every rule,
    /// so the first refusal is the whole reason it is not here — the rest were never asked, and
    /// listing them would be inventing reasons after the fact.
    @Test("Two rules could have hidden it; the one that did is the first")
    func theFirstRefusalIsTheReason() {
        let first = TimelineFilter(kind: .tag, value: "swift", negate: true)
        let second = TimelineFilter(kind: .server, value: "one.example", negate: true)
        let query = TimelineQuery(source: .public, filters: [first, second])

        let sifted = query.sifted([post("a", tags: ["swift"])])

        #expect(sifted.hidden.count == 1)
        #expect(sifted.hidden[0].because == .rule(first))
    }

    /// With no rules at all, nothing is hidden and nothing is claimed to be.
    @Test("No rules means nothing hidden")
    func noRulesHideNothing() {
        let query = TimelineQuery(source: .public)
        let sifted = query.sifted([post("a"), post("b")])

        #expect(sifted.admitted.count == 2)
        #expect(sifted.hidden.isEmpty)
    }

    /// The two switches are rules of the same kind — the reader's own, removing and never
    /// moving — so they answer the same question the same way.
    @Test("The boosts switch says it was the boosts switch")
    func boostsSaySo() {
        let sifted = TimelineLoader.sift(showBoosts: false, mediaOnly: false,
                                         [post("a"), post("b", boostedBy: "dag")])

        #expect(sifted.admitted.map(\.uri) == ["a"])
        #expect(sifted.hidden.map(\.because) == [.boostsHidden])
    }

    @Test("The media switch says it was the media switch")
    func mediaSaysSo() {
        let sifted = TimelineLoader.sift(showBoosts: true, mediaOnly: true,
                                         [post("a", media: ["https://one.example/p.png"]), post("b")])

        #expect(sifted.admitted.map(\.uri) == ["a"])
        #expect(sifted.hidden.map(\.because) == [.mediaOnly])
    }

    /// Sifting is what filtering was, and the old answer has to be the new one — every caller
    /// that only wants the list still gets exactly the list it got.
    @Test("What is admitted is what was admitted before")
    func admittedIsUnchanged() {
        let query = TimelineQuery(source: .public,
                                  filters: [TimelineFilter(kind: .tag, value: "swift")])
        let posts = [post("a", tags: ["swift"]), post("b"), post("c", tags: ["swift", "vapor"])]

        #expect(query.admitted(posts).map(\.uri) == query.sifted(posts).admitted.map(\.uri))
        #expect(query.admitted(posts).map(\.uri) == ["a", "c"])
        #expect(TimelineLoader.apply(showBoosts: false, mediaOnly: false, to: posts).map(\.uri)
                == TimelineLoader.sift(showBoosts: false, mediaOnly: false, posts).admitted.map(\.uri))
    }
}
