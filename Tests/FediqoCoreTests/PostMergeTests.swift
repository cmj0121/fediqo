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
        // A boost carries the original's uri; only `boostedBy` tells them apart.
        let merged = [
            makePost(uri: "https://a.example/1", at: 100, from: "one.example"),
            makePost(uri: "https://a.example/1", at: 120, from: "one.example", boostedBy: "someone else"),
        ].merged()

        #expect(merged.count == 2)
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
