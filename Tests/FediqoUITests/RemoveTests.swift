import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Remove, which is the act `ShellSession.clear`'s comment named and left unbuilt: "there is no
/// such button yet; when there is, it takes the source, its boards and its notes together, because
/// that is one decision and this is another."
///
/// Three things are pinned here that nothing else can pin. That Remove **subsumes** Clear, because
/// a reader who has stopped reading a server has stopped reading it in every cache too. That the
/// store is emptied **before** the caches, because a cleared cache announces itself and a row still
/// on screen would answer by asking the deleted host again. And that a note two servers both carry
/// survives the first Remove — decision 9, seen from the screen rather than from the store.
@MainActor
@Suite("Removing a server")
struct RemoveTests {
    private let alpha = "alpha.test"
    private let beta = "beta.test"
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    init() {
        L10n.language = .english
    }

    /// Somewhere a `@Sendable` observation callback can leave a reading. The shape `ClearTests`
    /// established, for the same reason: `withObservationTracking` cannot write to a local.
    private final class Reading: @unchecked Sendable {
        var sourcesWhenCleared: Int?
        var notesWhenCleared: Int?
    }

    nonisolated private func address(_ name: String) -> URL {
        URL(string: "https://cdn.example.test/\(name)")!
    }

    private func key(_ name: String) -> ShellPictures.Key {
        ShellPictures.Key(url: address(name), scale: 2, tier: .deck)
    }

    nonisolated private func emoji(_ shortcode: String) -> CustomEmoji {
        CustomEmoji(shortcode: shortcode, url: address("\(shortcode).gif"), staticURL: nil)
    }

    private func emojiClient() -> FixtureHTTP {
        FixtureHTTP(["/wave.gif": .body(EmojiFixture.gif(delays: [0.1, 0.1]))])
    }

    private func note(_ id: String, from source: Source) -> Note {
        Note(
            id: id,
            source: source,
            author: "Ada",
            handle: "@ada@\(source.host)",
            body: "hello",
            postedAt: origin,
            categories: [.public]
        )
    }

    /// The store filled and the session brought level with it — the same three lines `adopt()`
    /// runs, so a test seeded this way starts where a finished join leaves the reader.
    private func seed(_ session: ShellSession, sources: [Source], notes: [Note]) async {
        for source in sources { await session.store.add(source) }
        await session.store.ingest(notes)
        session.sources = await session.store.sources()
        session.notes = await session.store.all()
        session.rebuildQueries()
    }

    /// One server holding all three kinds this device can hold of a server.
    private func loaded(
        _ session: ShellSession, host: String, pictures: ShellPictures, emojis: EmojiCache
    ) async {
        let registered = [emoji("wave")]
        await session.emoji.refresh(host: host) { registered }
        await session.emoji.settle(host: host)
        await emojis.fetch(EmojiCache.Request(
            emojis: registered, metrics: .init(side: 20, baseline: -4), scale: 2, host: host,
            still: false
        ))
        pictures.keep(
            Image(systemName: "photo"), cost: 4096, for: key("\(host)-avatar.png"),
            startedAt: 0, hosts: [host]
        )
    }

    // MARK: - What goes

    /// The three things Clear deliberately keeps, plus the four it takes. Clear's promise is that
    /// what goes comes back, because the reader is still reading the server; Remove withdraws that
    /// premise, so a Remove that emptied the store and left a cache and a forum session behind
    /// would be holding this device's copy of a server the reader said to let go of.
    @Test("Remove takes the source, its boards, its notes and everything Clear would have taken")
    func removeTakesEverythingAndSubsumesClear() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        let emojis = EmojiCache(http: emojiClient())
        let session = ShellSession(http: FixtureHTTP(), pictures: pictures, emojis: emojis)
        let forum = Source(
            host: alpha, kind: .discuz, boards: [BoardSubscription(fid: 33, name: "a")])
        await seed(session, sources: [forum], notes: [note("thread-1", from: forum)])
        await loaded(session, host: alpha, pictures: pictures, emojis: emojis)

        // The premise, stated rather than assumed: a Remove that started with nothing measures
        // nothing at all.
        #expect(session.queries.map(\.id) == ["all", "trends"])
        #expect(await session.emoji.catalogue(host: alpha)?.count == 1)
        #expect(pictures.holding(host: alpha).count == 1)

        await session.remove(host: alpha)

