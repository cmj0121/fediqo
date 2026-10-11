import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #347 — wherever a bookmark is offered or locked, how the sign-in stands to bookmarks is
/// read the one way every place reads a standing (`PartWords.place`) and said in that place's
/// line: on a post's mark and in its menu, and on the source row's permission control. The
/// mark is dim whatever the standing; what it says, and what a press does, is the standing's.
@MainActor
@Suite("Bookmarks say how the sign-in stands to them, as every part does")
struct BookmarkPlaceTests {
    private typealias S = PartServer
    private let host = "social.example"
    private let forum = "bbs.example.org"
    private static let acting = MastodonOAuth.scopes(writing: true, bookmarks: false)
    private static let wider = MastodonOAuth.scopes(writing: true)
    private static let unaskedLine = "Update social.example's permission: its sign-in must be asked again before everything it could do is offered"
    private static let refusedLine = "This was refused on social.example's page. Ask again"
    private static let noneLine = "That source has no bookmarks to allow. Everything else works as it did."
    private static let askingLine = "Fediqo is asking social.example now."

    /// How a sign-in is written down to stand to bookmarks, for a test to file.
    enum Filed: String, CaseIterable, Sendable {
        case held, unasked, refused, hasNone

        @MainActor var scopes: String { self == .held ? BookmarkPlaceTests.wider : BookmarkPlaceTests.acting }
        @MainActor var asked: String { self == .unasked ? BookmarkPlaceTests.acting : BookmarkPlaceTests.wider }
        var refusedWords: String? { self == .refused ? "write:bookmarks" : nil }
        var kind: PartWords.Place.Kind? {
            switch self {
            case .held: nil
            case .unasked: .unasked
            case .refused: .refused
            case .hasNone: PartWords.Place.Kind.none
            }
        }
    }

    private func shell(
        _ filed: Filed? = .unasked, scopes: String? = nil
    ) async throws -> (ShellSession, PartServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        if let filed {
            try tokens.save(MastodonToken(
                host: host, accessToken: "held-1", clientID: "cid", clientSecret: "csecret", scopes: scopes ?? filed.scopes,
                asked: scopes ?? filed.asked, refused: scopes == nil ? filed.refusedWords : nil
            ))
        }
        let server = PartServer(tokens: tokens)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        for source in [Source(host: host, kind: .mastodon), Source(host: forum, kind: .discuz)] {
            await session.store.add(source)
        }
        session.sources = await session.store.sources()
        return (session, server, tokens)
    }

