import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoPersistence
@testable import FediqoUI

/// A token store whose every look fails while it is locked — who is signed in included, as a
/// Keychain read on a locked device does.
private final class DarkTokens: MastodonTokenStore, @unchecked Sendable {
    private let held = MemoryMastodonTokens()
    private let lock = NSLock()
    private var isLocked = false

    var locked: Bool {
        get { lock.withLock { isLocked } }
        set { lock.withLock { isLocked = newValue } }
    }

    private func open() throws {
        if locked { throw ForumCredentialError.keychain(-25_308) }
    }

    func token(host: String) throws -> MastodonToken? { try open(); return try held.token(host: host) }
    func save(_ token: MastodonToken) throws { try held.save(token) }
    func forget(host: String) throws { try held.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try held.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try open(); return try held.grants() }
    func bookmarking() throws -> Set<String> { try open(); return try held.bookmarking() }
    func bookmarksRefused() throws -> Set<String> { try open(); return try held.bookmarksRefused() }
    func noticing() throws -> Set<String> { try open(); return try held.noticing() }
    func dismissing() throws -> Set<String> { try open(); return try held.dismissing() }
    func noticesRefused() throws -> Set<String> { try open(); return try held.noticesRefused() }
    func app(host: String) throws -> MastodonApp? { try held.app(host: host) }
    func save(_ app: MastodonApp) throws { try held.save(app) }
    func forgetApp(host: String) throws { try held.forgetApp(host: host) }
}

/// #323, held: the notices page draws what this device holds before anybody is asked, follows
/// the store from then on, and what is let go is off the disk.
///
/// **A relaunch is a real one as far as the store goes**: the first session's store is saved to
/// a file in a folder of its own, the file is opened again, and a second session is made over
/// what it read. Every interleaving is pinned by a gate the test opens; no clock is waited for.
@MainActor
@Suite("Notices held on this device: drawn first, read after, and let go from the disk")
struct NoticesHeldTests {
    private typealias F = NoticeActFixture
    private static let a = F.a
    private static let b = F.b

    /// A mention by `name` saying `words`: a notice that carries a post.
    private static func mention(_ id: Int, by name: String, words: String, minutes: Int, cover: String = "") -> String {
        let user = name.lowercased()
        return """
        {"id":"\(id)","type":"mention","created_at":"\(F.ago(minutes))",\
        "account":{"id":"\(id)","username":"\(user)","acct":"\(user)","display_name":"\(name)"},\
        "status":{"id":"9\(id)","uri":"https://\(a)/p/9\(id)","created_at":"\(F.ago(minutes))",\
        "content":"<p>\(words)</p>","spoiler_text":"\(cover)","sensitive":\(!cover.isEmpty),"visibility":"direct",\
        "account":{"id":"\(id)","username":"\(user)","acct":"\(user)","display_name":"\(name)"}}}
        """
    }

    /// A read from 2 minutes ago down to 9, B from 5 down to 60: B's first stretch reaches
    /// below where A's stops the list.
    private static let two: [String: NoticeActServer.Outcome] = [
        F.get(a): F.page(F.one(4, by: "Ada-Four", minutes: 2), F.one(3, by: "Bo-Three", minutes: 9)),
        F.get(b): F.page(F.one(8, by: "Cy-Eight", minutes: 5), F.one(7, by: "Di-Seven", minutes: 60)),
    ]

    private func ids(_ notices: [Notice]) -> [String] {
        notices.map { "\($0.source.host.prefix(1))\($0.newestID)" }
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Whether any file under `folder` holds `phrase` — the index, a journal, anything.
    private func disk(_ folder: URL, holds phrase: String) throws -> Bool {
        let needle = Data(phrase.utf8)
        return try FileManager.default.subpathsOfDirectory(atPath: folder.path).contains { name in
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                return false
            }
            return try Data(contentsOf: url).range(of: needle) != nil
        }
    }

    /// One run of the app over the store in `dir`: what the file holds read into a store, a
    /// session over it that saves into the file, and the sources answering `routes`.
    @MainActor
    private struct Run {
        let session: ShellSession
        let server: NoticeActServer
        let saver: StoreSaver
        var list: ShellNoticeList { session.noticeList }
    }