        #expect(session.sources.isEmpty)
        #expect(session.notes.isEmpty)
        #expect(session.queries.isEmpty, "the board's tab outlived the board")
        #expect(session.timelineID == nil)
        #expect(await session.store.sources().isEmpty, "the session forgot it and the store did not")
        #expect(await session.emoji.catalogue(host: alpha) == nil)
        #expect(emojis.holding(host: alpha).count == 0)
        #expect(pictures.holding(host: alpha).count == 0)
        #expect(session.cleared == 1, "Remove did not press Clear")
    }

    /// The host is folded on the way in, as it is everywhere else this app keys by server.
    @Test("Remove finds the server whatever case the row was drawn in")
    func removeFoldsTheHost() async {
        let session = ShellSession(http: FixtureHTTP(), pictures: ShellPictures(http: FixtureHTTP()))
        let source = Source(host: alpha, kind: .mastodon)
        await seed(session, sources: [source], notes: [note("one", from: source)])

        await session.remove(host: "ALPHA.Test")

        #expect(session.sources.isEmpty)
        #expect(session.notes.isEmpty)
    }

    @Test("Removing one server leaves the other standing, with its tabs")
    func removingOneLeavesTheOther() async {
        let session = ShellSession(http: FixtureHTTP(), pictures: ShellPictures(http: FixtureHTTP()))
        let one = Source(host: alpha, kind: .mastodon)
        let two = Source(host: beta, kind: .discourse)
        await seed(
            session, sources: [one, two],
            notes: [note("one", from: one), note("two", from: two)]
        )

        await session.remove(host: alpha)

        #expect(session.sources.map(\.host) == [beta])
        #expect(session.notes.map(\.id) == ["two"])
        // A forum has no Trends, so the rail loses that tab with the microblog that had it.
        #expect(session.queries.map(\.id) == ["all"])
        #expect(session.timelineID == .all)
    }

    // MARK: - #10 two sources, two rows

    @Test("A status two instances carry is two rows, and Remove takes only that instance's row")
    func aSharedStatusSurvivesTheFirstRemove() async {
        let session = ShellSession(http: FixtureHTTP(), pictures: ShellPictures(http: FixtureHTTP()))
        let one = Source(host: alpha, kind: .mastodon)
        let two = Source(host: beta, kind: .mastodon)
        let uri = "https://origin.example/users/ada/statuses/1"
        await seed(
            session, sources: [one, two],
            notes: [note(uri, from: one), note(uri, from: two), note("only-beta", from: two)]
        )
        #expect(session.notes.count == 3)
        #expect(session.notes.filter { $0.id == uri }.count == 2)

        await session.remove(host: alpha)

        let left = session.notes.filter { $0.id == uri }
        #expect(left.map(\.source.host) == [beta])
        #expect(session.notes.contains { $0.id == "only-beta" })

        await session.remove(host: beta)

        #expect(session.notes.isEmpty)
    }

    /// **After Remove, nothing this device fetches is addressed to the removed server.**
    ///
    /// Every avatar and emoji request a row makes is tagged with `item.source.host` — `DummyItemRow`
    /// reads it at three places and `FediqoRootView` at two — so the set of every row's host is the
    /// whole of what a fetch can be addressed to, and a set without the removed host is the
    /// property itself rather than a sample of it. Driven through `items(from:)`, which is
    /// the call both screens make: a pin on `ItemStore` alone would pass with the wiring
    /// disconnected.
    @Test("After Remove, no fetch this device can make is addressed to the server that went")
    func nothingIsStillFetchedFromARemovedServer() async {
        let session = ShellSession(http: FixtureHTTP(), pictures: ShellPictures(http: FixtureHTTP()))
        let one = Source(host: alpha, kind: .mastodon)
        let two = Source(host: beta, kind: .mastodon)
        let uri = "https://origin.example/users/ada/statuses/1"
        await seed(
            session, sources: [one, two],
            notes: [note(uri, from: one), note(uri, from: two), note("only-beta", from: two)]
        )

        let before = TimelineQuery.all.items(from: session.notes, latest: nil)
        #expect(before.contains { $0.source.host == alpha })
        #expect(before.contains { $0.source.host == beta })

        await session.remove(host: alpha)

        let after = TimelineQuery.all.items(from: session.notes, latest: nil)
        let addressable = Set(after.map(\.source.host))
        #expect(!addressable.contains(alpha))
        #expect(addressable == [beta])
    }

    /// A post two servers carry was one row each until #114; it is one row now, naming both, and
    /// each copy under it is still drawn in the shape of the server it came through.
    @Test("A post two servers carry is one row, and each copy keeps the shape of its server")
    func aSharedPostIsOneRowOfEachServersCopies() async {
        let session = ShellSession(http: FixtureHTTP(), pictures: ShellPictures(http: FixtureHTTP()))
        let micro = Source(host: alpha, kind: .mastodon)
        let forum = Source(host: beta, kind: .discourse)
        let uri = "https://origin.example/users/ada/statuses/1"
        await seed(
            session, sources: [micro, forum],
            notes: [note(uri, from: micro), note(uri, from: forum)]
        )

        let items = TimelineQuery.all.items(from: session.notes, latest: nil)
        #expect(items.count == 1)
        let copies = items.first?.copies ?? []
        #expect(Set(copies.map(\.source.host)) == [alpha, beta])
        #expect(copies.first { $0.source.host == alpha }?.source.kind == .microblog)
        #expect(copies.first { $0.source.host == beta }?.source.kind == .forum)
    }

    // MARK: - The order

    /// **The cache-ordering rule, and the only thing that can catch it breaking.**
    ///
    /// `clear` bumps `ShellPictures`' generation, and that bump's documented contract is that a row
    /// still on screen asks again immediately — see `ShellPictures`, "What Clear means". That is
    /// right for Clear, where the reader is still reading the server, and it is exactly wrong for
    /// Remove: clearing before `adopt()` has taken the rows out of the list would aim a burst of
    /// avatar and emoji requests at the host the reader has just deleted, and every assertion about
    /// the end state would still pass.
    ///
    /// So this reads the session **at the instant the bump lands**, which is the one moment the
    /// order is visible from outside.
    @Test("The store is emptied before the caches announce themselves")
    func theStoreGoesBeforeTheCaches() async {
        let pictures = ShellPictures(http: FixtureHTTP())
        let session = ShellSession(http: FixtureHTTP(), pictures: pictures)
        let source = Source(host: alpha, kind: .mastodon)
        await seed(session, sources: [source], notes: [note("one", from: source), note("two", from: source)])
        #expect(session.notes.count == 2)

        let reading = Reading()
        withObservationTracking {
            _ = pictures.generation
        } onChange: {
            // Every one of these objects is main-actor-isolated and the bump happens on the main
            // actor inside `clear`, so this is the session as `pictures.forget` found it.
            MainActor.assumeIsolated {
                reading.sourcesWhenCleared = session.sources.count
                reading.notesWhenCleared = session.notes.count
            }
        }

        await session.remove(host: alpha)

        #expect(reading.notesWhenCleared != nil, """
            The picture cache was never told, so this measured nothing. `clear` bumps the \
            generation unconditionally and Remove calls `clear`; if that stopped being true the \
            ordering rule stopped being enforced here.
            """)
        #expect(reading.sourcesWhenCleared == 0 && reading.notesWhenCleared == 0, """
            The caches were cleared while the rows were still in the list. The generation bump \
            tells every RemoteImage on screen to ask again, so those rows would have re-fetched \
            avatars and emoji from the host the reader has just removed. `store.remove` and \
            `adopt()` both have to finish before `clear(host:)` is called.
            """)
    }

    // MARK: - What the errand leaves behind

    /// A refusal, an offered sign-in, a list of unread boards and the pause that asks which boards
    /// to read are all sentences about one host. Removing that host takes the sentences with it.
    @Test("Remove clears the session state that still names the server")
    func removeClearsWhatStillNamesThatHost() async {
        let session = ShellSession(http: FixtureHTTP(), pictures: ShellPictures(http: FixtureHTTP()))
        let source = Source(host: alpha, kind: .discuz)
        await seed(session, sources: [source], notes: [])
        session.progressHost = alpha
        session.refuse = "something about alpha"
        session.offerSignIn = alpha
        session.unread = [UnreadBoard(board: DiscuzBoard(fid: 3, name: "a", category: "c", gid: 1), error: .unreachable)]
        session.unreadAll = 4
        session.stage = .choosingBoards(
            JoinOffer(host: alpha, kind: .discuz, categories: []),
            from: .preview(
                SourcePreview(host: alpha, kind: .discuz, profile: .silent(host: alpha, kind: .discuz)),
                ticked: []
            )
        )
        session.signingIn = ForumSignInRequest(host: alpha, stop: .noCredential)

        await session.remove(host: alpha)

        #expect(session.refuse == nil)
        #expect(session.offerSignIn == nil)
        #expect(session.unread.isEmpty)
        #expect(session.unreadAll == 0)
        #expect(session.progressHost == "")
        #expect(session.choosing == nil, "the picker was still open over a server that is gone")
        // `signIn` sets `signingIn` *after* `await forums.signIn(host:)`, and that await is the
        // window a Remove is pressable in — so a sheet holding somebody else's login page can
        // outlive the server it belongs to, and would be asking the reader to sign in to nothing.
        #expect(session.signingIn == nil, "the sign-in sheet was left up over a server that is gone")
    }

    /// The other half, and the reason the errand fields are gated on `progressHost` rather than
    /// wiped: a reader who removes one server is still owed the sentence about a different one.
    @Test("Remove leaves another server's sentences where they are")
    func removeLeavesAnotherServersSentencesAlone() async {
        let session = ShellSession(http: FixtureHTTP(), pictures: ShellPictures(http: FixtureHTTP()))
        let one = Source(host: alpha, kind: .mastodon)
        let two = Source(host: beta, kind: .discuz)
        await seed(session, sources: [one, two], notes: [])
        session.progressHost = beta
        session.refuse = "something about beta"
        session.offerSignIn = beta
        session.unreadAll = 4
        session.stage = .choosingBoards(
            JoinOffer(host: beta, kind: .discuz, categories: []),
            from: .preview(
                SourcePreview(host: beta, kind: .discuz, profile: .silent(host: beta, kind: .discuz)),
                ticked: []
            )
        )
        session.signingIn = ForumSignInRequest(host: beta, stop: .noCredential)

        await session.remove(host: alpha)

        #expect(session.refuse == "something about beta")
        #expect(session.offerSignIn == beta)
        #expect(session.unreadAll == 4)
        #expect(session.progressHost == beta)
        #expect(session.choosing?.offer.host == beta)
        #expect(session.signingIn?.host == beta, "a sign-in to a different forum was torn down")
    }

    // MARK: - The question before the press

    /// **Nothing is destroyed while the question is up.** Remove takes the board picks the reader
    /// made, and `clear`'s comment is the argument for asking first: pictures come back by
    /// themselves and a pick of eight boards out of forty does not.
    @Test("Pressing Remove asks, and destroys nothing until it is answered")
    func theQuestionDestroysNothing() async {
        let session = ShellSession(http: FixtureHTTP(), pictures: ShellPictures(http: FixtureHTTP()))
        let source = Source(host: alpha, kind: .mastodon)
        await seed(session, sources: [source], notes: [note("one", from: source)])
        #expect(session.removing == nil)

        session.removing = alpha
        #expect(session.sources.map(\.host) == [alpha])
        #expect(session.notes.count == 1)
        #expect(session.cleared == 0, "the question cleared a cache")

        // Cancel is a complete undo, because nothing happened.
        session.removing = nil
        #expect(session.sources.map(\.host) == [alpha])

        session.removing = alpha
        await session.remove(host: alpha)
        #expect(session.removing == nil, "the dialog would still be asking about a server that is gone")
        #expect(session.sources.isEmpty)
    }

    /// The message names the boards only where there are boards to name. Two whole sentences and
    /// two keys, because "the 3 boards you picked" must never appear over a microblog and a clause
    /// glued on with `+` is a clause no translator can put first.
    @Test("The question names the boards it is about to take, and only then")
    func theQuestionNamesTheBoards() {
        let microblog = Source(host: alpha, kind: .mastodon)
        let forum = Source(
            host: beta, kind: .discuz,
            boards: [BoardSubscription(fid: 1, name: "a"), BoardSubscription(fid: 2, name: "b")]
        )
        let sources = [microblog, forum]

        #expect(
            FediqoRootView.removeDetail(for: alpha, in: sources)
                == L10n.t("account.remove.detail", language: .english)
        )
        #expect(
            FediqoRootView.removeDetail(for: beta, in: sources)
                == String(format: L10n.t("account.remove.detail.boards", language: .english), 2)
        )
        // A host with no row left — the list moved under the dialog — still gets a true sentence
        // rather than a claim about boards nobody can count.
        #expect(
            FediqoRootView.removeDetail(for: "gone.test", in: sources)
                == L10n.t("account.remove.detail", language: .english)
        )
        #expect(L10n.t("account.remove.title", language: .english).contains("%@"))
        #expect(!L10n.t("account.remove.confirm", language: .english).isEmpty)
    }
}