    private func post(in session: ShellSession, at source: Source? = nil) async -> DummyItem {
        let source = source ?? Source(host: host, kind: .mastodon)
        let note = Note(
            id: "https://\(source.host)/users/ada/statuses/9", source: source,
            author: "Ada", handle: "@ada@\(source.host)", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home], statusID: "9"
        )
        await session.store.ingest([note])
        await session.reloadFromStore()
        return DummyItem(note)
    }

    /// A row's share of the acts as a list that can act hands it down (`TimelinePane.acting`).
    private func handed(_ item: DummyItem, in session: ShellSession) -> ItemActing {
        var acting = session.acting(on: item)
        acting.perform = { _ in }
        acting.ask = { _ in session.askToBookmark(item) }
        acting.locks = session.locks(on: item, acts: acting.acts)
        return acting
    }

    private func bookmark(_ item: DummyItem, _ acting: ItemActing) throws -> RowMark {
        try #require(ItemActs.marks(on: item, acting: acting, language: .english).first { $0.isBookmark })
    }

    private func control(_ session: ShellSession, actsLive: Bool = true) throws -> ShellMark? {
        let row = try #require(session.rows.first { $0.source.host == host })
        return SourceRow.permission(row, actsLive: actsLive, lock: session.mastodon.bookmarkPlace(host: host), language: .english)
    }

    private static func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Shell")
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - The one reading

    @Test("How a sign-in stands to bookmarks is read the one way every part's standing is: held draws nothing, and never asked, refused on the page and none each draw that reading's own place", arguments: Filed.allCases)
    func theOneReading(_ filed: Filed) async throws {
        let (session, _, _) = try await shell(filed)
        let standing = try #require(session.mastodon.standing(.bookmarks, host: host))
        let place = session.mastodon.bookmarkPlace(host: host)
        #expect(place == PartWords.place(standing, of: .bookmarks))
        #expect(place?.kind == filed.kind)
        #expect(session.mastodon.bookmarkPlace(host: "Social.Example") == place)
        // What the place offers and what the press does agree.
        let asks: Bool = place?.asks ?? false
        #expect(session.askBookmarks(host: host) == asks)
    }

    // MARK: - A post's mark and its menu

    @Test("A post's bookmark mark is drawn dim in its own glyph for every standing but held, and says the standing's line after its reason — on the mark and at the head of the menu; never asked says its reason alone, as it did", arguments: Filed.allCases)
    func thePostsMark(_ filed: Filed) async throws {
        let (session, server, _) = try await shell(filed)
        let item = await post(in: session)
        let acting = handed(item, in: session)
        let mark = try bookmark(item, acting)
        let head = ItemActs.more(on: item, acting: acting, here: nil, language: .english).head
        #expect(mark.mark.symbol == "bookmark", "the mark itself changed with the standing")
        let lines = [Self.refusedLine, Self.noneLine, Self.askingLine]
        switch filed {
        case .held:
            // Kept: offered, live, and no lock.
            #expect(mark.mark.look == .live)
            #expect(acting.locks.isEmpty)
            #expect(mark.label == "Bookmark")
        case .unasked:
            // Kept: the reason alone, said once, and the press asks.
            #expect(mark.mark.look == .dim(.askAgain))
            #expect(mark.label == "Bookmark. This sign-in must be asked again first")
            #expect(head.contains("Bookmark. This sign-in must be asked again first"))
            for line in lines { #expect(!head.contains(line)) }
        case .refused:
            // Changed: it was drawn and said as never asked. It still asks, and now says why.
            #expect(mark.mark.look == .dim(.askAgain))
            #expect(mark.label == "Bookmark. This sign-in must be asked again first: \(Self.refusedLine)")
            #expect(head.contains(Self.refusedLine))
        case .hasNone:
            // Changed: the dim mark said only that the source has none; now in the place's words too.
            #expect(mark.mark.look == .dim(.never))
            #expect(mark.label == "Bookmark. This source has none: \(Self.noneLine)")
            #expect(head.contains(Self.noneLine))
        }
        // The other marks are as they were, whatever the bookmark's standing.
        let favourite = try #require(ItemActs.marks(on: item, acting: acting, language: .english).first { $0.kind == .act(.favourite) })
        #expect(favourite.mark.look == .live)
        #expect(favourite.label == "Favourite")

        ItemActs.press(mark, acting: acting)
        let raised: Bool = session.bookmarkAsk == host
        let asks: Bool = filed == .unasked || filed == .refused
        #expect(raised == asks, "the press and the line disagree")
        #expect(await server.paths.isEmpty, "a press on the mark asked the source something")
        // The menu's item does what the mark does.
        session.partAsks.putDown()
        let chosen = try #require(ItemActs.more(on: item, acting: acting, here: nil, language: .english).items.first { $0.name == "Bookmark" })
        let answers: Bool = filed == .held || raised
        #expect(chosen.answers == answers)
        chosen.press { _ in }
        let again: Bool = session.bookmarkAsk == host
        #expect(again == raised)
    }

    @Test("A bookmark the source turned away this run, a sign-in that only reads, no sign-in, and a forum's post draw no lock and say what they said")
    func whereBookmarksAreNotWhatIsInTheWay() async throws {
        // Turned away with a 403: said in its own words until the next sign-in, and never a standing.
        let (away, _, tokens) = try await shell(.held)
        let sent = try #require(try tokens.token(host: host))
        away.writeFailed(MastodonAuthError.http(403), host: host, bookmarkSentWith: sent)
        #expect(away.mastodon.bookmarkTurnedAway.contains(host))
        #expect(away.mastodon.bookmarkPlace(host: host) == nil)
        let item = await post(in: away)
        let turned = handed(item, in: away)
        #expect(turned.locks.isEmpty)
        let mark = try bookmark(item, turned)
        #expect(mark.mark.look == .dim(.never))
        #expect(mark.label == "Bookmark. This source has none")
        #expect(away.rowRefusal?.key == "account.bookmarks.refused")

        // Only reading: nothing to add bookmarks to, and the row says to sign in to act.
        let (reads, _, _) = try await shell(scopes: MastodonOAuth.reading)
        #expect(reads.mastodon.bookmarkPlace(host: host) == nil)
        let read = await post(in: reads)
        let reading = handed(read, in: reads)
        #expect(reading.locks.isEmpty)
        #expect(reading.acts.refused == .notSignedIn)
        #expect(try control(reads) == nil)

        let (out, _, _) = try await shell(nil)
        #expect(out.mastodon.bookmarkPlace(host: host) == nil)
        #expect(handed(await post(in: out), in: out).locks.isEmpty)
    }

    @Test("A post gone at its source draws no lock, whatever its sign-in holds; and on a row two sources carried, a copy whose press could not ask is not what the mark speaks of — the mark says what is true of the source its other acts go through")
    func theLockIsAboutWhereThePressGoes() async throws {
        let (gone, _, _) = try await shell(.hasNone)
        let lost = Note(
            id: "https://social.example/users/ada/statuses/9", source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: "@ada@social.example", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home], statusID: "9",
            goneSince: Date(timeIntervalSince1970: 1_700_000_100)
        )
        await gone.store.ingest([lost])
        await gone.reloadFromStore()
        let left = handed(DummyItem(lost), in: gone)
        #expect(left.acts.offered.isEmpty)
        #expect(left.locks.isEmpty)

        // Never asked at the first source, whose copy cannot be named there; none at the second.
        let other = "other.example"
        let (session, _, tokens) = try await shell(.unasked)
        try tokens.save(MastodonToken(
            host: other, accessToken: "held-2", clientID: "cid", clientSecret: "csecret", scopes: Self.acting, asked: Self.wider
        ))
        session.mastodon.refresh()
        await session.store.add(Source(host: other, kind: .mastodon))
        session.sources = await session.store.sources()
        for (at, statusID) in [(host, nil), (other, "7")] as [(String, String?)] {
            await session.store.ingest([Note(
                id: "https://origin.example/users/ada/statuses/1", source: Source(host: at, kind: .mastodon),
                author: "Ada", handle: "@ada@origin.example", body: "hello",
                postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home], statusID: statusID
            )])
        }
        await session.reloadFromStore()
        let rows = DummyItem.merged(session.notes)
        let row = try #require(rows.first)
        try #require(rows.count == 1)
        try #require(row.otherCopies.count == 1)
        try #require(row.source.host == host)
        #expect(session.mastodon.bookmarkPlace(host: host)?.kind == .unasked)
        let merged = handed(row, in: session)
        #expect(!merged.acts.asks(.bookmark))
        #expect(merged.acts.offers(.favourite))
        #expect(merged.locks[.bookmark] == ItemActing.Lock(place: PartWords.Place(kind: .none, key: "account.bookmarks.unavailable"), host: other))
        #expect(try bookmark(row, merged).mark.look == .dim(.never))
    }

    @Test("A forum source is untouched: no place, no lock, no listing, the same marks with the same words, and the same row")
    func aForumReadsAsItDid() async throws {
        let (session, _, _) = try await shell(.refused)
        #expect(session.mastodon.bookmarkPlace(host: forum) == nil)
        #expect(session.mastodon.holds(host: forum) == nil)
        let item = await post(in: session, at: Source(host: forum, kind: .discuz))
        var plain = session.acting(on: item)
        plain.perform = { _ in }
        plain.ask = { _ in }
        let given = handed(item, in: session)
        #expect(given.locks.isEmpty)
        #expect(given.acts.refused == .protocolCannot)
        #expect(ItemActs.marks(on: item, acting: given, language: .english) == ItemActs.marks(on: item, acting: plain, language: .english))
        let mark = try bookmark(item, given)
        #expect(mark.mark.look == .dim(.never))
        #expect(mark.label == "Bookmark. This source has none: \(L10n.t("item.act.no.protocol", language: .english))")
        let row = try #require(session.rows.first { $0.source.host == forum })
        #expect(row.owed == .nothing)
        #expect(SourceRow.permission(row, actsLive: true, lock: session.mastodon.bookmarkPlace(host: forum)) == nil)
        #expect(SourceRow.head(row, said: [], holds: session.mastodon.holds(host: forum), lock: session.mastodon.bookmarkPlace(host: forum)).isEmpty)
    }

    // MARK: - The source row's permission control

    @Test("The row's permission control says the standing's line: never asked in the words it had, refused on the page in the line that asks again; a source with none owes nothing, as before; the word and the glyph are the same whichever", arguments: Filed.allCases)
    func theRowsControl(_ filed: Filed) async throws {
        let (session, _, _) = try await shell(filed)
        let row = try #require(session.rows.first { $0.source.host == host })
        let lock = session.mastodon.bookmarkPlace(host: host)
        let mark = try control(session)
        switch filed {
        case .held, .hasNone:
            // Kept: nothing is owed, and no control is drawn.
            #expect(row.owed == .nothing)
            #expect(mark == nil)
            #expect(SourceRow.head(row, said: [], lock: lock, language: .english).isEmpty)
        case .unasked:
            // Kept, word for word.
            #expect(mark?.name == Self.unaskedLine)
            #expect(mark?.look == .live)
            #expect(mark == SourceRow.permission(row, actsLive: true, language: .english))
        case .refused:
            // Changed: it said it had never been asked.
            #expect(mark?.name == Self.refusedLine)
            #expect(mark?.look == .live)
            #expect(SourceRow.head(row, said: [], lock: lock, language: .english) == [Self.refusedLine])
        }
        if let mark {
            #expect(mark.symbol == "exclamationmark.lock")
            #expect(mark.word == "Update permission")
            // Held by a stage: dim, as it was, whatever the line.
            #expect(try control(session, actsLive: false)?.look == .dim(.notNow))
        }
    }

    @Test("A write the source turned away is still said first on the row, in its own words, whatever the bookmarks' standing; and Account and the timeline hand the place in where they draw")
    func aWriteTurnedAwayIsSaidFirst() async throws {
        let (session, _, _) = try await shell(.refused)
        let refused = SourceRow(source: Source(host: host, kind: .mastodon), profile: .unasked(host: host, kind: .mastodon), signedIn: true, writing: .refused, unasked: true)
        let lock = try #require(session.mastodon.bookmarkPlace(host: host))
        #expect(SourceRow.permissionLine(refused, lock: lock, language: .english) == Self.unaskedLine)
        // A place that is none is never the control's line: only one that asks, or the asking one.
        let asking = SourceRow(source: Source(host: host, kind: .mastodon), profile: .unasked(host: host, kind: .mastodon), signedIn: true, unasked: true)
        let none = PartWords.Place(kind: PartWords.Place.Kind.none, key: "account.bookmarks.unavailable")
        #expect(L10n.t(none.key, language: .english) == Self.noneLine)
        #expect(SourceRow.permissionLine(asking, lock: none, language: .english) == Self.unaskedLine)
        #expect(SourceRow.permission(asking, actsLive: true, lock: none, language: .english)?.name == Self.unaskedLine)
        #expect(SourceRow.permissionLine(asking, lock: nil, language: .english) == Self.unaskedLine)
        #expect(SourceRow.permissionLine(asking, lock: lock, language: .english) == Self.refusedLine)
        let now = PartWords.Place(kind: .asking, key: "part.ask.asking")
        #expect(SourceRow.permissionLine(asking, lock: now, language: .english) == Self.askingLine)
        #expect(try Self.source("AccountPane.swift").contains("lock: session.mastodon.bookmarkPlace(host: row.source.host),"))
        #expect(try Self.source("TimelinePane.swift").contains("acting.locks = session.locks(on: item, acts: acting.acts)"))
    }

    // MARK: - While the source is being asked

    /// What can come of an ask, and how a test brings it about.
    enum Outcome: String, CaseIterable, Sendable {
        case allowed, closed, refused, hasNone, failed, another, signedOut
    }

    @Test("While a source is being asked, its bookmark places say so and take no press — the post's mark and the row's control alike — and every way the ask can end clears it, leaving the place the sign-in then stands at", arguments: Outcome.allCases)
    func whileItIsAsked(_ outcome: Outcome) async throws {
        let (session, server, _) = try await shell(.unasked)
        let item = await post(in: session)
        var page = PartPage()
        switch outcome {
        case .allowed, .signedOut: break
        case .closed: page = PartPage(.close)
        case .refused: page = PartPage(.refuse)
        case .hasNone: await server.lists(MastodonParts.everything.split(separator: " ").map(String.init).filter { $0 != "write:bookmarks" })
        case .failed: await server.answer(S.apps, .body("{}", 503))
        case .another: await server.name("new-1", as: "2")
        }
        let gate = Gate()
        defer { Task { await gate.open() } }
        // Held at the first thing an ask sends, so every outcome is still ahead of it.
        await server.hold(S.check, at: gate)
        #expect(session.askBookmarks(host: host))
        session.partAsks.answer(try #require(session.partAsks.open), through: page, in: session)
        #expect(await spun { await server.waiting.contains(S.check) })

        #expect(session.mastodon.bookmarkPlace(host: host) == PartWords.Place(kind: .asking, key: "part.ask.asking"))
        let during = handed(item, in: session)
        let mark = try bookmark(item, during)
        // Changed: the mark said it must be asked again, and its press only answered with a toast.
        #expect(mark.mark.look == .dim(.notNow))
        #expect(mark.label == "Bookmark. Not right now: \(Self.askingLine)")
        #expect(ItemActs.more(on: item, acting: during, here: nil, language: .english).head.contains(Self.askingLine))
        ItemActs.press(mark, acting: during)
        #expect(session.partAsks.open == nil)
        #expect(session.toast == nil)
        let chosen = try #require(ItemActs.more(on: item, acting: during, here: nil, language: .english).items.first { $0.name == "Bookmark" })
        #expect(!chosen.answers, "the menu offered a press its line says cannot be made")
        let row = try control(session)
        #expect(row?.name == Self.askingLine)
        #expect(row?.look == .dim(.notNow))
        #expect(row?.spoken == "\(Self.askingLine). Not right now")

        if outcome == .signedOut { await session.signOut(host: host) }
        await gate.open()
        await session.partAsks.landed(host: host)

        #expect(!session.mastodon.asking.contains(host))
        let after = session.mastodon.bookmarkPlace(host: host)
        let now = handed(item, in: session)
        switch outcome {
        case .allowed:
            #expect(after == nil)
            #expect(session.mastodon.bookmarks(host: host) == .allowed)
            #expect(try bookmark(item, now).mark.look == .live)
            #expect(try control(session) == nil)
        case .closed, .failed, .another:
            #expect(after?.kind == .unasked)
            #expect(try bookmark(item, now).label == "Bookmark. This sign-in must be asked again first")
            #expect(try control(session)?.name == Self.unaskedLine)
        case .refused:
            #expect(after?.kind == .refused)
            #expect(try bookmark(item, now).label == "Bookmark. This sign-in must be asked again first: \(Self.refusedLine)")
            #expect(try control(session)?.name == Self.refusedLine)
            #expect(try control(session)?.look == .live)
        case .hasNone:
            #expect(after?.kind == PartWords.Place.Kind.none)
            #expect(try bookmark(item, now).label == "Bookmark. This source has none: \(Self.noneLine)")
            #expect(try control(session) == nil)
        case .signedOut:
            // Nothing is drawn of a sign-in that is gone.
            #expect(after == nil)
            #expect(now.locks.isEmpty)
            #expect(now.acts.refused == .notSignedIn)
            #expect(session.mastodon.holds(host: host) == nil)
        }
    }

    @Test("A sign-in that took another's place while the first was being asked is drawn as itself: its own standing, and not the one before's")
    func aSignInReplacedIsNotDrawnAsTheOneBefore() async throws {
        let (session, _, tokens) = try await shell(.refused)
        #expect(session.mastodon.bookmarkPlace(host: host)?.kind == .refused)
        try tokens.save(MastodonToken(
            host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.wider, asked: Self.wider
        ))
        session.mastodon.refresh()
        #expect(session.mastodon.bookmarkPlace(host: host) == nil)
        let item = await post(in: session)
        #expect(handed(item, in: session).locks.isEmpty)
        #expect(try control(session) == nil)
    }
}
