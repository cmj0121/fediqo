import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// What a row says about being an answer, which is as much as the page it is on can honestly
/// know: a timeline holds addresses, not the people behind them.
@Suite("A row that is an answer")
@MainActor
struct AnsweringTests {
    private func post(_ id: String, by who: String = "a", answering parent: String? = nil) -> Post {
        Post(uri: "https://one.example/api/v1/statuses/\(id)",
             socialProtocol: .mastodon, sourceURL: "https://one.example",
             createdAt: Date(timeIntervalSince1970: 100), authorId: "https://one.example/@\(who)",
             authorName: who.uppercased(), authorHandle: "@\(who)@one.example", text: id,
             inReplyToURI: parent.map { "https://one.example/api/v1/statuses/\($0)" })
    }

    @Test("A post that answers nothing says nothing")
    func notAnAnswer() {
        let alone = post("1")
        #expect(FeedScreen.answering(alone, among: [alone]) == .nothing)
    }

    @Test("Where the parent is on the page with it, the row names them")
    func namedFromThePage() {
        let parent = post("1", by: "wren")
        let reply = post("2", by: "ines", answering: "1")
        #expect(FeedScreen.answering(reply, among: [parent, reply]) == .handle("@wren@one.example"))
    }

    /// The other place that holds parents. A reader scrolls, and the post being answered went
    /// off the top of the page an hour ago — but this device still has it, and a name it holds
    /// is a name it may print.
    @Test("Where the store holds the parent, the row names them from there")
    func namedFromTheStore() {
        let reply = post("2", by: "ines", answering: "1")
        let known = ["https://one.example/api/v1/statuses/1": "@wren@one.example"]
        #expect(FeedScreen.answering(reply, among: [reply], orKnown: known) == .handle("@wren@one.example"))
    }

    /// The page first, because it is free — and because the two cannot disagree: they are the
    /// same post read from the same store.
    @Test("The page is asked before the store")
    func thePageComesFirst() {
        let parent = post("1", by: "wren")
        let reply = post("2", by: "ines", answering: "1")
        let known = ["https://one.example/api/v1/statuses/1": "@stale@one.example"]
        #expect(FeedScreen.answering(reply, among: [parent, reply], orKnown: known)
                == .handle("@wren@one.example"))
    }

    @Test("Where neither has it, the row says it is an answer and nothing more")
    func aParentNobodyHandedUs() {
        let reply = post("2", by: "ines", answering: "missing")
        // Not the reply's own handle, and not a name guessed from its mentions: neither the
        // page nor the store knows, and saying so is the whole of what a row may say.
        #expect(FeedScreen.answering(reply, among: [reply]) == .somebody)
        #expect(FeedScreen.answering(reply, among: [reply], orKnown: ["elsewhere": "@x@y"]) == .somebody)
    }

    /// #76's other half: a reply carries the address of what it answers and nothing about who
    /// wrote it, and the first mention is *usually* that person. Usually is not a fact, and a
    /// row that is right most of the time about who somebody was talking to is quietly wrong
    /// about it the rest of the time.
    @Test("A mention is never mistaken for the person being answered")
    func mentionsAreNotEvidence() {
        let reply = Post(
            uri: "https://one.example/api/v1/statuses/2", socialProtocol: .mastodon,
            sourceURL: "https://one.example", createdAt: Date(timeIntervalSince1970: 100),
            authorId: "https://one.example/@ines", authorName: "INES",
            authorHandle: "@ines@one.example", text: "@wren yes",
            inReplyToURI: "https://one.example/api/v1/statuses/missing",
            mentions: [Mention(uri: "https://one.example/@wren", handle: "@wren@one.example")])
        #expect(FeedScreen.answering(reply, among: [reply]) == .somebody)
    }
}
