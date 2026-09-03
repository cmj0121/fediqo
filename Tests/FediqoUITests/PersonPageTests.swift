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

    private func model(_ client: PersonDouble, signedIn: Bool = true,
                       changed: Counter? = nil) -> PersonModel {
        PersonModel(subject: PersonSubject(post: post()), client: client) {
            signedIn ? ActingAccount(host: "birch.example",
                                     authorId: "https://birch.example/@me", token: "t") : nil
        } changed: {
            changed?.bump()
        }
    }


    // MARK: - the ring, on somebody's page (#94)

    /// Three of theirs, so the ring has somewhere to go.
    private func wrote(_ ids: [String], on host: String = "cedar.example") -> [Post] {
        ids.map { id in
            Post(uri: "https://\(host)/api/v1/statuses/\(id)", socialProtocol: .mastodon,
                 sourceURL: "https://\(host)", createdAt: Date(timeIntervalSince1970: 100),
                 authorId: "https://\(host)/@tove", authorName: "Tove",
                 authorHandle: "@tove@\(host)", text: id)
        }
    }

    private func read(_ posts: [Post]) async -> PersonModel {
        let page = model(PersonDouble(profile: Profile(id: "10", authorId: "https://cedar.example/@tove",
                                                       name: "Tove", handle: "@tove@cedar.example"),
                                      wrote: posts))
        await page.read()
        return page
    }

    /// The whole of the issue: the keys work here, and they are the same keys.
    @Test("j and k move through what somebody wrote")
    func theRingMovesOnTheirPage() async {
        let page = await read(wrote(["a", "b", "c"]))

        #expect(page.place.moveSelection(by: 1))
        #expect(page.place.selectedPost?.text == "a")
        #expect(page.place.moveSelection(by: 1))
        #expect(page.place.selectedPost?.text == "b")
        #expect(page.place.moveSelection(by: -1))
        #expect(page.place.selectedPost?.text == "a")
    }

    /// The same ring and therefore the same rule, which is why it is the same object: `k` at the
    /// top stops rather than throwing the reader to the oldest post there is.
    @Test("It stops at the top rather than wrapping")
    func itStopsAtTheTop() async {
        let page = await read(wrote(["a", "b"]))

        #expect(page.place.moveSelection(by: 1))
        #expect(!page.place.moveSelection(by: -1))
        #expect(page.place.selectedPost?.text == "a")
    }

    /// Their page is theirs. The reader's two switches are what they want their *timeline* to be,
    /// and a page showing eleven of somebody's nineteen posts because eight were boosts would be
    /// this app deciding what somebody's page is.
    @Test("Their own posts are not filtered by the reader's timeline switches")
    func theirPageIsNotFiltered() async {
        let page = await read(wrote(["a", "b", "c"]))
        #expect(page.ringRows().posts.count == 3)
        #expect(page.landable(wrote(["d"])).count == 1)
    }

    /// A page with nobody's posts on it has nowhere for the ring to go, and says so rather than
    /// claiming to have moved.
    @Test("A press on an empty page moves nothing")
    func nothingToMoveThrough() async {
        let page = await read([])
        #expect(!page.place.moveSelection(by: 1))
        #expect(page.place.selectedPost == nil)
    }

    /// Opening somebody else starts a page of their own, and a ring on somebody else's post is
    /// not carried onto it.
    @Test("A new page does not open holding the last one's ring")
    func eachPageHasItsOwnRing() async {
        let first = await read(wrote(["a", "b"]))
        #expect(first.place.moveSelection(by: 1))

        let second = await read(wrote(["x", "y"]))
        #expect(second.place.selectedPost == nil)
    }


    /// The routing, which is where a second ring would have gone wrong first. A page about
    /// somebody stands over the timeline, and the keys belong to what is in front of the reader
    /// — moving the ring in the list behind it would be moving something they cannot see.
    @Test("With a page open, the keys move that page's ring and not the timeline's")
    @MainActor
    func theKeysGoToWhatIsInFront() async throws {
        let posts = wrote(["a", "b", "c"])
        let app = try await signedInApp("person-ring", posts: posts,
                                        client: PersonDouble(
                                            profile: Profile(id: "10",
                                                             authorId: "https://cedar.example/@tove",
                                                             name: "Tove",
                                                             handle: "@tove@cedar.example"),
                                            wrote: posts),
                                        host: "cedar.example")
        // The reader is on the second post in the timeline before they open anybody.
        #expect(app.presses("j"))
        #expect(app.presses("j"))
        let behind = app.feed(for: .publicFixture).place.selection

        app.openPerson(of: posts[0])
        let page = try #require(app.person)
        await page.read()

        #expect(app.presses("j"))
        #expect(page.place.selectedPost?.text == "a")
        // And the list behind it did not move under them.
        #expect(app.feed(for: .publicFixture).place.selection == behind)
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

    /// The complaint #88 opens with, arriving one step later: `loadIfNeeded` re-asks only when
    /// the servers differ, and following somebody changes nothing about the servers and
    /// everything about what they will say. Without this the reader follows their first person,
    /// goes to Home, and is shown the empty page all over again.
    @Test("A follow that landed says home is no longer answered")
    func aLandedFollowStalesHome() async {
        let counter = Counter()
        let client = PersonDouble(profile: Profile(id: "10", authorId: "a", name: "T", handle: "@t@h"),
                                  relationship: Relationship())
        let page = model(client, changed: counter)
        await page.read()
        await page.setFollow(true)

        #expect(counter.count == 1)
    }

    /// And the other way round, which is the same fact: a home still holding somebody the reader
    /// has just let go is as wrong as one that never gained them.
    @Test("So does an unfollow that landed")
    func anUnfollowStalesHomeToo() async {
        let counter = Counter()
        let client = PersonDouble(profile: Profile(id: "10", authorId: "a", name: "T", handle: "@t@h"),
                                  relationship: Relationship(following: true))
        let page = model(client, changed: counter)
        await page.read()
        await page.setFollow(false)

        #expect(counter.count == 1)
    }

    /// A press the server refused changed nothing, so nothing about home changed either. Telling
    /// it otherwise would spend a round of requests on every failed press.
    @Test("A refused follow says nothing about home")
    func refusedFollowLeavesHomeAlone() async {
        let counter = Counter()
        let client = PersonDouble(profile: Profile(id: "10", authorId: "a", name: "T", handle: "@t@h"),
                                  relationship: Relationship(), refusing: true)
        let page = model(client, changed: counter)
        await page.read()
        await page.setFollow(true)

        #expect(counter.count == 0)
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

/// How many times something was said, for the callbacks that have no other evidence.
@MainActor
final class Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// A source that answers about one person, and counts who was asked what.
final class PersonDouble: SourceClient, @unchecked Sendable {
    private let stored: Profile?
    /// What this person has written, for the ring to move over (#94).
    private let wrote: [Post]
    private let related: Relationship?
    private let afterFollow: Relationship
    private let refusing: Bool

    /// Which hosts were asked for the profile, so a test can assert the page never reaches the
    /// person's own server.
    private(set) var profileAsked: [String] = []
    private(set) var followsSent = 0

    init(profile: Profile? = nil, relationship: Relationship? = nil,
         afterFollow: Relationship = Relationship(following: true), refusing: Bool = false,
         wrote: [Post] = []) {
        self.wrote = wrote
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
               token: String?) async throws -> [Post] { wrote }

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
    func timeline(host: String, limit: Int, before: Post?, after: Post?, token: String?) async throws -> [Post] { [] }
    func home(host: String, limit: Int, before: Post?, after: Post?, token: String) async throws -> [Post] { [] }
    func trending(host: String, limit: Int, token: String?) async throws -> [Post] { [] }
    func context(of post: Post, host: String, token: String?) async throws -> Conversation {
        Conversation(post: post)
    }
    func stillHas(_ post: Post, host: String, token: String?) async throws -> Bool { true }
}

/// What a row says a post answers, and which account a reply goes as (#87).
@Suite("A reply says who, and as whom")
@MainActor
struct ReplySaysWhoTests {
    private func post(_ id: String, answering handle: String? = nil,
                      inReplyTo parent: String? = nil) -> Post {
        Post(uri: "https://one.example/api/v1/statuses/\(id)", socialProtocol: .mastodon,
             sourceURL: "https://one.example", createdAt: Date(timeIntervalSince1970: 100),
             authorId: "https://one.example/@\(id)", authorName: id.capitalized,
             authorHandle: "@\(id)@one.example", text: id,
             inReplyToURI: parent, answering: handle)
    }

    /// The parent in the same list is the most certain answer there is, so it still wins.
    @Test("A parent on the screen is who the row names")
    func theParentOnScreenWins() {
        let parent = post("tove")
        let reply = post("ines", answering: "@somebody@else.example", inReplyTo: parent.uri)

        #expect(FeedScreen.answering(reply, among: [parent, reply])
                == .handle("@tove@one.example"))
    }

    /// **The case this is for.** The post it answers is on a server the reader has not joined,
    /// so it is not in the list and never will be — and the reply itself carries the answer.
    @Test("A reply from elsewhere names whom it answers")
    func areplyFromElsewhereNamesWhom() {
        let reply = post("ines", answering: "@wren@alder.example",
                         inReplyTo: "https://alder.example/api/v1/statuses/8")

        #expect(FeedScreen.answering(reply, among: [reply]) == .handle("@wren@alder.example"))
    }

    /// And where nothing says who, the row says it is an answer and stops there rather than
    /// inventing whose.
    @Test("With nothing to go on, the row says it is an answer and no more")
    func nothingToGoOn() {
        let reply = post("ines", inReplyTo: "https://alder.example/api/v1/statuses/8")
        #expect(FeedScreen.answering(reply, among: [reply]) == .somebody)

        let plain = post("ines")
        #expect(FeedScreen.answering(plain, among: [plain]) == .nothing)
    }

    /// An empty handle is a server that sent something useless, not somebody with no name.
    @Test("An empty handle is nothing to name")
    func anemptyHandleNamesNobody() {
        let reply = post("ines", answering: "",
                         inReplyTo: "https://alder.example/api/v1/statuses/8")
        #expect(FeedScreen.answering(reply, among: [reply]) == .somebody)
    }
}
