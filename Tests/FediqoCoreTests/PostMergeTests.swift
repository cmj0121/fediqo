import Foundation
import Testing
@testable import FediqoCore

@Suite("One post, however many servers carried it")
struct PostMergeTests {
    @Test("The same post from two servers is one row that names both")
    func collapses() {
        let merged = [
            makePost(uri: "https://a.example/1", at: 100, from: "one.example"),
            makePost(uri: "https://a.example/1", at: 100, from: "two.example"),
        ].merged()

        #expect(merged.count == 1)
        #expect(merged[0].sources == ["one.example", "two.example"])
    }

    @Test("A boost and its original are not merged into each other")
    func boostsStaySeparate() {
        // A boost carries the original's uri; only who boosted it tells them apart.
        let original = makePost(uri: "https://a.example/1", at: 100, from: "one.example")
        let boost = makePost(uri: "https://a.example/1", at: 120, from: "one.example", boostedBy: "someone else")

        #expect(original.mergeKey != boost.mergeKey)
        #expect([original, boost].merged().count == 2)
    }

    @Test("The key is built on the booster's id and the canonical id, in the store's two tiers")
    func keyTiers() {
        let plain = makePost(uri: "https://a.example/api/v1/statuses/1", originURI: "https://o.example/users/a/statuses/1", at: 100)
        let boost = makePost(uri: "https://a.example/api/v1/statuses/2", originURI: "https://o.example/users/a/statuses/1", at: 120, boostedBy: "b")

        #expect(plain.mergeKey == "https://o.example/users/a/statuses/1")
        #expect(boost.mergeKey == "boost:https://booster.example/users/b|https://o.example/users/a/statuses/1")
        #expect(makePost(uri: "u", at: 100).mergeKey == "u")
    }

    @Test("Two servers with two local addresses for one canonical post are one row")
    func collapsesOnOrigin() {
        let merged = [
            makePost(uri: "https://one.example/api/v1/statuses/44", originURI: "https://o.example/users/a/statuses/1", at: 100, from: "one.example"),
            makePost(uri: "https://two.example/api/v1/statuses/97", originURI: "https://o.example/users/a/statuses/1", at: 100, from: "two.example"),
        ].merged()

        #expect(merged.count == 1)
        #expect(merged[0].sources == ["one.example", "two.example"])
    }

    @Test("Tags are one spelling each, in the order they came")
    func tagsNormalised() {
        let post = makePost(uri: "u", at: 100, tags: ["#Swift", "swift", "Caf\u{0065}\u{0301}", "café", "#", "Rust"])
        #expect(post.tags == ["swift", "café", "rust"])
    }

    @Test("The same boost from two servers is still one row")
    func sameBoostCollapses() {
        let merged = [
            makePost(uri: "https://a.example/1", at: 120, from: "one.example", boostedBy: "someone else"),
            makePost(uri: "https://a.example/1", at: 120, from: "two.example", boostedBy: "someone else"),
        ].merged()

        #expect(merged.count == 1)
        #expect(merged[0].sources == ["one.example", "two.example"])
    }

    @Test("Order is the timestamp and nothing else")
    func ordering() {
        let merged = [
            makePost(uri: "u1", at: 100, from: "one.example"),
            makePost(uri: "u3", at: 300, from: "one.example"),
            makePost(uri: "u2", at: 200, from: "two.example"),
        ].merged()

        #expect(merged.map(\.uri) == ["u3", "u2", "u1"])
    }
}
