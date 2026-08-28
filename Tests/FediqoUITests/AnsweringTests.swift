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

    @Test("Where it is not, the row says it is an answer and nothing more")
    func aParentNobodyHandedUs() {
        let reply = post("2", by: "ines", answering: "missing")
        // Not the reply's own handle, and not a name guessed from its mentions: the page does
        // not know, and saying so is the whole of what it may say.
        #expect(FeedScreen.answering(reply, among: [reply]) == .somebody)
    }
}
