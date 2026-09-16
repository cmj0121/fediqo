import Foundation
import Testing

@testable import FediqoCore

/// Adding a forum: what the reader's button actually calls, and what it does with each answer.
@Suite("Forum join")
struct ForumJoinTests {
    private static func forumHTTP(
        latest: FixtureHTTP.Outcome = .body(Fixtures.json("discourse-latest"))
    ) -> FixtureHTTP {
        FixtureHTTP([
            "/": .body(Fixtures.html("discourse")),
            "/latest.json": latest,
            "/site.json": .body(Fixtures.json("discourse-site")),
        ])
    }

    @Test("A forum is detected, read, and added with its topics in the store")
    func aForumJoins() async throws {
        let store = ItemStore()
        let http = Self.forumHTTP()
        try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
            .join(host: "install-f.example")

        let sources = await store.sources()
        #expect(sources.map(\.host) == ["install-f.example"])
        // The source carries what the host actually speaks, because that is what decides the
        // shape of the row — a forum is drawn as a thread, a microblog as a note.
        #expect(sources.first?.kind == .discourse)

        let notes = await store.all()
        #expect(notes.count == 3)
        #expect(notes.allSatisfy { $0.title?.isEmpty == false })
        #expect(notes.contains { $0.board == "Ideas" })
    }

    @Test("The host is asked what it speaks once, not once per protocol")
    func theHostIsAskedOnce() async throws {
        let store = ItemStore()
        let http = Self.forumHTTP()
        try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
            .join(host: "install-f.example")

        // The front page is read once for the detector and never again. A dispatcher that let
        // each protocol re-detect would double this against every server, for nothing.
        #expect(await http.paths.filter { $0 == "/" }.count == 1)
        #expect(await Set(http.paths) == ["/", "/latest.json", "/site.json"])
    }

    @Test("A forum that answers the detector and then refuses is not left behind as a source")
    func aRefusedForumIsNotAdded() async throws {
        let store = ItemStore()
        let http = Self.forumHTTP(latest: .text("<html>checking your browser</html>", status: 403))

        await #expect(throws: JoinError.refused(403)) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "install-f.example")
        }

        // Nothing added. A source in the list whose timeline can never load is worse than a
        // failed join: the reader has to work out for themselves why one of their servers is
        // permanently blank.
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("A refusal is its own message, never confused with a host that is not a forum")
    func aRefusalIsToldApart() async throws {
        for status in [401, 403, 429, 503] {
            let store = ItemStore()
            let http = Self.forumHTTP(latest: .text("", status: status))
            await #expect(throws: JoinError.refused(status)) {
                try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                    .join(host: "install-f.example")
            }
        }

