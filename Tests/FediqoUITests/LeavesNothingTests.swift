import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #221: signing out of a source, or removing it, leaves nothing that can reach it.
///
/// What "reaches it" means here is what the run's record (#218) says: every piece of work that
/// goes out to a source is written there, under that source, as it starts. So each test here
/// catches work for a source **on its way or queued** as the source is removed, lets it go on,
/// and asks the record whether anything new was written under that source after the removal.
///
/// Every test builds its own `SourceWork`, stores and caches; nothing here touches the app's
/// shared ones, the Keychain, the network or the language of the shell.
@MainActor
@Suite("Signing out or removing leaves nothing", .serialized)
struct LeavesNothingTests {
    private static let gone = "gone.example"
    private static let kept = "kept.example"

    /// The acts the record holds for `source`.
    private static func acts(_ work: SourceWork, for source: String) -> [SourceAct] {
        work.record.filter { $0.source == source }
    }

    private static func mastodonRoutes(_ host: String) -> [String: FixtureHTTP.Outcome] {
        [
            MastodonInstance.address(host): MastodonInstance.mastodon(host),
            "https://\(host)/api/v1/timelines/public": .text("[]"),
            "https://\(host)/api/v1/trends/statuses": .text("[]"),
        ]
    }

    private static func session(
        http: any HTTPClient, store: ItemStore = ItemStore(), work: SourceWork
    ) -> ShellSession {
        let session = ShellSession(
            http: http, store: store,
            pictures: ShellPictures(http: FixtureHTTP()),
            emojis: EmojiCache(http: FixtureHTTP()),
            forums: ForumSessions(credentials: MemoryCredentials()),
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: Unsent()),
            posts: ForumPosts(http: http)
        )
        session.work = work
        session.jar = SystemJar(cookies: Self.jar())
        return session
    }

    /// A cookie store of this test's own, so nothing here writes to the process's shared one.
    private static func jar() -> HTTPCookieStorage {
        HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "fediqo.tests.\(UUID())")
    }

    // MARK: - Removing stops what is on its way

    @Test("A reload on its way to a removed source asks nothing more of it, and names no failure for it",
          .timeLimit(.minutes(1)))
    func aReloadOnItsWay() async {
        let work = SourceWork()
        // The public timeline is held on the wire; its trends would be asked right after it.
        let http = GatedHTTP(Self.mastodonRoutes(Self.gone), holding: "/api/v1/timelines/public")
        let watchdog = hangGuard(http.gate)
        defer { watchdog.cancel() }
        let store = ItemStore()
        await store.add(Source(host: Self.gone, kind: .mastodon))
        let session = Self.session(http: http, store: store, work: work)
        await session.reloadFromStore()

        let reloading = Task { await session.reload.held(in: session) }
        #expect(await spun { await http.asks == 1 }, "the premise: the read is on the wire")
        let before = Self.acts(work, for: Self.gone).count
        #expect(before >= 1)

        await session.remove(host: Self.gone)
        await http.gate.open()
        await reloading.value

        #expect(Self.acts(work, for: Self.gone).count == before, "the removed source was asked again")
        #expect(await !http.requested().contains { $0.contains("/trends/") }, "its trends went out")
        #expect(session.reload.failures[.held]?.contains(Self.gone) != true)
    }

    @Test("A forum's next board is not read once the forum is removed", .timeLimit(.minutes(1)))
    func aForumsNextBoard() async {
        let work = SourceWork()
        let host = SubBoardChoiceTests.host
        let http = GatedHTTP(SubBoardChoiceTests.routes, holding: SubBoardChoiceTests.read(434))
        let watchdog = hangGuard(http.gate)
        defer { watchdog.cancel() }
        let store = ItemStore()
        await store.add(Source(host: host, kind: .discuz, boards: [
            BoardSubscription(fid: 434, name: "Child"), BoardSubscription(fid: 40, name: "Neighbour"),
        ]))
        let session = Self.session(http: http, store: store, work: work)
        await session.reloadFromStore()

        let reloading = Task { await session.reload.timeline(.all, in: session) }
        #expect(await spun { await http.asks == 1 }, "the premise: the first board is on the wire")
        let before = Self.acts(work, for: host).count

        await session.remove(host: host)
        await http.gate.open()
        await reloading.value

        #expect(await !http.requested().contains(SubBoardChoiceTests.read(40)), "the second board was read")
        #expect(Self.acts(work, for: host).count == before)
    }

    @Test("The wait asks nothing of a removed source, round after round, and asks it again once it is added back",
          .timeLimit(.minutes(1)))
    func theWait() async {
        let work = SourceWork()
        let http = FixtureHTTP(Self.mastodonRoutes(Self.gone).merging(Self.mastodonRoutes(Self.kept)) { a, _ in a })
        let store = ItemStore()
        await store.add(Source(host: Self.gone, kind: .mastodon))
        await store.add(Source(host: Self.kept, kind: .mastodon))
        let session = Self.session(http: http, store: store, work: work)
        await session.reloadFromStore()

        // Round one reads both; the source goes as the second wait begins; rounds two to six run
        // with it gone; the seventh wait ends the loop.
        final class Rounds { var count = 0; var removedAt = 0 }
        let rounds = Rounds()
        await session.reload.keepAsking(every: .seconds(60), in: session) { _ in
            rounds.count += 1
            if rounds.count == 2 {
                await session.remove(host: Self.gone)
                rounds.removedAt = Self.acts(work, for: Self.gone).count
            }
            if rounds.count > 6 { throw CancellationError() }
        }

        #expect(rounds.removedAt > 0, "the premise: the first round asked it")
        #expect(Self.acts(work, for: Self.gone).count == rounds.removedAt, "a wait asked the removed source")
        #expect(Self.acts(work, for: Self.kept).count > rounds.removedAt, "the source still held was asked each round")

        // Added again, it is asked again as before.
        await store.add(Source(host: Self.gone, kind: .mastodon))
        await session.reloadFromStore()
        await session.reload.held(in: session)
        #expect(Self.acts(work, for: Self.gone).count > rounds.removedAt, "adding it back did not reach it")
    }

    @Test("An open thread from a removed source is not renewed on the wait")
    func anOpenThread() async {
        let work = SourceWork()
        let http = FixtureHTTP(Self.mastodonRoutes(Self.gone))
        let store = ItemStore()
        let source = Source(host: Self.gone, kind: .mastodon)
        await store.add(source)
        let session = Self.session(http: http, store: store, work: work)
        await session.reloadFromStore()
        let item = DummyItem(Note(
            id: "https://\(Self.gone)/users/ada/statuses/9", source: source, author: "Ada",
            handle: "@ada@\(Self.gone)", body: "open", postedAt: .distantPast, categories: []
        ))
        session.reload.inFront = item

        await session.remove(host: Self.gone)
        let before = Self.acts(work, for: Self.gone).count
        #expect(session.reload.inFront?.id == item.id, "the premise: its pane is still up")
        #expect(await session.reload.renew(in: session) == nil)
        #expect(Self.acts(work, for: Self.gone).count == before)
    }

    // MARK: - Removing stops what is queued

    @Test("A picture queued for a removed source never goes out", .timeLimit(.minutes(1)))
    func aQueuedPicture() async {
        let work = SourceWork()
        let http = Parking()
        let watchdog = hangGuard(http.gate)
        defer { watchdog.cancel() }
        let pictures = ShellPictures(http: http)
        pictures.work = work
        let filling = (0..<ShellPictures.maxInFlight).map { index in
            Task { await pictures.fetch(Self.address("kept-\(index)"), scale: 2, tier: .deck, host: Self.kept) }
        }
        #expect(await spun { await http.asked.count == ShellPictures.maxInFlight }, "the premise: every slot is taken")
        let queued = Task { await pictures.fetch(Self.address("gone"), scale: 2, tier: .deck, host: Self.gone) }
        await Task.yield()

        pictures.forget(host: Self.gone)
        await http.gate.open()
        for task in filling { await task.value }
        await queued.value

        #expect(await !http.asked.contains(Self.address("gone")), "the queued picture went out")
        #expect(Self.acts(work, for: Self.gone).isEmpty)
        #expect(Self.acts(work, for: Self.kept).count == ShellPictures.maxInFlight)
    }

    @Test("An emoji queued for a removed source never goes out", .timeLimit(.minutes(1)))
    func aQueuedEmoji() async {
        let work = SourceWork()
        let http = Parking()
        let watchdog = hangGuard(http.gate)
        defer { watchdog.cancel() }
        let emojis = EmojiCache(http: http)
        emojis.work = work
        let request = { (host: String, names: [String]) in
            EmojiCache.Request(
                emojis: names.map { CustomEmoji(shortcode: $0, url: Self.address($0), staticURL: nil) },
                metrics: .init(side: 20, baseline: -4), scale: 2, host: host, still: false
            )
        }
        let filling = Task {
            await emojis.fetch(request(Self.kept, (0..<EmojiCache.maxInFlight).map { "kept\($0)" }))
        }
        #expect(await spun { await http.asked.count == EmojiCache.maxInFlight }, "the premise: every slot is taken")
        let queued = Task { await emojis.fetch(request(Self.gone, ["gone"])) }
        await Task.yield()

        emojis.forget(host: Self.gone)
        await http.gate.open()
        await filling.value
        await queued.value

        #expect(await !http.asked.contains(Self.address("gone")), "the queued emoji went out")
        #expect(Self.acts(work, for: Self.gone).isEmpty)
    }

    @Test("A forum post queued for a removed forum never goes out", .timeLimit(.minutes(1)))
    func aQueuedForumPost() async {
        let work = SourceWork()
        let http = Parking()
        let watchdog = hangGuard(http.gate)
        defer { watchdog.cancel() }
        let posts = ForumPosts(http: http)
        posts.work = work
        let filling = (0..<ForumPosts.maxInFlight).map { index in
            Task { await posts.fetch(ForumThreadRef(host: Self.kept, tid: index + 1)) }
        }
        #expect(await spun { await http.asked.count == ForumPosts.maxInFlight }, "the premise: every slot is taken")
        let queued = Task { await posts.fetch(ForumThreadRef(host: Self.gone, tid: 99)) }
        await Task.yield()

        posts.forget(host: Self.gone)
        await http.gate.open()
        for task in filling { await task.value }
        await queued.value

        #expect(await !http.asked.contains { $0.host() == Self.gone }, "the queued post went out")
        #expect(Self.acts(work, for: Self.gone).isEmpty)
    }

    // MARK: - Nothing left that can sign in

    @Test("A forum's launch sign-in still running is ended by a sign-out, and signs nothing back in",
          .timeLimit(.minutes(1)))
    func aLaunchSignIn() async throws {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: Self.gone, username: "reader", password: "p"))
        let forums = ForumSessions(credentials: credentials)
        forums.work = SourceWork()
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }

        forums.signInAgain(hosts: [Self.gone]) { _ in
            await gate.wait()
            return .signedIn
        }
        #expect(forums.isSigningInAgain(host: Self.gone), "the premise: it is running")

        await forums.forget(host: Self.gone)
        #expect(!forums.isSigningInAgain(host: Self.gone))
        await gate.open()
        await Task.yield()

        #expect(!forums.reachedSignIn(host: Self.gone), "the sign-in landed after the sign-out")
        #expect(forums.notice(host: Self.gone) == nil)
        #expect(try credentials.credential(host: Self.gone) == nil, "the password stayed")
        #expect(forums.signIns(host: Self.gone) == 0)
    }

    @Test("Signing out leaves no cookie or kept credential for that source in the system's stores",
          arguments: [ProtocolKind.mastodon, .discuz, .discourse])
    func theSystemsStores(kind: ProtocolKind) async throws {
        let session = Self.session(http: FixtureHTTP(), work: SourceWork())
        await session.store.add(Source(host: Self.gone, kind: kind))
        await session.reloadFromStore()
        let jar = session.jar.cookies
        for (name, domain) in [("sid", Self.gone), ("guest", ".gone.example"), ("sid", Self.kept)] {
            jar.setCookie(try #require(HTTPCookie(properties: [
                .name: name, .value: "v", .domain: domain, .path: "/",
            ])))
        }
        let space = URLProtectionSpace(
            host: Self.gone, port: 443, protocol: "https", realm: "r\(kind)",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        session.jar.credentials.set(
            URLCredential(user: "reader", password: "p", persistence: .forSession), for: space
        )

        await session.signOut(host: Self.gone)

        #expect(jar.cookies?.map(\.domain) == [Self.kept], "a cookie for the source outlived its sign-out")
        #expect(session.jar.credentials.credentials(for: space)?.isEmpty ?? true)
    }

    // MARK: - Helpers

    nonisolated private static func address(_ name: String) -> URL {
        URL(string: "https://cdn.example.test/\(name)")!
    }
}

/// Holds every request until the test opens the gate, then answers 404. What was asked is noted
/// as it is asked, in front of the gate.
private actor Parking: HTTPClient {
    let gate = Gate()
    private(set) var asked: [URL] = []

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        asked.append(url)
        await gate.wait()
        return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

/// A signed-in door that is never reached in these tests, and says so if it is.
private struct Unsent: HTTPSender {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
