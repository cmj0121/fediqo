import Foundation
import Testing
import SwiftUI
import FediqoCore
@testable import FediqoUI

/// The offer itself: what is asked of whom, and what a press of `Tab` does with the answer (#98).
@Suite("Offering who a handle could be")
@MainActor
struct MentionOfferTests {
    private let host = "one.example"

    private func profile(_ who: String) -> Profile {
        Profile(id: who, authorId: "https://\(host)/@\(who)", name: who.capitalized,
                handle: "@\(who)@\(host)")
    }

    private func account() -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/@ada", token: "t")
    }

    private func model(_ found: [Profile], refusing: Bool = false) -> MentionSuggestions {
        MentionSuggestions(registry: SourceRegistry(
            clients: [.mastodon: PeopleDouble(found: found, refusing: refusing)]))
    }

    // MARK: - asking

    @Test("What the server offered is what is drawn")
    func whatIsOfferedIsDrawn() async {
        let offering = model([profile("tove"), profile("tom")])

        await offering.look(for: "to", as: account())

        #expect(offering.people.map(\.handle) == ["@tove@one.example", "@tom@one.example"])
        #expect(offering.first?.handle == "@tove@one.example")
    }

    /// Nobody signed in on the server this draft would go to is nobody to ask. A composer that
    /// asked anyway would be asking a stranger about the reader's own correspondents.
    @Test("With nobody to act as, nobody is asked and nothing is offered")
    func nobodyToAskAs() async {
        let offering = model([profile("tove")])

        await offering.look(for: "to", as: nil)

        #expect(offering.people.isEmpty)
    }

    /// A convenience while somebody is typing is not a thing to interrupt a draft over. The
    /// reader types the handle themselves, which is what they were doing anyway.
    @Test("A server that will not answer says nothing to the reader")
    func arefusalIsQuiet() async {
        let offering = model([], refusing: true)

        await offering.look(for: "to", as: account())

        #expect(offering.people.isEmpty)
    }

    /// An answer to a question the reader has moved on from is not an answer to draw. Without
    /// this, a slow reply about `@to` lands under a draft that now says `@tove@cedar.exam`.
    @Test("An answer to a question nobody is asking any more is dropped")
    func alateAnswerIsDropped() async {
        let offering = model([profile("tove")])

        await offering.look(for: "to", as: account())
        offering.clear()

        #expect(offering.people.isEmpty)
    }

    // MARK: - taking one

    /// The model says which was taken and writes nothing. The composer owns the draft, so there
    /// is one place in the app that edits what somebody wrote.
    @Test("Tab takes the first of them, and the model writes nothing itself")
    func tabTakesTheFirst() async throws {
        let written = Post(uri: "https://\(host)/api/v1/statuses/1", socialProtocol: .mastodon,
                           sourceURL: "https://\(host)",
                           createdAt: Date(timeIntervalSince1970: 100),
                           authorId: "https://\(host)/@ada", authorName: "Ada",
                           authorHandle: "@ada@\(host)", text: "one")
        let app = try await signedInApp("mention-tab", posts: [written],
                                        client: PeopleDouble(found: [profile("tove"),
                                                                     profile("tom")]))
        #expect(!app.isOfferingHandle)

        await app.mentions.look(for: "to", as: account())

        #expect(app.isOfferingHandle)
        #expect(app.perform(.completeMention))
        #expect(app.mentions.chosen?.handle == "@tove@one.example")
    }

    /// With nothing on offer, `Tab` in a draft is the nothing it always was — it is not handed
    /// back, because a letter-shaped key mid-draft never is, but it does not complete anything.
    @Test("With nothing offered, Tab completes nothing")
    func tabWithNoOffer() {
        #expect(KeyCommand.from(KeyEquivalent.tab.character, modifiers: [], typing: true,
                                offering: false) == nil)
    }

    @Test("With something offered, Tab is the completion key")
    func tabWithAnOffer() {
        #expect(KeyCommand.from(KeyEquivalent.tab.character, modifiers: [], typing: true,
                                offering: true) == .completeMention)
    }

    /// And outside a draft it is still the move it always was. An offer standing while nobody is
    /// typing must not take the key off the tabs.
    @Test("Outside a draft Tab is still the move it was")
    func tabOutsideADraft() {
        #expect(KeyCommand.from(KeyEquivalent.tab.character, modifiers: [], typing: false,
                                offering: true) == .nextTab)
    }
}

/// A server that answers an account search, or will not.
final class PeopleDouble: SourceClient, @unchecked Sendable {
    private let found: [Profile]
    private let refusing: Bool

    init(found: [Profile], refusing: Bool = false) {
        self.found = found
        self.refusing = refusing
    }

    func searchPeople(matching query: String, limit: Int,
                      as account: ActingAccount) async throws -> [Profile] {
        if refusing { throw SourceFailure.badHost(account.host) }
        return found
    }

    func instance(host: String) async throws -> InstanceInfo {
        InstanceInfo(host: host, title: host, summary: "", maxCharacters: 500)
    }
    func timeline(host: String, limit: Int, before: Post?, after: Post?, token: String?) async throws -> [Post] { [] }
    func home(host: String, limit: Int, before: Post?, after: Post?, token: String) async throws -> [Post] { [] }
    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }
    func context(of post: Post, host: String, token: String?) async throws -> Conversation {
        Conversation(post: post)
    }
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }
}