    private func run(
        in dir: URL, _ routes: [String: NoticeActServer.Outcome], tokens: any MastodonTokenStore,
        adopting: Bool = true, capacity: Int? = nil
    ) async throws -> Run {
        let opened = StoreFile.open(at: dir)
        let file = try #require(opened.file)
        let hosts = [Source(host: Self.a, kind: .mastodon), Source(host: Self.b, kind: .mastodon)]
        let store = ItemStore(
            sources: opened.sources.isEmpty ? hosts : opened.sources, notes: opened.notes, notices: opened.notices
        )
        let server = NoticeActServer(routes)
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        let saver = StoreSaver(store: store, file: file)
        session.persist = { try? await saver.save() }
        session.mastodon.refresh()
        if let capacity { session.noticeList.capacity = capacity }
        if adopting { await session.reloadFromStore() }
        return Run(session: session, server: server, saver: saver)
    }

    private func signedIn() throws -> MemoryMastodonTokens {
        let tokens = MemoryMastodonTokens()
        try tokens.save(F.token(Self.a, scopes: F.acts))
        try tokens.save(F.token(Self.b, scopes: F.reads))
        return tokens
    }

    /// A first run that read `routes` and saved, then ended.
    private func firstRun(in dir: URL, _ routes: [String: NoticeActServer.Outcome], tokens: any MastodonTokenStore) async throws {
        let first = try await run(in: dir, routes, tokens: tokens)
        await first.list.read(in: first.session)
        await first.list.kept()
        try await first.saver.save()
    }

    // MARK: - Drawn first

    @Test("After a relaunch the page draws what this device holds before any source is asked, with the list stopping where it stopped; a read then joins what it brings, and nothing drawn moves")
    func aRelaunchDrawsWhatIsHeld() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        try await firstRun(in: dir, Self.two, tokens: tokens)

        let gateA = Gate(), gateB = Gate()
        let again = try await run(in: dir, [
            F.get(Self.a): .held(gateA, "[" + [
                F.one(5, by: "Eve-Five", minutes: 1), F.one(4, by: "Ada-Four", minutes: 2), F.one(3, by: "Bo-Three", minutes: 9),
            ].joined(separator: ",") + "]"),
            F.get(Self.b): .held(gateB, "[" + [
                F.one(8, by: "Cy-Eight", minutes: 5), F.one(7, by: "Di-Seven", minutes: 60),
            ].joined(separator: ",") + "]"),
        ], tokens: tokens)
        let list = again.list

        #expect(ids(list.lines) == ["a4", "b8", "a3"], "drawn from this device")
        #expect(await again.server.asked.isEmpty, "and nobody was asked for it")
        #expect(list.floor != nil, "A has more below where it was read to: the list stops there from the first frame")
        #expect(list.reaches[Self.b]?.notices.map(\.newestID) == ["8", "7"], "B's older line is held, and not drawn below A's unread stretch")
        #expect(list.standing(host: Self.a) == .unread && !list.isReading)
        #expect(list.hasMore(in: again.session), "read on from where the last run stopped")
        #expect(NoticesPane.foot(in: again.session) == .more, "never an instruction to wait for a source nobody has asked")

        let reading = Task { await list.read(in: again.session) }
        #expect(await spun { await again.server.asked.count == 2 })
        #expect(await again.server.asked.sorted() == [F.get(Self.a), F.get(Self.b)], "each asked the way it answered last run")
        #expect(ids(list.lines) == ["a4", "b8", "a3"], "what is held stays drawn while they are asked")
        #expect(list.readingHosts == [Self.a, Self.b])
        #expect(NoticesPane.foot(in: again.session) == .asking, "nobody is named above, so nobody is waited for")

