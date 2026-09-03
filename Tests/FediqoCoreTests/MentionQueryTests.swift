import Foundation
import Testing
@testable import FediqoCore

/// The handle somebody is part-way through typing (#98).
///
/// Two things have to hold and the second is the one that matters. **Nothing is asked before there
/// is something to ask about** — a server asked on the bare `@` answers with whoever it lists
/// first, which is nobody's question. And **nothing is ever rewritten that the reader did not
/// mean**: the offer is attached to the end of the draft, which is a place this can be certain of,
/// rather than to a guessed caret, which is a place it cannot.
@Suite("The handle being typed")
struct MentionQueryTests {
    private func text(_ draft: String) -> String? { MentionQuery.trailing(in: draft)?.text }

    // MARK: - when there is something to ask about

    @Test("A handle at the end of the draft is what is asked about")
    func theTrailingHandle() {
        #expect(text("hello @tov") == "tov")
        #expect(text("@tov") == "tov")
    }

    /// A full handle is still being typed as far as this is concerned — `@tove@ced` is on its way
    /// to `@tove@cedar.example`, and the offer is what gets it there.
    @Test("A handle part-way through its host is still a handle")
    func theHostHalfTyped() {
        #expect(text("@tove@ced") == "tove@ced")
    }

    // MARK: - when there is not

    @Test("A bare @ asks nobody")
    func abareAtAsksNobody() {
        #expect(text("@") == nil)
        #expect(text("hello @") == nil)
    }

    /// One letter is barely narrower than none. The line is drawn at two, and it is drawn here
    /// rather than in the view, so it is the same line wherever it is asked.
    @Test("One letter is not enough to ask about")
    func oneLetterIsNotEnough() {
        #expect(text("@t") == nil)
        #expect(text("@to") == "to")
        #expect(MentionQuery.shortest == 2)
    }

    /// The token is finished and the reader has moved on. An offer still standing there would be
    /// an offer to replace a word they have already left.
    @Test("A draft that ends in a space is asking nothing")
    func afinishedTokenAsksNothing() {
        #expect(text("@tove@cedar.example ") == nil)
        #expect(text("@tove hello") == nil)
    }

    @Test("Words that are not a handle ask nothing")
    func plainWordsAskNothing() {
        #expect(text("hello there") == nil)
        #expect(text("") == nil)
        #expect(text("an email like a@b") == nil)
    }

    /// The end of the draft and not the middle of it. Editing in the middle offers nothing, which
    /// is the honest answer — the alternative is an offer that would replace the wrong word.
    @Test("A handle in the middle of a draft is not what is being typed")
    func theMiddleIsNotTheEnd() {
        #expect(text("@tove and then some words") == nil)
    }

    // MARK: - taking one

    @Test("Taking a handle replaces the whole token and leaves room to write after it")
    func takingReplacesTheToken() throws {
        let draft = "morning @tov"
        let query = try #require(MentionQuery.trailing(in: draft))

        #expect(query.accepting("@tove@cedar.example", in: draft)
                == "morning @tove@cedar.example ")
    }

    /// What was written before the token is untouched, which is the whole promise: this finishes
    /// a word, it does not edit a draft.
    @Test("Nothing before the token is touched")
    func nothingBeforeIsTouched() throws {
        let draft = "@ines@birch.example and also @tov"
        let query = try #require(MentionQuery.trailing(in: draft))

        #expect(query.accepting("@tove@cedar.example", in: draft)
                == "@ines@birch.example and also @tove@cedar.example ")
    }

    /// A draft that is nothing but the handle is the commonest one there is — a reply opening
    /// with somebody in it, which is #97.
    @Test("A draft that is only a handle is replaced whole")
    func onlyAHandle() throws {
        let query = try #require(MentionQuery.trailing(in: "@tov"))
        #expect(query.accepting("@tove@cedar.example", in: "@tov") == "@tove@cedar.example ")
    }

    /// A newline is whitespace like any other: a handle at the end of the second line is the one
    /// being typed, and one left at the end of the first is not.
    @Test("A new line ends a token as surely as a space")
    func newlinesEndTokens() {
        #expect(text("@tove@cedar.example\nand then @in") == "in")
        #expect(text("@tove@cedar.example\n") == nil)
    }
}

/// What is actually asked of a server when a handle is being typed (#98).
@Suite("Asking who a handle could be")
struct MentionSearchTests {
    private var client: MastodonClient { MastodonClient(session: stubbedSession()) }

    private func acting(on host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/@ada", token: "t")
    }

    /// **`resolve=false`, and it is the whole point.** Every other search in this app asks a
    /// server to go and fetch somebody, because it is asking about an address a reader gave.
    /// This one is asked on a keystroke, and a server sent out to the rest of the network on
    /// every letter somebody types is a cost nobody asked it to pay.
    @Test("It asks the reader's own server, and never sends it out to fetch")
    func itNeverFetches() async throws {
        let host = "mention-search.test"
        stubRoutes.on(host, "/api/v1/accounts/search", status: 200, body: """
        [{ "id": "1", "url": "https://\(host)/@tove", "username": "tove", "acct": "tove",
           "display_name": "Tove", "avatar": null }]
        """)

        let found = try await client.searchPeople(matching: "to", limit: 5, as: acting(on: host))

        let asked = try #require(stubRoutes.requests(for: host, "/api/v1/accounts/search").first)
        #expect(asked.query["q"] == "to")
        #expect(asked.query["limit"] == "5")
        #expect(asked.query["resolve"] == "false")
        #expect(found.map(\.handle) == ["@tove@\(host)"])
    }

    /// A bare `acct` is how a server spells one of its own, and it becomes a whole handle by the
    /// same rule every handle in this app follows — so what goes into the draft is addressable
    /// from anywhere rather than only from there.
    @Test("A local account is offered as a whole handle")
    func alocalAccountIsWhole() async throws {
        let host = "mention-local.test"
        stubRoutes.on(host, "/api/v1/accounts/search", status: 200, body: """
        [{ "id": "2", "url": "https://\(host)/@ines", "username": "ines", "acct": "ines",
           "display_name": "Ines", "avatar": null }]
        """)

        let found = try await client.searchPeople(matching: "in", limit: 5, as: acting(on: host))

        #expect(found.first?.handle == "@ines@\(host)")
    }
}
