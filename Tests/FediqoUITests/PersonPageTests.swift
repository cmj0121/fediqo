import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// What the page about somebody knows, and the two silences it must not confuse.
///
/// The model is where "we were not told" and "the answer is no" are kept apart, and both of them
/// reach the screen as an absent follow. A test that only checked `relationship == nil` would
/// pass for either.
@MainActor
@Suite("A page about somebody")
struct PersonPageTests {
    private func post(by who: String = "tove", on host: String = "cedar.example") -> Post {
        Post(uri: "https://\(host)/api/v1/statuses/1", socialProtocol: .mastodon,
             sourceURL: "https://\(host)", createdAt: Date(timeIntervalSince1970: 100),
             authorId: "https://\(host)/@\(who)", authorName: who.capitalized,
             authorHandle: "@\(who)@\(host)", text: "one")
    }

    private func model(_ client: PersonDouble, signedIn: Bool = true) -> PersonModel {
        PersonModel(subject: PersonSubject(post: post()), client: client) {
            signedIn ? ActingAccount(host: "birch.example",
                                     authorId: "https://birch.example/@me", token: "t") : nil
        }
    }

    /// The row already knows a name and a picture, so the page opens drawn rather than empty and
    /// the server fills it in. A page that waited would flash blank on every press.
    @Test("It is drawn from what the row already knew, before anybody is asked")
    func seededFromTheRow() {
        let page = model(PersonDouble())
        #expect(page.name == "Tove")
        #expect(page.handle == "@tove@cedar.example")
        #expect(page.profile == nil)
    }

    @Test("What the server says replaces what the row knew")
    func serverFillsIn() async {
        let client = PersonDouble(profile: Profile(id: "10", authorId: "https://cedar.example/@tove",
                                                   name: "Tove Rasmussen", handle: "@tove@cedar.example",
                                                   followers: 89))
        let page = model(client)
        await page.read()

        #expect(page.name == "Tove Rasmussen")
        #expect(page.profile?.followers == 89)
        // Asked of the server that handed the post over, never of the reader's own.
        #expect(client.profileAsked == ["cedar.example"])
    }

    /// Once. Coming back to the page from a post opened out of it must not ask again.
    @Test("A second appearance asks nobody a second time")
    func readsOnce() async {
        let client = PersonDouble(profile: Profile(id: "10", authorId: "a", name: "T", handle: "@t@h"))
        let page = model(client)
        await page.read()
        await page.read()

        #expect(client.profileAsked.count == 1)
    }

    // MARK: - the two silences

    /// Nobody is signed in anywhere. There is no relationship to have, and the page says so —
    /// it does not say the reader is not following them, which would be an answer.
    @Test("With no account anywhere there is no answer, and none is invented")
    func noAccountMeansNoAnswer() async {
        let page = model(PersonDouble(profile: Profile(id: "10", authorId: "a", name: "T", handle: "@t@h")),
                         signedIn: false)
        await page.read()

        #expect(page.relationship == nil)
        #expect(!page.hasRelationship)
        // And the profile is there regardless: reading what somebody published needs nobody's
        // credential, which is why the page opens at all.
        #expect(page.profile != nil)
    }

    /// The reader's own server has never heard of them. The same shape on screen as above and a
    /// different fact, and the same shape as "not following" and a different fact again.
    @Test("A server that has never heard of them is not the reader not following them")
    func unknownIsNotNotFollowing() async {
        let page = model(PersonDouble(profile: Profile(id: "10", authorId: "a", name: "T", handle: "@t@h"),
                                      relationship: nil))
        await page.read()

        #expect(page.relationship == nil)
        #expect(!page.hasRelationship)
    }

    @Test("A relationship the server does have is what the page shows")
    func knownRelationship() async {
        let page = model(PersonDouble(profile: Profile(id: "10", authorId: "a", name: "T", handle: "@t@h"),
                                      relationship: Relationship(following: true, followedBy: true)))
        await page.read()

        #expect(page.hasRelationship)
        #expect(page.relationship?.following == true)
        #expect(page.relationship?.followedBy == true)
    }

    // MARK: - changing it

    /// A star moves first and goes back if refused, because the reader is the authority on it.
    /// This is not a star: whether somebody has accepted a follower is that somebody's answer,
    /// and it is read off the server rather than assumed from the press.
    @Test("A locked account answers asked, and the page does not say following")
    func lockedAccountIsNotClaimedAsFollowing() async {
        let client = PersonDouble(profile: Profile(id: "10", authorId: "a", name: "T", handle: "@t@h"),
                                  relationship: Relationship(),
                                  afterFollow: Relationship(requested: true))
        let page = model(client)
        await page.read()
        await page.setFollow(true)

        #expect(page.relationship?.requested == true)
        #expect(page.relationship?.following == false)
        // The control still reads as on, so pressing again withdraws rather than asking twice.
        #expect(page.relationship?.isOn == true)
    }

    @Test("A refused follow leaves the relationship as the server last had it")
    func refusedFollowChangesNothing() async {
        let client = PersonDouble(profile: Profile(id: "10", authorId: "a", name: "T", handle: "@t@h"),
                                  relationship: Relationship(following: false),
                                  refusing: true)
        let page = model(client)
        await page.read()
        await page.setFollow(true)

        #expect(page.relationship?.following == false)
        #expect(page.failure != nil)
    }

    @Test("Following with no account anywhere is refused before anything is sent")
    func followNeedsAnAccount() async {
        let client = PersonDouble(profile: Profile(id: "10", authorId: "a", name: "T", handle: "@t@h"))
        let page = model(client, signedIn: false)
        await page.setFollow(true)

        #expect(client.followsSent == 0)
        #expect(page.failure != nil)
    }
}

/// A source that answers about one person, and counts who was asked what.
final class PersonDouble: SourceClient, @unchecked Sendable {
    private let stored: Profile?
    private let related: Relationship?
    private let afterFollow: Relationship
    private let refusing: Bool

    /// Which hosts were asked for the profile, so a test can assert the page never reaches the
    /// person's own server.
    private(set) var profileAsked: [String] = []
    private(set) var followsSent = 0

    init(profile: Profile? = nil, relationship: Relationship? = nil,
         afterFollow: Relationship = Relationship(following: true), refusing: Bool = false) {
        self.stored = profile
        self.related = relationship
        self.afterFollow = afterFollow
        self.refusing = refusing
    }

    func profile(handle: String, host: String, token: String?) async throws -> Profile? {
        profileAsked.append(host)
        return stored
    }

    func posts(by id: String, host: String, limit: Int, before: Post?,
               token: String?) async throws -> [Post] { [] }

    func relationship(with handle: String, as account: ActingAccount) async throws -> Relationship? {
        related
    }

    func setFollow(_ following: Bool, with handle: String,
                   as account: ActingAccount) async throws -> Relationship {
        followsSent += 1
        if refusing { throw SourceFailure.http(422, Data()) }
        return following ? afterFollow : Relationship()
    }

    func instance(host: String) async throws -> InstanceInfo {
        InstanceInfo(host: host, title: host, summary: "")
    }
    func timeline(host: String, limit: Int, before: Post?, token: String?) async throws -> [Post] { [] }
    func home(host: String, limit: Int, before: Post?, token: String) async throws -> [Post] { [] }
    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }
    func context(of post: Post, host: String, token: String?) async throws -> Conversation {
        Conversation(post: post)
    }
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }
}
