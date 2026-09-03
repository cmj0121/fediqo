import Foundation
import Testing
@testable import FediqoCore

/// Who a reply opens with (#97).
///
/// The one thing worth being careful about is that this speaks to people on the reader's behalf.
/// A draft that opens with eleven handles has pulled eleven people into a conversation before the
/// reader has written a word, and a draft that opens by addressing the reader themselves is one
/// they have to edit before they can start. Both are asserted here.
@Suite("Who a reply opens with")
struct CarriedMentionsTests {
    private let host = "cedar.example"

    /// A post by `who`, naming `naming` — the shape a real reply is built from.
    private func post(by who: String, naming: [String] = []) -> Post {
        Post(uri: "https://\(host)/api/v1/statuses/1", socialProtocol: .mastodon,
             sourceURL: "https://\(host)", createdAt: Date(timeIntervalSince1970: 100),
             authorId: "https://\(host)/@\(who)", authorName: who.capitalized,
             authorHandle: "@\(who)@\(host)", text: "one",
             mentions: naming.map { Mention(uri: "https://\(host)/@\($0)",
                                            handle: "@\($0)@\(host)") })
    }

    private func me(_ who: String) -> String { "https://\(host)/@\(who)" }

    // MARK: - the three answers

    @Test("Nobody opens the draft empty")
    func nobodyCarriesNobody() {
        let parent = post(by: "tove", naming: ["ines", "wren"])
        #expect(CarriedMentions.nobody.opening(answering: parent, as: me("ada")) == "")
    }

    @Test("Them carries the person being answered and nobody else")
    func repliedCarriesOne() {
        let parent = post(by: "tove", naming: ["ines", "wren"])
        #expect(CarriedMentions.replied.opening(answering: parent, as: me("ada"))
                == "@tove@cedar.example ")
    }

    /// The person being answered first, and the rest at the tail — which is the order the issue
    /// asked for, and the order a reader reads the draft in.
    @Test("Everyone carries them first and the rest behind")
    func everyoneCarriesInOrder() {
        let parent = post(by: "tove", naming: ["ines", "wren"])
        #expect(CarriedMentions.everyone.carried(answering: parent, as: me("ada"))
                == ["@tove@cedar.example", "@ines@cedar.example", "@wren@cedar.example"])
    }

    // MARK: - who is never carried

    /// A draft that opens by addressing you is a draft you have to edit before you can write in
    /// it. Compared by account URI rather than by handle, because a handle is spelled by whichever
    /// server is doing the spelling and the URI is the thing both ends actually have.
    @Test("The reader is never carried into their own reply")
    func theReaderIsNeverCarried() {
        let parent = post(by: "tove", naming: ["ada", "ines"])
        #expect(CarriedMentions.everyone.carried(answering: parent, as: me("ada"))
                == ["@tove@cedar.example", "@ines@cedar.example"])
    }

    /// Answering yourself is a thing people do — a thread of your own — and it opens with nobody
    /// in it rather than with your own handle.
    @Test("Answering yourself carries nobody, and the rest still follows")
    func answeringYourself() {
        let parent = post(by: "ada", naming: ["ines"])
        #expect(CarriedMentions.replied.carried(answering: parent, as: me("ada")) == [])
        #expect(CarriedMentions.everyone.carried(answering: parent, as: me("ada"))
                == ["@ines@cedar.example"])
    }

    /// The person being answered is almost always in the post's own mention list as well, so
    /// this is the ordinary case rather than a corner of it.
    @Test("Nobody is carried twice, however often the post named them")
    func nobodyTwice() {
        let parent = post(by: "tove", naming: ["tove", "ines", "tove"])
        #expect(CarriedMentions.everyone.carried(answering: parent, as: me("ada"))
                == ["@tove@cedar.example", "@ines@cedar.example"])
    }

    /// Nobody signed in anywhere is somebody with no account to leave out, not somebody to
    /// leave everything out for.
    @Test("With nobody acting, everyone the post named is still carried")
    func noActingAccount() {
        let parent = post(by: "tove", naming: ["ines"])
        #expect(CarriedMentions.everyone.carried(answering: parent, as: nil)
                == ["@tove@cedar.example", "@ines@cedar.example"])
    }

    // MARK: - the shape of what comes out

    /// It ends in a space, because what follows it is what the reader came to write.
    @Test("What is carried is ready to be written after")
    func readyToWriteAfter() {
        let opening = CarriedMentions.replied.opening(answering: post(by: "tove"), as: me("ada"))
        #expect(opening.hasSuffix(" "))
        #expect(!opening.hasPrefix(" "))
    }

    /// A post whose author has no handle — a server that sent nothing useful — is not answered
    /// with an empty mention, which would be an `@` on its own in the draft.
    @Test("A handle nobody sent is not carried as nothing")
    func anemptyHandleIsNotCarried() {
        let nameless = Post(uri: "https://\(host)/api/v1/statuses/2", socialProtocol: .mastodon,
                            sourceURL: "https://\(host)",
                            createdAt: Date(timeIntervalSince1970: 100),
                            authorId: "https://\(host)/@ghost", authorName: "",
                            authorHandle: "", text: "one")
        #expect(CarriedMentions.replied.carried(answering: nameless, as: me("ada")) == [])
    }
}