        await gateA.open()
        #expect(await spun { list.standing(host: Self.a) == .read })
        #expect(ids(list.lines) == ["a5", "a4", "b8", "a3"], "joined as a reload joins: the new line above, the rest where they were")
        await gateB.open()
        await reading.value
        #expect(ids(list.lines) == ["a5", "a4", "b8", "a3"])
        #expect(list.hasMore(in: again.session))
    }

    @Test("A page that reads before the store has been adopted still draws what is held before its requests leave")
    func drawnBeforeTheRequestLeaves() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        try await firstRun(in: dir, Self.two, tokens: tokens)
        let gate = Gate()
        var routes = Self.two
        routes[F.get(Self.a)] = .held(gate, "[" + F.one(4, by: "Ada-Four", minutes: 2) + "," + F.one(3, by: "Bo-Three", minutes: 9) + "]")
        let again = try await run(in: dir, routes, tokens: tokens, adopting: false)
        #expect(again.list.lines.isEmpty, "the premise: nothing has adopted the store")

        let reading = Task { await again.list.read(in: again.session) }
        #expect(await spun { await again.server.count(F.get(Self.a)) == 1 })

        #expect(ids(again.list.lines) == ["a4", "b8", "a3"])
        await gate.open()
        await reading.value
        #expect(ids(again.list.lines) == ["a4", "b8", "a3"])
    }

    @Test("A source with nothing held is on its first stretch as before: its lines wait for it, and what is held of the other stays drawn")
    func aSourceNewToTheListWaits() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = MemoryMastodonTokens()
        try tokens.save(F.token(Self.a, scopes: F.acts))
        try await firstRun(in: dir, Self.two, tokens: tokens)
        // B is signed in to between the runs: nothing is held of it.
        try tokens.save(F.token(Self.b, scopes: F.reads))
        let gate = Gate()
        var routes = Self.two
        routes[F.get(Self.b)] = .held(gate, "[" + F.one(8, by: "Cy-Eight", minutes: 5) + "]")
        let again = try await run(in: dir, routes, tokens: tokens)
        #expect(ids(again.list.lines) == ["a4", "a3"])

        let reading = Task { await again.list.read(in: again.session) }
        #expect(await spun { again.list.standing(host: Self.a) == .read })
        #expect(ids(again.list.lines) == ["a4", "a3"], "nothing drawn is taken back, and nothing of B is drawn before it has said where it stops")
        await gate.open()
        await reading.value
        #expect(ids(again.list.lines) == ["a4", "b8"], "B has more below five minutes ago, and stops the list there")
        #expect(again.list.reaches[Self.a]?.notices.count == 2)
    }

    @Test("A notice dismissed elsewhere between two runs is drawn from this device, goes at the next read, and is then off the disk")
    func dismissedElsewhere() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        try await firstRun(in: dir, Self.two, tokens: tokens)
        var routes = Self.two
        routes[F.get(Self.a)] = F.page(F.one(4, by: "Ada-Four", minutes: 2), F.one(2, by: "Flo-Two", minutes: 12))
        let again = try await run(in: dir, routes, tokens: tokens)
        #expect(ids(again.list.lines).contains("a3"))
        #expect(try disk(dir, holds: "Bo-Three"))

        await again.list.read(in: again.session)
        await again.list.kept()
        try await again.saver.save()

        #expect(again.list.reaches[Self.a]?.notices.map(\.newestID) == ["4", "2"])
        #expect(await again.session.store.noticesHeld().notices.first?.notices.map(\.newestID) == ["4", "2"])
        #expect(try !disk(dir, holds: "Bo-Three"))
    }

    @Test("The post a notice is about is drawn from this device after a relaunch, covered where it was, and is no item until it is opened")
    func theCarriedPost() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        let routes = [
            F.get(Self.a): F.page(Self.mention(4, by: "Gil", words: "words-only-for-me", minutes: 2, cover: "about lunch")),
            F.get(Self.b): F.page(),
        ]
        try await firstRun(in: dir, routes, tokens: tokens)

        let again = try await run(in: dir, routes, tokens: tokens)

        let post = try #require(again.list.lines.first?.post)
        #expect(post.body.contains("words-only-for-me"))
        #expect(post.spoiler == "about lunch" && post.sensitive == true, "covered still")
        #expect(await again.session.store.all().isEmpty, "carried in its line, and in no timeline")
        #expect(again.session.notes.isEmpty)
    }

    // MARK: - The list follows the store

    @Test("A post let go is struck from the notice that carried it by itself, through the store's own word; and a line dismissed in the same moment does not put it back")
    func theListFollowsTheStore() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        let routes = [
            F.get(Self.a): F.page(
                Self.mention(4, by: "Gil", words: "marrow-thistle-words", minutes: 2), F.one(3, by: "Bo-Three", minutes: 9)
            ),
            F.get(Self.b): F.page(),
        ]
        let here = try await run(in: dir, routes, tokens: tokens)
        let list = here.list
        await list.read(in: here.session)
        await list.kept()
        let post = try #require(list.lines.first?.post)
        let three = try #require(list.lines.last)

        // The store strikes it, and before the list has heard, a line is dismissed: the
        // list's copy still carries the post when it is written back.
        await here.session.store.forget(post.key)
        #expect(list.lines.first?.post != nil, "the premise: the list has not been told yet")
        list.took(three)
        await list.kept()

        #expect(await here.session.store.noticesHeld().notices.first?.notices.map { $0.post == nil } == [true], "a copy of what was held put the words back")
        #expect(ids(list.lines) == ["a4"])
        #expect(list.lines.first?.post == nil, "and the list has taken the store's word")
        try await here.saver.save()
        #expect(try !disk(dir, holds: "marrow-thistle-words"))

        // And with the store followed, as the app follows it, nothing has to be asked for.
        await list.read(in: here.session)
        await list.kept()
        let following = Task { await here.session.followStore() }
        defer { following.cancel() }
        #expect(await spun { list.lines.first?.post != nil }, "a read brings it back where the source still serves it")
        let again = try #require(list.lines.first?.post)
        await here.session.store.forget(again.key)
        #expect(await spun { list.lines.first?.post == nil })
        #expect(ids(list.lines) == ["a4", "a3"], "the lines stay")
    }

    @Test("A store's word read while a write of the list's is still out is not taken over it")
    func aStaleWordIsNotTaken() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        let routes = [
            F.get(Self.a): F.page(
                Self.mention(4, by: "Gil", words: "marrow-thistle-words", minutes: 2), F.one(3, by: "Bo-Three", minutes: 9)
            ),
            F.get(Self.b): F.page(),
        ]
        let here = try await run(in: dir, routes, tokens: tokens)
        let list = here.list
        await list.read(in: here.session)
        await list.kept()
        let post = try #require(list.lines.first?.post)
        let three = try #require(list.lines.last)
        // The store moves by another road, so what it holds of A is not what the list last took…
        await here.session.store.forget(post.key)

        // …and a line is dismissed: its write is out while the store is read, and what is
        // read still names the line.
        list.took(three)
        await list.follow(in: here.session)

        #expect(list.reaches[Self.a]?.notices.map(\.newestID) == ["4"], "the dismissed line came back from a store not yet told")
        await list.kept()
        #expect(list.reaches[Self.a]?.notices.map(\.newestID) == ["4"])
        #expect(list.reaches[Self.a]?.notices.first?.post == nil, "and once the write has landed, the store's own change is taken")
    }

    @Test("A post struck while a read is on the wire stays struck when that read fails: what the read is put back to is what the store holds")
    func struckWhileAReadIsOut() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        let routes = [
            F.get(Self.a): F.page(Self.mention(4, by: "Gil", words: "marrow-thistle-words", minutes: 2)),
            F.get(Self.b): F.page(),
        ]
        let here = try await run(in: dir, routes, tokens: tokens)
        let list = here.list
        await list.read(in: here.session)
        await list.kept()
        let post = try #require(list.lines.first?.post)
        let gate = Gate()
        await here.server.set(F.get(Self.a), .fails(gate, .notConnectedToInternet))

        let reading = Task { await list.read(in: here.session) }
        #expect(await spun { await here.server.count(F.get(Self.a)) == 2 })
        await here.session.store.forget(post.key)
        await here.session.reloadFromStore()
        #expect(list.lines.first?.post == nil, "the premise: taken while the read is out")
        await gate.open()
        await reading.value

        #expect(list.standing(host: Self.a) == .failed(.unreachable))
        #expect(ids(list.lines) == ["a4"])
        #expect(list.lines.first?.post == nil, "the failed read put back what the store had let go")
    }

    // MARK: - Let go

    @Test("A sign-out leaves none of that source's notices in the list, the store or the file by the time it returns; another source's stay")
    func signOutLeavesNoneOnDisk() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        let routes = [
            F.get(Self.a): F.page(Self.mention(4, by: "Gil-Four", words: "words-only-for-me", minutes: 2)),
            F.get(Self.b): F.page(F.one(8, by: "Cy-Eight", minutes: 5)),
        ]
        try await firstRun(in: dir, routes, tokens: tokens)
        let again = try await run(in: dir, routes, tokens: tokens)
        #expect(try disk(dir, holds: "words-only-for-me") && disk(dir, holds: "Gil-Four"), "the premise")

        await again.session.signOut(host: Self.a)

        #expect(try !disk(dir, holds: "words-only-for-me"))
        #expect(try !disk(dir, holds: "Gil-Four"))
        #expect(try disk(dir, holds: "Cy-Eight"))
        #expect(ids(again.list.lines) == ["b8"])
        #expect(await again.session.store.noticesHeld().notices.map(\.host) == [Self.b])
    }

    @Test("A sign-in its server ended, found by the notices read, leaves none of that reader's notices in the list, the store or the file")
    func endedByTheServer() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        let routes = [
            F.get(Self.a): F.page(Self.mention(4, by: "Gil-Four", words: "words-only-for-me", minutes: 2)),
            F.get(Self.b): F.page(F.one(8, by: "Cy-Eight", minutes: 5)),
        ]
        try await firstRun(in: dir, routes, tokens: tokens)
        var ended = routes
        ended[F.get(Self.a)] = .status(401)
        ended[F.get(Self.a, "/api/v1/accounts/verify_credentials")] = .status(401)
        let again = try await run(in: dir, ended, tokens: tokens)
        #expect(try disk(dir, holds: "words-only-for-me"), "the premise")

        await again.list.read(in: again.session)
        await again.session.saved()

        #expect(!again.session.mastodon.isSignedIn(host: Self.a), "the premise: the server ended it")
        #expect(ids(again.list.lines) == ["b8"])
        #expect(await again.session.store.noticesHeld().notices.map(\.host) == [Self.b])
        #expect(try !disk(dir, holds: "words-only-for-me"))
        #expect(try !disk(dir, holds: "Gil-Four"))
        #expect(try disk(dir, holds: "Cy-Eight"))
    }

    @Test("A write of the list's still on its way when its reader's notices are let go does not put them back in the store")
    func aWriteAfterTheLettingGo() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let here = try await run(in: dir, Self.two, tokens: try signedIn())
        let list = here.list
        await list.read(in: here.session)
        await list.kept()
        await here.session.reloadFromStore()
        let three = try #require(list.lines.last)

        // The write is asked for and has not run; the store lets the reader's notices go
        // first — the order a sign-out, a Clear or another account can fall in.
        list.took(three)
        await here.session.store.forgetReaderMarks(host: Self.a)
        await list.kept()

        #expect(await here.session.store.noticesHeld().notices.map(\.host) == [Self.b], "the gone reader's notices came back")
        try await here.saver.save()
        #expect(try !disk(dir, holds: "Ada-Four"))
    }

    @Test("A source at the bound keeps where it stopped: a dismissal makes room and reading on resumes from there; it is still full after a relaunch; and a read from the top across a gap starts it again")
    func theBoundAcrossRuns() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        let routes: [String: NoticeActServer.Outcome] = [
            F.get(Self.a): F.page(F.one(4, by: "Ada-Four", minutes: 2), F.one(3, by: "Bo-Three", minutes: 9)),
            F.get(Self.a) + "?older": F.page(F.one(2, by: "Cy-Two", minutes: 12), F.one(1, by: "Di-One", minutes: 15)),
            F.get(Self.b): F.page(),
        ]
        let first = try await run(in: dir, routes, tokens: tokens, capacity: 3)
        await first.list.read(in: first.session)
        await first.list.readOn(in: first.session)
        #expect(ids(first.list.lines) == ["a4", "a3", "a2"])
        #expect(first.list.isFull && first.list.reaches[Self.a]?.before == "2", "full, and where it stopped is kept")
        await first.list.kept()
        try await first.saver.save()

        // The next run: still at the bound, and said so.
        let again = try await run(in: dir, routes, tokens: tokens, capacity: 3)
        let list = again.list
        #expect(ids(list.lines) == ["a4", "a3", "a2"])
        #expect(list.isFull && NoticesPane.foot(in: again.session) == .full)
        #expect(NoticesPane.lines(in: again.session).contains(.full(host: Self.a)))
        await list.readOn(in: again.session)
        #expect(await again.server.asked.isEmpty, "a source at the bound was read on")

        // A dismissal makes room: no longer full, and reading on brings what lay below the bound.
        list.took(try #require(list.lines.first { $0.newestID == "3" }))
        #expect(!list.isFull && list.hasMore(in: again.session))
        #expect(NoticesPane.foot(in: again.session) == .more)
        await again.server.set(F.get(Self.a) + "?older", F.page(F.one(1, by: "Di-One", minutes: 15)))
        await list.readOn(in: again.session)
        #expect(ids(list.lines) == ["a4", "a2", "a1"], "nothing between the bound and what reading on brought")
        #expect(list.isFull, "and at the bound again, with more below")

        // A read from the top joined to nothing held starts the source again.
        await again.server.set(F.get(Self.a), F.page(F.one(20, by: "Eve", minutes: 0), F.one(19, by: "Flo", minutes: 1)))
        await list.read(in: again.session)
        #expect(ids(list.lines) == ["a20", "a19"])
        #expect(!list.isFull && NoticesPane.foot(in: again.session) == .more)
    }

    @Test("Reading stops at the months limit and the foot says so; nothing is asked past it; the page, Usage and the file agree; and a longer limit offers reading on again from where it stopped")
    func nothingPastTheLimitIsDrawn() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let routes = [
            F.get(Self.a): F.page(F.one(4, by: "Ada-Four", minutes: 2), F.one(3, by: "Old-Three", minutes: 60 * 24 * 100)),
            F.get(Self.b): F.page(),
        ]
        let here = try await run(in: dir, routes, tokens: try signedIn())
        await here.session.keep(months: 1)

        await here.list.read(in: here.session)

        #expect(ids(here.list.lines) == ["a4"], "what the person set is true on screen")
        #expect(here.list.reaches[Self.a]?.notices.count == 1, "and nothing past it is held")
        #expect(!here.list.hasMore(in: here.session) && here.list.isAtLimit)
        #expect(here.list.reaches[Self.a]?.before == "4", "where it stopped is the oldest line kept, not below what was left out")
        #expect(NoticesPane.foot(in: here.session) == .limit)
        #expect(NoticesFoot.limit.words(language: .english) == "Older notices are not read: they are older than the latest months Keep posts holds.")
        #expect(NoticesFoot.limit.words(language: .taiwanese) == "不再讀取更早的通知：它們比「保留貼文」留下的月數還舊。")
        let asked = await here.server.asked.count
        await here.list.readOn(in: here.session)
        #expect(await here.server.asked.count == asked, "a press that could bring nothing drawn asked a source")

        // The page, Usage and the file: one rule.
        await here.list.kept()
        await here.session.reloadFromStore()
        try await here.saver.save()
        #expect(here.session.noticesHeld[Self.a] == 1)
        #expect(await here.session.store.noticesHeld().notices.first?.notices.count == 1)
        #expect(try !disk(dir, holds: "Old-Three") && disk(dir, holds: "Ada-Four"))

        // A longer limit: read on again from where it stopped, with nothing between unread.
        await here.server.set(F.get(Self.a) + "?older", F.page(F.one(3, by: "Old-Three", minutes: 60 * 24 * 100)))
        await here.session.keep(months: 12)
        #expect(here.list.hasMore(in: here.session) && NoticesPane.foot(in: here.session) == .more)
        await here.list.readOn(in: here.session)
        #expect(ids(here.list.lines) == ["a4", "a3"])
    }

    @Test("Removing a source while an adopt of the store is in flight still leaves none of its notices on disk by the time it returns")
    func removeWhileFollowed() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        try await firstRun(in: dir, Self.two, tokens: tokens)
        let again = try await run(in: dir, Self.two, tokens: tokens)
        // An adopt at every change of the store, as the app's is: the removal's own is in
        // flight, and has read the store, before the removal goes on.
        let following = Task { await again.session.followStore() }
        defer { following.cancel() }
        for _ in 0..<200 { await Task.yield() }

        await again.session.remove(host: Self.a)

        #expect(try !disk(dir, holds: "Ada-Four"))
        #expect(try disk(dir, holds: "Cy-Eight"))
    }

    @Test("A source whose newest notice is already older than the months limit has more, and the foot says the limit is why none is read — not that every source has sent all it has")
    func everythingIsPastTheLimit() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let routes = [
            F.get(Self.a): F.page(F.one(3, by: "Old-Three", minutes: 60 * 24 * 100)),
            F.get(Self.b): F.page(),
        ]
        let here = try await run(in: dir, routes, tokens: try signedIn())
        await here.session.keep(months: 1)

        await here.list.read(in: here.session)

        #expect(here.list.lines.isEmpty && here.list.reaches[Self.a]?.notices.isEmpty == true)
        #expect(here.list.isAtLimit && !here.list.hasMore(in: here.session))
        #expect(NoticesPane.foot(in: here.session) == .limit)
    }

    @Test("The first stretch read for whoever signs in next is written as theirs, though nothing has adopted the store since the last reader's notices were let go")
    func theNextReadersFirstStretch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        let here = try await run(in: dir, Self.two, tokens: tokens)
        await here.list.read(in: here.session)
        await here.list.kept()
        await here.session.reloadFromStore()

        // A's sign-in ends and is swept, with no adopt after it — as a server-ended one is.
        try tokens.forget(host: Self.a)
        here.session.mastodon.refresh()
        await here.session.forgetReaderMarksDue()
        #expect(await here.session.store.noticesHeld().notices.map(\.host) == [Self.b], "the premise")

        // Somebody signs in there, and the page reads before anything else has happened.
        try tokens.save(F.token(Self.a, scopes: F.acts, access: "tok-new"))
        here.session.mastodon.refresh()
        await here.list.read(in: here.session)
        await here.list.kept()

        #expect(await here.session.store.noticesHeld().notices.map(\.host) == [Self.a, Self.b], "refused as the last reader's")
        #expect(here.list.reaches[Self.a]?.notices.count == 2)
    }

    @Test("A sweep of changed readers asked for while one is still writing waits for that write: nobody is told it is done while the file still holds what went")
    func aSecondSweepWaitsForTheFirst() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        try await firstRun(in: dir, Self.two, tokens: tokens)
        let again = try await run(in: dir, Self.two, tokens: tokens)
        let gate = Gate()
        var writing = false
        let saver = again.saver
        again.session.persist = {
            writing = true
            await gate.wait()
            try? await saver.save()
        }
        // A's sign-in goes, and the first sweep takes it and is held at its write.
        try tokens.forget(host: Self.a)
        again.session.mastodon.refresh()
        let first = Task { await again.session.forgetReaderMarksDue() }
        #expect(await spun { writing })

        var done = false
        let second = Task {
            await again.session.forgetReaderMarksDue()
            done = true
        }
        for _ in 0..<2_000 { await Task.yield() }
        #expect(!done, "the second caller was told while the first was still writing")
        #expect(try disk(dir, holds: "Ada-Four"), "the premise: not written yet")

        await gate.open()
        await first.value
        await second.value
        #expect(try !disk(dir, holds: "Ada-Four"))
    }

    @Test("Removing a source leaves none of its notices on disk by the time it returns, posts kept or not")
    func removeLeavesNoneOnDisk() async throws {
        for keepingPosts in [false, true] {
            let dir = scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            // Nobody is signed in to B any more by the launch's own sweep; A is the one removed.
            let tokens = try signedIn()
            try await firstRun(in: dir, Self.two, tokens: tokens)
            let again = try await run(in: dir, Self.two, tokens: tokens)
            #expect(try disk(dir, holds: "Ada-Four"), "the premise")

            await again.session.remove(host: Self.a, keepingPosts: keepingPosts)

            #expect(try !disk(dir, holds: "Ada-Four"), "keeping posts: \(keepingPosts)")
            #expect(try disk(dir, holds: "Cy-Eight"))
            #expect(ids(again.list.lines) == ["b8", "b7"])
        }
    }

    @Test("A launch that finds nobody signed in to a source lets go of what was held of it, from the file too")
    func aSignInGoneBetweenRuns() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        try await firstRun(in: dir, Self.two, tokens: tokens)
        try tokens.forget(host: Self.a)

        let again = try await run(in: dir, Self.two, tokens: tokens)

        #expect(ids(again.list.lines) == ["b8", "b7"])
        #expect(try !disk(dir, holds: "Ada-Four"), "waited for, as a signed-out reader's marks are")
    }

    @Test("A Keychain that cannot be read is not everybody leaving: nothing held is let go, in the list, the store or the file")
    func aLockedKeychainLetsNothingGo() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = DarkTokens()
        try tokens.save(F.token(Self.a, scopes: F.acts))
        try tokens.save(F.token(Self.b, scopes: F.reads))
        try await firstRun(in: dir, Self.two, tokens: tokens)
        let again = try await run(in: dir, Self.two, tokens: tokens)
        #expect(ids(again.list.lines) == ["a4", "b8", "a3"])

        // The device locks, the app comes to the front, and the page reads.
        tokens.locked = true
        again.session.mastodon.refresh()
        #expect(!again.session.mastodon.grantsKnown, "the premise")
        await again.list.read(in: again.session)
        await again.session.reloadFromStore()
        await again.list.kept()
        try await again.saver.save()

        #expect(ids(again.list.lines) == ["a4", "b8", "a3"])
        #expect(await again.session.store.noticesHeld().notices.map(\.host) == [Self.a, Self.b])
        #expect(try disk(dir, holds: "Ada-Four"))

        // And a launch on a locked device draws nothing it cannot say is this reader's, and lets none go.
        let dark = try await run(in: dir, Self.two, tokens: tokens)
        await dark.list.read(in: dark.session)
        #expect(dark.list.lines.isEmpty)
        #expect(await dark.session.store.noticesHeld().notices.count == 2)
        #expect(dark.session.noticesHeld == [Self.a: 2, Self.b: 2], "Usage still says what the disk holds")
        tokens.locked = false
        dark.session.mastodon.refresh()
        await dark.session.reloadFromStore()
        #expect(ids(dark.list.lines) == ["a4", "b8", "a3"])
    }

    @Test("A notice dismissed leaves the screen at the yes, and once its source has said yes its words are off the disk before the act is over; a stretch that only landed waits for no save")
    func aDismissalIsOffTheDisk() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate()
        var routes = Self.two
        routes[F.post(Self.a, "/api/v1/notifications/4/dismiss")] = .held(gate, "{}")
        let here = try await run(in: dir, routes, tokens: try signedIn())
        var saves = 0
        let saver = here.saver
        here.session.persist = {
            saves += 1
            try? await saver.save()
        }
        let list = here.list
        await list.read(in: here.session)
        await list.kept()
        await here.session.saved()
        #expect(saves == 0, "a page read is saved by the follower, with nobody asking")
        try await saver.save()
        #expect(try disk(dir, holds: "Ada-Four"), "the premise: written")
        let four = try #require(list.lines.first)

        let act = Task { await list.acts.dismiss(four, in: here.session) }
        #expect(await spun { !ids(list.lines).contains("a4") }, "off the screen at the yes")
        #expect(try disk(dir, holds: "Ada-Four"), "and nothing on this device moved before the source answered")
        await gate.open()
        await act.value
        await here.session.saved()

        #expect(saves == 1)
        #expect(try !disk(dir, holds: "Ada-Four"))
        #expect(try disk(dir, holds: "Bo-Three"))
        #expect(here.session.said.lines.isEmpty, "nothing new is said to the person")
    }

    @Test("Usage counts the notices held of a source, and none where none is held")
    func usageCountsThem() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let here = try await run(in: dir, Self.two, tokens: try signedIn())
        let a = try #require(here.session.sources.first { $0.host == Self.a })
        #expect(UsageSourceDetail.notices(a, in: here.session) == 0)

        await here.list.read(in: here.session)
        await here.list.kept()
        await here.session.reloadFromStore()

        #expect(UsageSourceDetail.notices(a, in: here.session) == 2)
        #expect(L10n.count("prefs.cache.notices", 2, language: .english) == "2 notices")
        #expect(L10n.count("prefs.cache.notices", 1, language: .english) == "1 notice")
        #expect(L10n.count("prefs.cache.notices", 2, language: .taiwanese) == "2 則通知")
    }

    @Test("The months limit lets notices older than it go, from the list and from the file, by the time it returns")
    func theMonthsLimit() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = try signedIn()
        let routes = [
            F.get(Self.a): F.page(F.one(4, by: "Ada-Four", minutes: 2), F.one(3, by: "Old-Three", minutes: 60 * 24 * 100)),
            F.get(Self.b): F.page(),
        ]
        try await firstRun(in: dir, routes, tokens: tokens)
        let again = try await run(in: dir, routes, tokens: tokens)
        #expect(ids(again.list.lines) == ["a4", "a3"])
        #expect(try disk(dir, holds: "Old-Three"), "the premise")

        #expect(await again.session.keep(months: 1) == 0, "no post went: a notice is not counted as one")

        #expect(try !disk(dir, holds: "Old-Three"))
        #expect(try disk(dir, holds: "Ada-Four"))
        await again.session.reloadFromStore()
        #expect(ids(again.list.lines) == ["a4"])
    }
}
