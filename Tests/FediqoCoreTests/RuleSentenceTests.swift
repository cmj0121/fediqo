import Foundation
import Testing
@testable import FediqoCore

/// A rule, read back as a sentence somebody would say (#115).
///
/// A kind and a value in two boxes is a form. Reading a rule back is most of being able to
/// change one, which is why the sheet could carry only one rule for as long as it could only
/// show a kind and a value.
@Suite("A rule you can read")
struct RuleSentenceTests {
    @Test("Each kind says itself, both ways round")
    func bothWaysRound() {
        for kind in TimelineFilter.Kind.allCases {
            let keeping = TimelineFilter(kind: kind, value: "x").sentence
            let dropping = TimelineFilter(kind: kind, value: "x", negate: true).sentence
            #expect(keeping.key == "rule.\(kind.rawValue).with")
            #expect(dropping.key == "rule.\(kind.rawValue).without")
            // The two must not be the same sentence, or "keep" and "leave out" would read
            // identically on the screen and the control would be the only thing saying which.
            #expect(keeping.key != dropping.key)
        }
    }

    /// The value is what the reader typed, not what the model made of it — except for a tag,
    /// which is normalised on the way in so that `#Swift` and `swift` are one rule.
    @Test("The sentence carries what the rule is about")
    func whatItIsAbout() {
        #expect(TimelineFilter(kind: .server, value: "birch.example").sentence.value == "birch.example")
        #expect(TimelineFilter(kind: .tag, value: "#Swift").sentence.value == "swift")
    }

    /// Every kind a reader can write must have somewhere for the words to live. A kind added to
    /// the model with no sentence is a rule that reads as its own key on the screen.
    @Test("Every kind of rule is one the builder can offer")
    func everyKindIsReachable() {
        #expect(TimelineFilter.Kind.allCases.count == 5)
        #expect(Set(TimelineFilter.Kind.allCases.map(\.rawValue))
                == ["tag", "author", "mention", "server", "media"])
    }

    /// Several rules, of different kinds, each way round — the thing the sheet could not write
    /// down and the model always could. A post has to satisfy every one of them.
    @Test("Several rules of different kinds are all applied")
    func severalRules() {
        let post = makePost(uri: "https://a.example/1", at: 1, from: "a.example",
                            text: "about swift", tags: ["swift"])
        let timeline = Timeline(name: "n", source: .public, template: "public", filters: [
            TimelineFilter(kind: .tag, value: "#Swift"),
            TimelineFilter(kind: .server, value: "b.example", negate: true),
        ])
        #expect(timeline.query.admitted([post]) == [post])

        let alsoNotFromA = Timeline(name: "n", source: .public, template: "public", filters: [
            TimelineFilter(kind: .tag, value: "swift"),
            TimelineFilter(kind: .server, value: "a.example", negate: true),
        ])
        #expect(alsoNotFromA.query.admitted([post]).isEmpty)
    }

    /// **Removing the last rule leaves a timeline rather than a broken one.** No rules means
    /// everything the reading carries, which is what the three shipped ones are.
    @Test("No rules is everything, not nothing")
    func norulesIsEverything() {
        let post = makePost(uri: "https://a.example/2", at: 1, from: "a.example")
        let timeline = Timeline(name: "n", source: .public, template: "public", filters: [])
        #expect(timeline.query.admitted([post]) == [post])
    }
}
