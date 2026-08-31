import Foundation
import Testing
@testable import FediqoCore

/// Finding a post on the server that is about to be asked to do something to it.
///
/// The one step between a reader pressing a star and the write going out, and the step that
/// used to swallow the press: a post on the reader's own server was looked up through
/// `/api/v2/search`, which cannot answer about one, and the honest-sounding refusal that came
/// back said the server had never heard of a post it had written itself.
@Suite("Finding a post on the acting server")
struct MastodonWritesTests {
    private var client: MastodonClient {
        MastodonClient(session: stubbedSession())
    }

    private func acting(on host: String) -> ActingAccount {
        ActingAccount(host: host, authorId: "https://\(host)/users/ada", token: "t")
    }

    /// The bug, named: the reader's own server hands over a post, the reader stars it, and
    /// nothing is looked up — because the number to send is already in the address that
    /// server gave the post.
    ///
    /// `paths(for:)` being empty of a search is the whole assertion. A lookup sent here is a
    /// lookup that comes back empty on every stock Mastodon, and an empty one is refused.
    @Test("A post the acting server handed over needs no lookup at all")
    func ownPostIsNotLookedUp() async throws {
        let host = "writes-own.test"
        let post = handedOver("42", from: host)

        let found = try await client.localId(of: post, as: acting(on: host), fetching: false)

        #expect(found.id == "42")
        #expect(found.reach == .alreadyThere)
        #expect(stubRoutes.paths(for: host).isEmpty)
    }

    /// The other way a post can be the acting server's: written there, and read here through
    /// somebody else's timeline. The canonical address carries that server's own number, so
    /// the relay's number for its own copy is never the one sent.
    @Test("A post written on the acting server is found by its canonical address, not a relay's")
    func ownPostArrivingByRelay() async throws {
        let mine = "writes-mine.test"
        let relay = "writes-relay.test"
        let post = handedOver("999", from: relay, authority: mine)

        let found = try await client.localId(of: post, as: acting(on: mine), fetching: false)

        #expect(found.id == "999")           // the number on my server, out of the canonical URI
        #expect(found.reach == .alreadyThere)
        #expect(stubRoutes.paths(for: mine).isEmpty)
        #expect(stubRoutes.paths(for: relay).isEmpty)
    }

    /// A boost row carries the wrapper's number, and that is what gets sent. Mastodon carries
    /// a favourite aimed at a reblog through to the status it reblogged, so the star lands on
    /// the post — sending the wrapper is right, not a near miss.
    @Test("A boost the acting server handed over is acted on by the boost's own number")
    func boostUsesTheWrapper() async throws {
        let host = "writes-boost.test"
        let elsewhere = "writes-author.test"
        let post = makePost(uri: "https://\(host)/api/v1/statuses/700",
                            originURI: "https://\(elsewhere)/users/a/statuses/12",
                            at: 1, from: host, boostedBy: "ada")

        let found = try await client.localId(of: post, as: acting(on: host), fetching: false)

        #expect(found.id == "700")
        #expect(found.reach == .alreadyThere)
    }

    /// The star still goes out, and it goes out against the number the short circuit found.
    @Test("The write is sent against the id read out of the address")
    func theWriteGoesOut() async throws {
        let host = "writes-star.test"
        let post = handedOver("42", from: host)
        stubRoutes.on(host, "/api/v1/statuses/42/favourite", status: 200, body: "{}")

        let account = acting(on: host)
        let found = try await client.localId(of: post, as: account, fetching: false)
        try await client.setMark(.favourite, on: found.id, as: account, done: true)

        #expect(stubRoutes.paths(for: host) == ["/api/v1/statuses/42/favourite"])
        #expect(stubRoutes.requests(for: host, "/api/v1/statuses/42/favourite").first?.method == "POST")
    }

    /// The write's own answer is a whole status, and the numbers in it are the numbers with
    /// this press counted in. Reading them costs nothing — the request was made anyway — and
    /// it is the only way this app's counts move without inventing one.
    @Test("What the write answered is read back: the marks, and the numbers with it counted in")
    func theAnswerIsKept() async throws {
        let host = "writes-answer.test"
        let post = handedOver("42", from: host)
        stubRoutes.on(host, "/api/v1/statuses/42/favourite", status: 200, body: """
        {"id": "42", "favourited": true, "reblogged": false,
         "replies_count": 2, "reblogs_count": 0, "favourites_count": 8}
        """)

        let marked = try await client.setMark(.favourite, on: "42", as: acting(on: host), done: true)

        #expect(marked.marks.favourited == true)
        #expect(marked.marks.reblogged == false)
        #expect(marked.marks.bookmarked == nil)     // never told, which is not "no"
        #expect(marked.counts?.favourites == 8)
        #expect(marked.counts?.replies == 2)
    }

