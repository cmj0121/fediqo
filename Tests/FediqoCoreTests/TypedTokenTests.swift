import Foundation
import Testing
@testable import FediqoCore

/// The token somebody is part-way through typing — a handle or a hashtag (#98, #108).
///
/// One finder for both, because the two differ in their first character and in what is asked
/// about them and in nothing else. These assertions are what say so.
@Suite("What is being typed")
struct TypedTokenTests {
    private func kind(_ draft: String) -> MentionQuery.Kind? {
        MentionQuery.trailing(in: draft)?.kind
    }

    @Test("A handle and a hashtag are told apart by the mark they start with")
    func twokinds() {
        #expect(kind("hello @tove") == .handle)
        #expect(kind("hello #libraries") == .tag)
        #expect(kind("hello there") == nil)
    }

    /// `＃` is U+FF03, which is what a Japanese or Chinese keyboard types without leaving the
    /// input mode the rest of the draft is in.
    @Test("Both hashes start a hashtag")
    func bothHashes() {
        #expect(kind("hello ＃libraries") == .tag)
        #expect(MentionQuery.trailing(in: "hello ＃libraries")?.text == "libraries")
    }

    /// The same line both tokens are held to, and it is `shortest`: a bare mark is the start of
    /// everything there is, and one letter is barely narrower. Nothing is asked before there is
    /// something to ask about, and that is decided once rather than once per kind.
    @Test("Both need the same amount typed before anybody is asked")
    func bothWaitTheSame() {
        #expect(MentionQuery.trailing(in: "@") == nil)
        #expect(MentionQuery.trailing(in: "#") == nil)
        #expect(MentionQuery.trailing(in: "@t") == nil)
        #expect(MentionQuery.trailing(in: "#t") == nil)
        #expect(MentionQuery.trailing(in: "@to") != nil)
        #expect(MentionQuery.trailing(in: "#to") != nil)
    }

    @Test("A finished token is not being typed")
    func afinishedToken() {
        #expect(MentionQuery.trailing(in: "#libraries ") == nil)
        #expect(MentionQuery.trailing(in: "@tove ") == nil)
    }

    /// What replaces the token is what is handed in, written the way it goes into a post — so
    /// what a handle or a hashtag looks like is decided in one place rather than two.
    @Test("Taking one puts back what it was given, and a space to carry on from")
    func takingOne() throws {
        let tag = try #require(MentionQuery.trailing(in: "about #lib"))
        #expect(tag.accepting("#libraries", in: "about #lib") == "about #libraries ")
        let handle = try #require(MentionQuery.trailing(in: "hello @to"))
        #expect(handle.accepting("@tove@one.example", in: "hello @to") == "hello @tove@one.example ")
    }

    /// The token is found at the end of the draft and nowhere else, which is as true of a
    /// hashtag as it was of a handle: SwiftUI does not hand the caret over, and an offer
    /// attached to the wrong place would replace words somebody had already written.
    @Test("Only the end of the draft is being typed")
    func onlyTheEnd() {
        #expect(MentionQuery.trailing(in: "#libraries and more words") == nil)
    }
}
