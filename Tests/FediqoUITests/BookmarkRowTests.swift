import AppKit
import FediqoPersistence
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A bookmark is kept at the source (#285), from the row down.
///
/// What a test can reach: where the mark is offered and what the row says where it is not; the
/// press reaching the source, landing as its answer, failing and being tried again; the mark
/// read again and after a relaunch; the mark a row lays out, in each of the three standings; and
/// every word in both languages. What it cannot: the mark drawn in light and dark, on a Mac and
/// a phone — that lives in a view body. What the sign-in asks for is `MastodonSignInTests`'.
@MainActor
@Suite("Bookmarking a post at its source", .serialized)
struct BookmarkRowTests {
    private let host = "social.example"
    private static let acting = MastodonOAuth.scopes(writing: true)
    /// What a sign-in to read and act was before bookmarks were asked for.
    private static let before = MastodonOAuth.scopes(writing: true, bookmarks: false)

    static func status(bookmarked: Bool? = nil, favourited: Bool? = nil) -> String {
        let flag = (bookmarked.map { #","bookmarked":\#($0)"# } ?? "")
            + (favourited.map { #","favourited":\#($0)"# } ?? "")
        return """
        {"id":"9","uri":"https://social.example/users/ada/statuses/9",
         "created_at":"2024-06-01T00:00:00.000Z","content":"<p>hello</p>",
         "visibility":"public"\(flag),
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private func note(bookmarked: Bool?, favourited: Bool? = nil, host: String? = nil) -> Note {
        Note(
            id: "https://social.example/users/ada/statuses/9",
            source: Source(host: host ?? self.host, kind: .mastodon),
            author: "Ada", handle: "@ada@social.example", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home],
            favourited: favourited, bookmarked: bookmarked, statusID: "9"
        ).readNow()
    }

    private func shell(
        scopes: String?, holding: Note, routes: [String: ActServer.Outcome] = [:], store: ItemStore? = nil
    ) async throws -> (ShellSession, ActServer) {
        let tokens = MemoryMastodonTokens()
        if let scopes {
            try tokens.save(MastodonToken(
                host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret", scopes: scopes
            ))
        }
        let server = ActServer(routes)
        let store = store ?? ItemStore(sources: [Source(host: host, kind: .mastodon)], notes: [holding])
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        return (session, server)
    }

    private func row(_ session: ShellSession) throws -> DummyItem {
        DummyItem(try #require(session.notes.first))
    }

    // MARK: - Offered, or said why not

    @Test("Signed in to read only, or not signed in, the bookmark is not offered or asked for, and a press sends nothing")
    func notOfferedWithoutActing() async throws {
        for scopes in [MastodonOAuth.reading, nil] {
            let (session, server) = try await shell(scopes: scopes, holding: note(bookmarked: nil))
            let item = try row(session)
            let acts = session.acts(on: item)
            #expect(!acts.offers(.bookmark) && !acts.asks(.bookmark))
            #expect(acts.refused == .notSignedIn)
            await session.toggle(.bookmark, on: item)
            #expect(!session.askToBookmark(item), "a sign-in that does not act has nothing to add bookmarks to")
            #expect(await server.paths.isEmpty)
        }
    }

    @Test("Signed in to act, the bookmark is offered beside the boost and the favourite")
    func offeredWhereAllowed() async throws {
        let (session, _) = try await shell(scopes: Self.acting, holding: note(bookmarked: false))
        let acts = session.acts(on: try row(session))
        #expect(acts.offered == [.boost, .favourite, .answer, .bookmark])
        #expect(acts.asking.isEmpty && acts.refused == nil)
    }

    @Test("A row two sources carried bookmarks through the source that allows it, and asks nothing")
    func aMergedRowGoesThroughTheSourceThatAllows() async throws {
        let other = "second.example"
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: host, accessToken: "a", clientID: "c", clientSecret: "s", scopes: Self.before))
        try tokens.save(MastodonToken(host: other, accessToken: "b", clientID: "c", clientSecret: "s", scopes: Self.acting))
        let store = ItemStore(
            sources: [Source(host: host, kind: .mastodon), Source(host: other, kind: .mastodon)],
            notes: [note(bookmarked: false), note(bookmarked: false, host: other)]
        )
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: ActServer([:]))
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        let merged = try #require(session.timelineItems(latest: nil).first)
        #expect(merged.copies.count == 2)

        let acts = session.acts(on: merged)
        #expect(acts.offers(.bookmark) && acts.asking.isEmpty, "an act a press can do is done, not asked about")
        #expect(session.actingCopy(of: merged, for: .bookmark)?.source.host == other)
        #expect(session.acting(on: merged).through[.bookmark]?.source.host == other)
    }

    // MARK: - The press

    @Test("Bookmarked here, the source is asked and its answer is the mark; taken off here, the same")
    func aBookmarkLands() async throws {
        let (session, server) = try await shell(
            scopes: Self.acting, holding: note(bookmarked: false, favourited: true),
            routes: [
                "/api/v1/statuses/9/bookmark": .json(Self.status(bookmarked: true, favourited: true)),
                "/api/v1/statuses/9/unbookmark": .json(Self.status(bookmarked: false, favourited: true)),
            ]
        )
        var saved = 0
        session.persist = { saved += 1; return true }

        await session.toggle(.bookmark, on: try row(session))
        #expect(await server.paths == ["/api/v1/statuses/9/bookmark"])
        #expect(await server.methods == ["POST"])
        #expect(try row(session).bookmarked == true)
        #expect(try row(session).favourited == true, "another mark moved")
        #expect(session.acts.standings.isEmpty, "nothing about the press is kept")
        await session.saved()
        #expect(saved == 1)

        await session.toggle(.bookmark, on: try row(session))
        #expect(await server.paths.last == "/api/v1/statuses/9/unbookmark")
        #expect(try row(session).bookmarked == false)
    }

    @Test("A press the source turns away says so and leaves the mark as it was; the same press tries again")
    func aBookmarkTurnedAway() async throws {
        for refusal in [ActServer.Outcome.fail, .json("{}", status: 422)] {
            let (session, server) = try await shell(
                scopes: Self.acting, holding: note(bookmarked: false),
                routes: ["/api/v1/statuses/9/bookmark": refusal]
            )
            let item = try row(session)
            await session.toggle(.bookmark, on: item)
            #expect(session.acts.standing(of: item.id, .bookmark) == .failed)
            #expect(session.acts.standing(of: item.id, .favourite) == nil, "one act's failure is not another's")
            #expect(try row(session).bookmarked == false, "the mark moved on a press that did not land")
            let mark = ItemActs.mark(.bookmark, on: try row(session), acting: session.acting(on: try row(session)), language: .english)
            #expect(!mark.done && mark.glyph == "exclamationmark.triangle")
            #expect(mark.spoken == "Bookmark did not arrive. Press to try again.")
            await session.toggle(.bookmark, on: item)
            #expect(await server.paths == ["/api/v1/statuses/9/bookmark", "/api/v1/statuses/9/bookmark"])
        }
    }

    @Test("A bookmark the source forbids is not offered there for the rest of the run, and says so; every other act stands, and the sign-in is not touched")
    func aForbiddenBookmarkLeavesTheRest() async throws {
        let tokens = MemoryMastodonTokens()
        let held = MastodonToken(
            host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
            scopes: Self.acting, asked: Self.acting
        )
        try tokens.save(held)
        let server = ActServer([
            "/api/v1/statuses/9/bookmark": .json("{}", status: 403),
            "/api/v1/statuses/9/favourite": .json(Self.status(favourited: true)),
        ])
        let store = ItemStore(sources: [Source(host: host, kind: .mastodon)], notes: [note(bookmarked: false)])
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()

        await session.toggle(.bookmark, on: try row(session))

        #expect(session.mastodon.writing(host: host, kind: .mastodon) == .writes, "one forbidden bookmark hid every act")
        let acts = session.acts(on: try row(session))
        #expect(acts.offered == [.boost, .favourite, .answer])
        #expect(!acts.asks(.bookmark), "a source that has answered is offered the question again")
        #expect(try row(session).bookmarked == false)
        #expect(session.rowRefusal?.host == host && session.rowRefusal?.key == "account.bookmarks.refused")
        #expect(session.toast != nil, "nothing told the reader why the mark went")
        #expect(try tokens.token(host: host) == held, "what the sign-in wrote down was rewritten on one refusal")
        await session.toggle(.favourite, on: try row(session))
        #expect(try row(session).favourited == true, "and the acts that stand still land")
        for language in [DummyLanguage.english, .taiwanese] {
            #expect(L10n.t("account.bookmarks.refused", language: language) != "account.bookmarks.refused")
        }

        // One refusal is not proof, and nothing was written down: the next run offers it again.
        let relaunched = MastodonSessions(tokens: tokens, sender: server)
        #expect(relaunched.bookmarks(host: host) == .allowed)
        // And signing in again, this run, is a fresh answer.
        #expect(session.mastodon.bookmarks(host: host) == .unavailable)
        await session.mastodon.signOut(host: host)
        #expect(session.mastodon.bookmarkTurnedAway.isEmpty)
    }

    @Test("A refusal that comes back about a sign-in since replaced is not laid on the one held now")
    func aRefusalAboutAnEarlierTokenIsNotRecorded() throws {
        let tokens = MemoryMastodonTokens()
        let old = MastodonToken(host: host, accessToken: "tok-old", clientID: "c", clientSecret: "s", scopes: Self.acting)
        try tokens.save(MastodonToken(host: host, accessToken: "tok-new", clientID: "c", clientSecret: "s", scopes: Self.acting))
        let sessions = MastodonSessions(tokens: tokens, sender: ActServer([:]))

        sessions.refusedBookmark(host: host, sentWith: old)
        #expect(sessions.bookmarks(host: host) == .allowed)
        #expect(try tokens.token(host: host)?.accessToken == "tok-new")

        sessions.refusedBookmark(host: host, sentWith: try #require(try tokens.token(host: host)))
        #expect(sessions.bookmarks(host: host) == .unavailable)
    }

    // MARK: - The marks are the signed-in reader's

    /// A session signed in to `host` as `me`, holding a post the source said that reader had
    /// boosted, favourited and bookmarked, and kept here.
    private func marked(as me: String = "me", scopes: String = BookmarkRowTests.acting) async throws
        -> (ShellSession, MemoryMastodonTokens, ActServer)
    {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret", scopes: scopes
        ))
        let server = ActServer([
            "/api/v1/accounts/verify_credentials": .json(#"{"acct":"\#(me)"}"#),
            "/oauth/revoke": .json("{}"),
        ])
        let held = Note(
            id: "https://social.example/users/ada/statuses/9", source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: "@ada@social.example", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home],
            boosted: true, favourited: true, bookmarked: true, statusID: "9", kept: true
        )
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(sources: [Source(host: host, kind: .mastodon)], notes: [held]),
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.mastodon.verifyAll()
        await session.reloadFromStore()
        return (session, tokens, server)
    }

    private static func said(_ item: DummyItem) -> [Bool?] { [item.boosted, item.favourited, item.bookmarked] }

    @Test("Signing out takes what the source said that reader did from its rows, and writes it down; the post and what is kept stay")
    func signingOutTakesTheMarks() async throws {
        let (session, _, _) = try await marked()
        #expect(Self.said(try row(session)) == [true, true, true])
        var saved = 0
        session.persist = { saved += 1; return true }

        await session.signOut(host: host)
        await session.reloadFromStore()

        #expect(Self.said(try row(session)) == [nil, nil, nil], "the next reader would be told what this one did")
        #expect(try row(session).kept, "what this device keeps is not the source's to take")
        #expect(await session.store.snapshot().notes.first?.bookmarked == nil, "and it rides no package")
        await session.saved()
        #expect(saved >= 1)
    }

    @Test("A sign-in the server ended takes them too, at the next thing the store is read for")
    func endedByTheServerTakesTheMarks() async throws {
        let (session, tokens, _) = try await marked()
        try tokens.forget(host: host)
        session.mastodon.endedByServer(host: host)
        await session.reloadFromStore()
        #expect(Self.said(try row(session)) == [nil, nil, nil])
    }

    @Test("Another account signing in on that host is not told what the first did; the same account signing in again keeps its marks")
    func anotherAccountIsNotToldTheFirsts() async throws {
        for next in ["me", "somebody"] {
            let tokens = MemoryMastodonTokens()
            try tokens.save(MastodonToken(
                host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret", scopes: Self.acting
            ))
            let server = WhoServer(acct: "me")
            let store = ItemStore(sources: [Source(host: host, kind: .mastodon)], notes: [note(bookmarked: true, favourited: true)])
            let session = ShellSession(
                http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
            )
            session.mastodon.refresh()
            await session.mastodon.verifyAll()
            await session.reloadFromStore()
            #expect(session.mastodon.handles[host] == "@me@social.example")

            // The source's own page, answered this time as `next`, with nobody signed out first.
            await server.become(next)
            await session.signIn(host: host, through: ApprovingPage(), writing: true)
            await session.reloadFromStore()

            #expect(session.mastodon.handles[host] == "@\(next)@social.example")
            let item = try row(session)
            if next == "me" {
                #expect(item.bookmarked == true && item.favourited == true, "the same reader lost their own marks")
            } else {
                #expect(item.bookmarked == nil && item.favourited == nil, "a second account inherited the first's marks")
                #expect(!ItemActs.mark(.bookmark, on: item, acting: session.acting(on: item)).done,
                        "its first press would take off a bookmark it never made")
            }
        }
    }

    @Test("Signed out, then the store taken away at once: the package's rows, and the file on disk, say nothing of the reader")
    func signedOutThenTakenAway() async throws {
        let root = LimitRoom.scratch()
        let other = LimitRoom.scratch()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-\(UUID().uuidString).fdq")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
            try? FileManager.default.removeItem(at: package)
        }
        let (session, tokens, _) = try await marked()
        let file = try StoreFile(at: root)
        let saver = StoreSaver(store: session.store, file: file)
        session.persist = { (try? await saver.save()) != nil }
        _ = await session.persist?()
        #expect(try file.load().notes.first?.bookmarked == true)
        func packager(_ directory: URL, _ file: StoreFile?, _ store: ItemStore, _ suite: String) throws -> StorePackager {
            StorePackager(
                directory: directory, file: file, store: store,
                media: try MediaCache(directory: directory.appendingPathComponent("media", isDirectory: true)),
                tokens: tokens, credentials: MemoryCredentials(), defaults: try #require(UserDefaults(suiteName: suite)),
                device: "a test", appVersion: "0.7.0", freeSpace: { _ in .max }, rounds: 1000
            )
        }
        let suite = "fediqo.test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        // Signed out, and nothing else asked of the session before the store is taken away.
        await session.signOut(host: host)
        await session.saved()
        #expect(try file.load().notes.first?.bookmarked == nil, "still on disk after the sign-out")
        await session.saveForCarry()
        try await packager(root, file, session.store, suite)
            .takeAway(to: package, key: .password("open sesame"), pictures: false) { _ in }

        let onto = ItemStore()
        try await packager(other, try StoreFile(at: other), onto, suite)
            .readBack(package, key: .password("open sesame"), replacing: false) { _ in }
        let carried = try #require(await onto.snapshot().notes.first)
        #expect(carried.bookmarked == nil && carried.favourited == nil && carried.boosted == nil,
                "the package says what a signed-out reader did")
        #expect(carried.kept, "what this device keeps still rides")
    }

    @Test("A sign-in the server ended, with nothing read since, is let go of before a take-away or a move saves the store")
    func endedThenSavedForCarry() async throws {
        let (session, tokens, _) = try await marked()
        var saved = 0
        session.persist = { saved += 1; return true }
        try tokens.forget(host: host)
        session.mastodon.endedByServer(host: host)

        await session.saveForCarry()

        #expect(await session.store.snapshot().notes.first?.bookmarked == nil)
        #expect(saved >= 1)
    }

    @Test("Another account signing in: what the first did is let go of before its first read, so what that read says of the new reader is there afterwards")
    func theNewReadersFirstReadStands() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret", scopes: Self.acting
        ))
        let server = WhoServer(acct: "me")
        // The first reader had favourited it and not bookmarked it; the second, the other way.
        let store = ItemStore(sources: [Source(host: host, kind: .mastodon)], notes: [note(bookmarked: false, favourited: true)])
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.mastodon.verifyAll()
        await session.reloadFromStore()

        await server.become("somebody", home: Self.status(bookmarked: true))
        await session.signIn(host: host, through: ApprovingPage(), writing: true)
        await session.reloadFromStore()

        let item = try row(session)
        #expect(item.bookmarked == true, "the new reader's own mark was wiped with the old reader's")
        #expect(item.favourited == nil, "and the old reader's is not told to the new")
    }

    @Test("At a launch, rows of a source nobody is signed in to say nothing of a reader; a Keychain that cannot be read is not everybody leaving")
    func aLaunchWithNoSignIn() async throws {
        let store = ItemStore(sources: [Source(host: host, kind: .mastodon)], notes: [note(bookmarked: true, favourited: true)])
        let unsigned = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:]))
        )
        await unsigned.reloadFromStore()
        #expect(try row(unsigned).bookmarked == nil && row(unsigned).favourited == nil)

        let locked = ItemStore(sources: [Source(host: host, kind: .mastodon)], notes: [note(bookmarked: true, favourited: true)])
        let session = ShellSession(
            http: FixtureHTTP(), store: locked, mastodon: MastodonSessions(tokens: LockedTokens(), sender: ActServer([:]))
        )
        await session.reloadFromStore()
        #expect(try row(session).bookmarked == true, "a locked Keychain at launch wiped what the source had said")
    }

    // MARK: - What the source last said

    @Test("Taken off at the source and read again, the row shows it not bookmarked")
    func readAgainSaysWhatTheSourceSays() async throws {
        let (session, _) = try await shell(scopes: Self.acting, holding: note(bookmarked: true))
        #expect(try row(session).bookmarked == true)
        await session.store.refresh([note(bookmarked: false)], ifSourceHere: host)
        await session.reloadFromStore()
        #expect(try row(session).bookmarked == false)
        #expect(!ItemActs.mark(.bookmark, on: try row(session), acting: session.acting(on: try row(session))).done)
    }

    @Test("Quit and open again: the mark is as the source last said it")
    func survivesARelaunch() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (session, _) = try await shell(
            scopes: Self.acting, holding: note(bookmarked: false),
            routes: ["/api/v1/statuses/9/bookmark": .json(Self.status(bookmarked: true))]
        )
        let file = try StoreFile(at: dir)
        session.persist = {
            let snapshot = await session.store.snapshot()
            try? await file.save(sources: snapshot.sources, notes: snapshot.notes)
            return true
        }
        await session.toggle(.bookmark, on: try row(session))
        await session.saved()

        let opened = StoreFile.open(at: dir)
        let (relaunched, _) = try await shell(
            scopes: Self.acting, holding: note(bookmarked: nil),
            store: ItemStore(sources: opened.sources, notes: opened.notes)
        )
        #expect(try row(relaunched).bookmarked == true)
        #expect(relaunched.acts.standings.isEmpty)
    }

    // MARK: - Nothing that only lived on the screen

    /// The names of the marks a row lays out for `acting`.
    private static func marks(_ item: DummyItem, _ acting: ItemActing) -> Set<String> {
        let probe = RowBandProbe()
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
                               acting: acting, probe: probe)
        let host = NSHostingView(rootView: row.frame(width: 720))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return Set(probe.marks.keys)
    }

    /// A mark's name in every language a row may be drawn in, since the row reads the shell's.
    private static func names(_ name: (DummyLanguage) -> String) -> Set<String> {
        Set([DummyLanguage.english, .taiwanese].map(name))
    }

    @Test("Every row draws the bookmark mark, in its own glyph: dim where the source cannot hold one, live where it can, and dim as to be asked again for an earlier sign-in")
    func theRowDrawsTheBookmarkLiveOrDim() async throws {
        let bookmark = Self.names { ItemActs.name(.bookmark, done: false, language: $0) }
        let taken = Self.names { ItemActs.name(.bookmark, done: true, language: $0) }
        func mark(_ item: DummyItem, _ acting: ItemActing) throws -> ShellMark {
            let found = ItemActs.marks(on: item, acting: acting).first { $0.isBookmark }
            return try #require(found).mark
        }

        // No session behind the row, a read-only sign-in, no sign-in: drawn, and dim.
        let fixture = DummyItem(note(bookmarked: true))
        #expect(!Self.marks(fixture, ItemActing()).isDisjoint(with: taken))
        #expect(try mark(fixture, ItemActing()).look == .dim(.notNow))
        for scopes in [MastodonOAuth.reading, nil] {
            let (session, _) = try await shell(scopes: scopes, holding: note(bookmarked: true))
            var acting = session.acting(on: try row(session))
            acting.perform = { _ in }
            acting.ask = { _ in }
            #expect(!Self.marks(try row(session), acting).isDisjoint(with: bookmark.union(taken)), "the mark was left out")
            let drawn = try mark(try row(session), acting)
            #expect(drawn.look == .dim(ItemActs.reason(.notSignedIn)) && drawn.symbol == "bookmark")
        }

        // Signed in to act: the mark says what the source last said, and nothing else.
        for said in [true, false] {
            let (session, _) = try await shell(scopes: Self.acting, holding: note(bookmarked: said))
            var acting = session.acting(on: try row(session))
            acting.perform = { _ in }
            let drawn = Self.marks(try row(session), acting)
            #expect(!drawn.isDisjoint(with: said ? taken : bookmark))
            #expect(drawn.isDisjoint(with: said ? bookmark : taken))
            #expect(try mark(try row(session), acting).look == .live)
            #expect(try mark(try row(session), acting).drawn == (said ? "bookmark.fill" : "bookmark"))
        }

        // An earlier sign-in: the same glyph, dim, to be asked again; every other act live.
        let (session, _) = try await shell(scopes: Self.before, holding: note(bookmarked: nil))
        var acting = session.acting(on: try row(session))
        acting.perform = { _ in }
        acting.ask = { _ in }
        let drawn = Self.marks(try row(session), acting)
        #expect(!drawn.isDisjoint(with: bookmark) && drawn.isDisjoint(with: taken))
        let asking = try mark(try row(session), acting)
        #expect(asking.look == .dim(.askAgain) && asking.drawn == "bookmark", "no second glyph for the ask")
        #expect(!drawn.isDisjoint(with: Self.names { ItemActs.name(.favourite, done: false, language: $0) }))
        let favourite = try #require(ItemActs.marks(on: try row(session), acting: acting).first { $0.kind == .act(.favourite) })
        #expect(favourite.mark.look == .live)
    }

    @Test("The mark fills when the source says it is bookmarked and at the press before it answers, and is named for what a press does")
    func theMark() {
        #expect(ShellMark.drawn(ItemActs.glyph(.bookmark, standing: nil), on: false) == "bookmark")
        #expect(ShellMark.drawn(ItemActs.glyph(.bookmark, standing: nil), on: true) == "bookmark.fill")
        #expect(ShellMark.drawn(ItemActs.glyph(.bookmark, standing: .pressed(to: true)), on: true) == "bookmark.fill")
        #expect(ShellMark.drawn(ItemActs.glyph(.bookmark, standing: .failed), on: false) != "bookmark")
        #expect(ItemActs.spoken(.bookmark, done: false, standing: nil, language: .english) == "Bookmark")
        #expect(ItemActs.spoken(.bookmark, done: true, standing: nil, language: .english) == "Take the bookmark off")
        for language in [DummyLanguage.english, .taiwanese] {
            for done in [false, true] {
                let said = ItemActs.spoken(.bookmark, done: done, standing: .pressed(to: done), language: language)
                #expect(!said.contains("item.act."), "untranslated: \(said)")
            }
            let name = ItemActs.name(.bookmark, done: false, language: language)
            let asks = ShellMark.spoken(name: name, look: .dim(.askAgain), language: language)
            #expect(asks.hasPrefix(name) && asks != name, "the ask is the mark's name and its reason")
            #expect(!asks.contains("mark.dim.") && !asks.contains("%"))
        }
        // The lines a mark only the screen held used to say are gone with it.
        for key in ["item.toast.bookmark.on", "item.toast.bookmark.off"] {
            #expect(L10n.t(key, language: .english) == key && L10n.t(key, language: .taiwanese) == key)
        }
    }
}

/// The server's page, approving with the state it was sent.
@MainActor
private final class ApprovingPage: OAuthBrowser {
    func authorize(_ url: URL, callbackScheme: String) async throws -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "fediqo://oauth?code=c&state=\(state)")!
    }
}

/// A Mastodon that signs in whoever it is told the reader is, and says so at the account check.
private actor WhoServer: HTTPSender {
    private var acct: String
    /// What its Home timeline holds, as a JSON list's contents.
    private var home = ""

    init(acct: String) { self.acct = acct }

    func become(_ acct: String, home: String = "") {
        self.acct = acct
        self.home = home
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FixtureHTTPError.unmapped }
        let body: String
        switch url.path {
        case "/api/v1/accounts/verify_credentials": body = #"{"acct":"\#(acct)"}"#
        case "/api/v1/apps": body = #"{"client_id":"cid","client_secret":"csecret"}"#
        case "/oauth/token": body = #"{"access_token":"tok-\#(acct)"}"#
        case "/oauth/revoke": body = "{}"
        case "/api/v1/timelines/home": body = "[\(home)]"
        default: throw FixtureHTTPError.unmapped
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

/// A token store that cannot be read at all: a device still locked at launch.
private final class LockedTokens: MastodonTokenStore, @unchecked Sendable {
    private let locked = ForumCredentialError.keychain(-25_308)
    func token(host: String) throws -> MastodonToken? { throw locked }
    func save(_ token: MastodonToken) throws { throw locked }
    func forget(host: String) throws { throw locked }
    func forget(_ token: MastodonToken) throws -> Bool { throw locked }
    func grants() throws -> [String: MastodonGrant] { throw locked }
    func app(host: String) throws -> MastodonApp? { throw locked }
    func save(_ app: MastodonApp) throws { throw locked }
    func forgetApp(host: String) throws { throw locked }
}