        // 404 is a host that does not serve a front page, which is a different sentence to a
        // reader: check the address, rather than "that server turned us away".
        let store = ItemStore()
        let http = Self.forumHTTP(latest: .text("", status: 404))
        await #expect(throws: JoinError.publicTimelineFailed) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "install-f.example")
        }
    }

    // MARK: - The other forum

    private static func discuzHTTP(
        page: FixtureHTTP.Outcome = .body(Fixtures.html("discuz-x34-guide"))
    ) -> FixtureHTTP {
        FixtureHTTP([
            "/": .body(Fixtures.html("discuz")),
            "/forum.php": page,
        ])
    }

    @Test("A Discuz! forum is detected, read, and added with its threads in the store")
    func aDiscuzForumJoins() async throws {
        let store = ItemStore()
        let http = Self.discuzHTTP()
        try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
            .join(host: "install-a.example")

        let sources = await store.sources()
        #expect(sources.map(\.host) == ["install-a.example"])
        // The source carries what the host actually speaks. A Discuz! and a Discourse are both
        // forums and are not the same program; the row is drawn from the kind.
        #expect(sources.first?.kind == .discuz)

        let notes = await store.all()
        #expect(notes.count == 5)
        #expect(notes.allSatisfy { $0.title?.isEmpty == false })
        #expect(notes.contains { $0.board == "缘聚茶楼" })

        // The front page is read once for the detector, and the guide page once for the threads.
        #expect(await Set(http.paths) == ["/", "/forum.php"])
        #expect(await http.paths.filter { $0 == "/" }.count == 1)
    }

    @Test("A challenge page is a refusal, and leaves no source behind that draws nothing")
    func aChallengedForumIsNotAdded() async throws {
        // The whole reason the page is read *before* the source is added. A forum that detects
        // perfectly and then hands back a filter's challenge would otherwise sit in the reader's
        // list forever, permanently blank, with nothing anywhere saying why.
        for status in [200, 403] {
            let store = ItemStore()
            let http = Self.discuzHTTP(page: .body(Fixtures.html("challenge"), status: status))

            // 403 whatever status it arrived with: a challenge dressed as a 200 reported as a
            // 200 would tell the reader that it worked.
            await #expect(throws: JoinError.refused(403)) {
                try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                    .join(host: "closed.example")
            }
            #expect(await store.sources().isEmpty)
            #expect(await store.all().isEmpty)
        }
    }

    @Test("The forum's own notice page is a refusal too, and is not a spelling mistake")
    func aRestrictedForumIsNotAdded() async throws {
        // `install-e.example` answers a signed-out reader with one of these on every board. The
        // host is fine and so is the address; an account is what would change the answer, which
        // is exactly what `refused` means and `publicTimelineFailed` does not.
        let store = ItemStore()
        let http = Self.discuzHTTP(page: .body(Fixtures.html("discuz-restricted")))
        await #expect(throws: JoinError.refused(403)) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "install-e.example")
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("A forum that shows this reader no threads is a failed join, not an empty one")
    func anEmptyForumIsNotAdded() async throws {
        // Captured from `install-e.example`: a real guide page with an empty table, because a
        // signed-out reader may read no board there at all.
        let store = ItemStore()
        let http = Self.discuzHTTP(page: .body(Fixtures.html("discuz-empty-guide")))
        await #expect(throws: JoinError.publicTimelineFailed) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "install-e.example")
        }
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("A Discuz! refusal keeps its own number, and a 404 stays a 404")
    func aDiscuzRefusalIsToldApart() async throws {
        for status in [401, 403, 429, 503] {
            let store = ItemStore()
            let http = Self.discuzHTTP(page: .text("<html>no</html>", status: status))
            await #expect(throws: JoinError.refused(status)) {
                try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                    .join(host: "install-a.example")
            }
            #expect(await store.sources().isEmpty)
        }

        let store = ItemStore()
        let http = Self.discuzHTTP(page: .text("", status: 404))
        await #expect(throws: JoinError.publicTimelineFailed) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "install-a.example")
        }
    }

    @Test("A forum that cannot be reached at all is not reported as a refusal")
    func anUnreachableDiscuzIsUnreachable() async throws {
        let store = ItemStore()
        let http = Self.discuzHTTP(page: .fail)
        await #expect(throws: JoinError.unreachable) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "install-a.example")
        }
        #expect(await store.sources().isEmpty)
    }

    // MARK: - A join that pauses so the reader can choose

    /// A forum whose index and whose boards are all reachable, each at its own address.
    ///
    /// Routed by whole address rather than by path, because a Discuz!'s index and every one of
    /// its boards are the same path — `/forum.php` — and telling them apart is the query.
    private static func boardHTTP(
        host: String = "install-c.example",
        index: FixtureHTTP.Outcome = .body(Fixtures.html("discuz-x50-index")),
        boards: [Int: FixtureHTTP.Outcome] = [:]
    ) -> FixtureHTTP {
        var routes: [String: FixtureHTTP.Outcome] = [
            "/": .body(Fixtures.html("discuz")),
            "https://\(host)/forum.php": index,
        ]
        for (fid, outcome) in boards {
            routes["https://\(host)/forum.php?mod=forumdisplay&fid=\(fid)"] = outcome
        }
        return FixtureHTTP(routes)
    }

    private static func joiner(_ http: FixtureHTTP, _ store: ItemStore) -> SourceJoin {
        SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
    }

    @Test("A forum join pauses with the boards in hand, and nothing added")
    func aForumJoinPauses() async throws {
        // D28: `join(host:)` means "returns when the source is added and its timeline is in the
        // store", and a forum cannot honour that — the reader has to choose before there is a
        // timeline to fetch at all. So this stops, hands back the index, and adds nothing.
        let store = ItemStore()
        let http = Self.boardHTTP()
        let step = try await Self.joiner(http, store).begin(host: "install-c.example")

        guard case .chooseBoards(let offer) = step else {
            Issue.record("a Discuz! should pause for the reader to choose")
            return
        }
        #expect(offer.host == "install-c.example")
        #expect(offer.kind == .discuz)
        #expect(offer.categories.map(\.name) == ["::工具软件::", "::数码生活::"])
        #expect(offer.boards.count == 9)

        // **Nothing is added until they pick** — the same rule the existing joins follow, for the
        // same reason: a source in the list whose timeline can never load is worse than a failed
        // join, and until the reader has chosen there is nothing for its timeline to be.
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("The reader picks, and one source carries every board they chose")
    func theReaderPicksAndOneSourceCarriesThem() async throws {
        // D26: one `Source` per host with a set of subscribed boards, never one source per board.
        let store = ItemStore()
        let http = Self.boardHTTP(boards: [
            33: .body(Fixtures.html("discuz-x50-board")),
            41: .body(Fixtures.html("discuz-x50-board")),
        ])
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        let picks = offer.boards.filter { [33, 41].contains($0.fid) }
        let outcome = try await join.subscribe(offer, to: picks)

        #expect(outcome.subscribed.map(\.fid) == [33, 41])
        #expect(outcome.unread.isEmpty)

        let sources = await store.sources()
        #expect(sources.count == 1)
        let source = try #require(sources.first)
        #expect(source.host == "install-c.example")
        #expect(source.kind == .discuz)
        #expect(source.boards.map(\.fid) == [33, 41])
        #expect(source.boards.map(\.name) == ["启动盘工具", "Linux系统"])
        #expect(source.subscribes(to: 33))
        #expect(!source.subscribes(to: 99))
        #expect(await store.all().isEmpty == false)
    }

    @Test("The host is asked what it speaks once, across both halves of the conversation")
    func theHostIsAskedOnceAcrossThePause() async throws {
        let store = ItemStore()
        let http = Self.boardHTTP(boards: [33: .body(Fixtures.html("discuz-x50-board"))])
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        try await join.subscribe(offer, to: offer.boards.filter { $0.fid == 33 })

        // The detection travelled in the offer. A second half that asked again would double
        // every join's traffic against a server that did nothing to deserve it.
        #expect(await http.paths.filter { $0 == "/" }.count == 1)
    }

    @Test("A board that cannot be read is not subscribed to, and is named")
    func aBoardThatCannotBeReadIsNotSubscribedTo() async throws {
        // `install-a.example` board 37 is the live case: a real, busy board whose per-board display
        // style is Discuz!'s picture mode, so a signed-out reader is served an empty thread table
        // and a wall of cards with no dates on them. Subscribing to it would put a permanently
        // blank query in the rail — the same failure `refused` guards against one level up.
        let store = ItemStore()
        let http = Self.boardHTTP(boards: [
            33: .body(Fixtures.html("discuz-x50-board")),
            40: .body(Fixtures.html("discuz-empty-guide")),
            37: .body(Fixtures.html("discuz-restricted")),
        ])
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        let outcome = try await join.subscribe(
            offer, to: offer.boards.filter { [33, 40, 37].contains($0.fid) })

        #expect(outcome.subscribed.map(\.fid) == [33])
        #expect(outcome.unread.map(\.board.fid) == [40, 37])
        // Each carries its own reason, so what the reader is told about one is not what they are
        // told about the other: nothing to read, against being turned away.
        #expect(outcome.unread.map(\.error) == [.publicTimelineFailed, .refused(403)])
        #expect(await store.sources().first?.boards.map(\.fid) == [33])
    }

    @Test("A pick where nothing read leaves nothing behind, and says why")
    func nothingReadAddsNothing() async throws {
        let store = ItemStore()
        let http = Self.boardHTTP(boards: [33: .body(Fixtures.html("challenge"))])
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        await #expect(throws: JoinError.refused(403)) {
            try await join.subscribe(offer, to: offer.boards.filter { $0.fid == 33 })
        }
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("Picking nothing is not a failure, and is not a source either")
    func anEmptyPickIsNotAFailure() async throws {
        // A reader who opened the picker and closed it again has not failed at anything, so
        // there is no error for it. There is also no source, which is the half that matters.
        let store = ItemStore()
        let http = Self.boardHTTP()
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        let outcome = try await join.subscribe(offer, to: [])
        #expect(outcome.subscribed.isEmpty)
        #expect(outcome.unread.isEmpty)
        #expect(await store.sources().isEmpty)
    }

    @Test("Picking again replaces the subscription rather than adding a second server")
    func pickingAgainReplacesTheSubscription() async throws {
        let store = ItemStore()
        let http = Self.boardHTTP(boards: [
            33: .body(Fixtures.html("discuz-x50-board")),
            41: .body(Fixtures.html("discuz-x50-board")),
        ])
        let join = Self.joiner(http, store)
        guard case .chooseBoards(let offer) = try await join.begin(host: "install-c.example") else {
            Issue.record("a Discuz! should pause")
            return
        }
        try await join.subscribe(offer, to: offer.boards.filter { $0.fid == 33 })
        try await join.subscribe(offer, to: offer.boards.filter { [33, 41].contains($0.fid) })

        // One host, one source — and the newest statement of what the reader subscribed to.
        #expect(await store.sources().count == 1)
        #expect(await store.sources().first?.boards.map(\.fid) == [33, 41])
    }

    @Test("A forum whose index has no board for this reader is a refusal, not a spelling mistake")
    func anIndexWithNoBoardsIsARefusal() async throws {
        // `install-e.example` serves an unchallenged, ordinary index with no forum list on it at
        // all. The host is fine, the address is fine, and an account is what would change the
        // answer — which is what `refused` means and what `publicTimelineFailed` does not.
        let store = ItemStore()
        let http = Self.boardHTTP(
            host: "install-e.example", index: .body(Fixtures.html("discuz-empty-index")))
        await #expect(throws: JoinError.refused(403)) {
            _ = try await Self.joiner(http, store).begin(host: "install-e.example")
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("Everything that is not a forum with boards still joins in one step")
    func everythingElseStillJoinsInOneStep() async throws {
        let store = ItemStore()
        let discourse = try await Self.joiner(Self.forumHTTP(), store)
            .begin(host: "install-f.example")
        #expect(discourse == .joined)
        #expect(await store.sources().map(\.kind) == [.discourse])
        // And it carries no boards, because a Discourse has no such idea.
        #expect(await store.sources().first?.boards.isEmpty == true)

        let microblog = ItemStore()
        let step = try await Self.joiner(JoinTests.joinHTTP(), microblog)
            .begin(host: "first.example")
        #expect(step == .joined)
        #expect(await microblog.sources().map(\.kind) == [.mastodon])

        // A host that speaks neither is refused by name through this door too.
        let neither = ItemStore()
        let http = FixtureHTTP(["/": .body(Fixtures.html("pleroma"))])
        await #expect(throws: JoinError.unsupportedKind(.pleroma)) {
            _ = try await Self.joiner(http, neither).begin(host: "pleroma.example")
        }
    }

    @Test("Subscribing against a kind that has no boards is refused by name")
    func subscribingToSomethingWithNoBoardsIsRefused() async throws {
        let store = ItemStore()
        let offer = JoinOffer(host: "install-f.example", kind: .discourse, categories: [])
        await #expect(throws: JoinError.unsupportedKind(.discourse)) {
            try await Self.joiner(Self.forumHTTP(), store).subscribe(offer, to: [])
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("A microblog still joins through the same door, and still gets its catalogue")
    func aMicroblogStillJoins() async throws {
        let store = ItemStore()
        let catalogues = EmojiCatalogueStore()
        try await SourceJoin(http: JoinTests.joinHTTP(), store: store, catalogues: catalogues)
            .join(host: "first.example")

        #expect(await store.sources().map(\.kind) == [.mastodon])
        #expect(await store.all().isEmpty == false)
    }

    @Test("A host that speaks neither is refused by name")
    func anUnsupportedHostIsRefusedByName() async throws {
        let store = ItemStore()
        let http = FixtureHTTP(["/": .body(Fixtures.html("pleroma"))])
        await #expect(throws: JoinError.unsupportedKind(.pleroma)) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "pleroma.example")
        }
        #expect(await store.sources().isEmpty)
    }

    // MARK: - A host behind a filter

    @Test("A challenge at the front door is a refusal, not an unknown protocol")
    func aChallengedHostIsRefusedNotUnknown() async throws {
        // The live case this exists for: `challenge.example` answers a challenge page to every path,
        // including `/robots.txt`. A challenge names no software, so every marker
        // `HTMLKind.classify` looks for is absent and the detector used to fall through to
        // `.unknown` — which tells the reader to check their spelling for a host whose spelling
        // is fine, and closes the only door that opens: a sign-in is offered on a refusal and on
        // nothing else.
        let store = ItemStore()
        let http = FixtureHTTP(["/": .body(Fixtures.html("challenge"), status: 403)])

        await #expect(throws: JoinError.refused(403)) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "closed.example")
        }
        #expect(await store.sources().isEmpty)
    }

    @Test("A challenge dressed as a 200 is still a refusal")
    func aChallengeAt200IsStillARefusal() async throws {
        // Cloudflare serves the interstitial at 403 on some paths and 200 on others. Reporting
        // the literal status would tell the reader a challenge had worked.
        let store = ItemStore()
        let http = FixtureHTTP(["/": .body(Fixtures.html("challenge"))])
        await #expect(throws: JoinError.refused(403)) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
                .join(host: "closed.example")
        }
    }

    @Test("A forum that names itself is named, even from behind a filter")
    func softwareMarkersWinOverTheFilter() async throws {
        // The ordering that matters: a forum merely *sitting behind* a filter still serves its
        // own front page most of the time, and naming itself is a better answer than naming its
        // filter. The challenge judgement is only reached when the page named nothing.
        let http = FixtureHTTP(["/": .body(Fixtures.html("discuz"))])
        #expect(try await Detector(http: http).detect("install-a.example") == .discuz)
    }
}