    /// A boost's answer is the reblog it just made, with the original underneath it. The
    /// numbers that moved are the original's, and so is every mark — Mastodon carries an act
    /// aimed at a reblog through to what it reblogged and says so in the same place.
    @Test("A boost's answer is read off the status it wrapped, not off the wrapper")
    func aBoostAnswersAboutTheOriginal() async throws {
        let host = "writes-boosted.test"
        stubRoutes.on(host, "/api/v1/statuses/700/reblog", status: 200, body: """
        {"id": "701", "favourites_count": 0, "reblogs_count": 0,
         "reblog": {"id": "700", "reblogged": true, "favourited": true,
                    "reblogs_count": 4, "favourites_count": 9}}
        """)

        let marked = try await client.setMark(.reblog, on: "700", as: acting(on: host), done: true)

        #expect(marked.marks.reblogged == true)
        #expect(marked.marks.favourited == true)
        #expect(marked.counts?.reblogs == 4)
        #expect(marked.counts?.favourites == 9)
    }

    /// An answer with no numbers in it is not an error and not a zero. The write happened,
    /// which is what was asked for; nobody said what the count is now, so nothing is claimed
    /// and the screen goes on showing the number the post arrived with.
    @Test("An answer that says nothing about the numbers claims nothing")
    func anAnswerWithNoNumbers() async throws {
        let host = "writes-quiet.test"
        stubRoutes.on(host, "/api/v1/statuses/42/bookmark", status: 200, body: #"{"id": "42"}"#)

        let marked = try await client.setMark(.bookmark, on: "42", as: acting(on: host), done: true)

        #expect(marked.counts == nil)
        #expect(marked.marks.areKnown == false)
    }

    /// Somebody else's post is the case the lookup is for — and the refusal comes before it,
    /// because the only search Mastodon can answer is the one that fetches.
    @Test("Without leave to fetch, somebody else's post is refused before anything is sent")
    func strangersPostIsRefusedWithoutSending() async throws {
        let mine = "writes-refuse.test"
        let theirs = "writes-theirs.test"
        let post = handedOver("5", from: theirs, authority: theirs)

        await #expect(throws: SourceFailure.notItsPost("https://\(theirs)/users/a/statuses/5")) {
            try await client.localId(of: post, as: acting(on: mine), fetching: false)
        }
        #expect(stubRoutes.paths(for: mine).isEmpty)
    }

    /// With leave, one search goes out, and it resolves. `resolve=false` is not sent first:
    /// Mastodon reads a query as an address only when resolving, so the extra request was one
    /// that could never answer.
    @Test("With leave, one resolving search goes out and what it saw is kept")
    func strangersPostIsResolved() async throws {
        let mine = "writes-resolve.test"
        let theirs = "writes-far.test"
        let post = handedOver("5", from: theirs, authority: theirs)
        stubRoutes.on(mine, "/api/v2/search", status: 200, body: """
        {"statuses": [{"id": "88", "favourited": true, "bookmarked": false}]}
        """)

        let found = try await client.localId(of: post, as: acting(on: mine), fetching: true)

        #expect(found.id == "88")
        #expect(found.reach == .fetched)
        #expect(found.marks.favourited == true)
        #expect(found.marks.bookmarked == false)
        #expect(found.marks.reblogged == nil)      // never told, which is not "no"

        let sent = stubRoutes.requests(for: mine, "/api/v2/search")
        #expect(sent.count == 1)
        #expect(sent.first?.query["resolve"] == "true")
        #expect(sent.first?.query["q"] == "https://\(theirs)/users/a/statuses/5")
        #expect(sent.first?.query["type"] == "statuses")
    }

    /// A search that comes back with nothing is still a refusal, and it says so as the post's
    /// canonical address rather than as the relay's copy.
    @Test("A resolving search that finds nothing is refused by the post's canonical address")
    func resolvedToNothing() async throws {
        let mine = "writes-empty.test"
        let theirs = "writes-gone.test"
        let post = handedOver("5", from: theirs, authority: theirs)
        stubRoutes.on(mine, "/api/v2/search", status: 200, body: #"{"statuses": []}"#)

        await #expect(throws: SourceFailure.notItsPost("https://\(theirs)/users/a/statuses/5")) {
            try await client.localId(of: post, as: acting(on: mine), fetching: true)
        }
    }
}
