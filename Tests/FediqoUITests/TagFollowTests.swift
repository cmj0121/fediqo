import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #318, the hashtag's page: the line each signed-in source has there — whether the reader
/// follows the hashtag as the source last said, and the press for the other — what is asked
/// for it and when, how a press is guarded, and what stands there where the sign-in was not
/// given who the reader follows.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), tied to the work that
/// made the ask where a check can name it: a held ask is let go by the check, and by a guard
/// when the run has gone still; every deadline is on a clock nobody turns.
@MainActor
@Suite("A hashtag followed at a source, on the hashtag's page", .serialized, .watched)
struct TagFollowTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    /// A sign-in that reads and holds who the reader follows, and nothing else that acts.
    private static let follows = "\(reads) read:follows write:follows"
    private static let asked = "/api/v1/tags/swift"
    private static let follow = "/api/v1/tags/swift/follow"
    private static let unfollow = "/api/v1/tags/swift/unfollow"
    private static let swift = PostTag("#swift")!

    private static func said(_ following: Bool, name: String = "swift") -> PageServer.Answer {
        PageServer.Answer(body: #"{"id":"2","name":"\#(name)","url":"https://m.example/tags/\#(name)","history":[],"following":\#(following),"featuring":false}"#)
    }

    private static let down = PageServer.Answer(body: "<html>", status: 500)
    /// Made up here, in the shape a Mastodon's not-found has (`MastodonTagFollowCaptures.notFound`).
    private static let notFound = #"{"error":"Not Found"}"#

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server, work)
    }

    private func signOut(_ session: ShellSession) throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        session.mastodon.refresh()
    }

    private func signIn(
        _ session: ShellSession, as access: String = "tok", holding scopes: String = TagFollowTests.follows,
        asked: String? = nil, refused: String? = nil
    ) throws {
        try signOut(session)
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: access, clientID: "c", clientSecret: "s", scopes: scopes, asked: asked ?? scopes,
            refused: refused
        ))
        session.mastodon.refresh()
    }

    private func line(_ standing: TagFollowLine.Standing, missed: Bool? = nil) -> [TagFollowLine] {
        [TagFollowLine(host: Self.host, tag: Self.swift, standing: standing, missed: missed)]
    }

    private static var shell: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI")
    }

    // MARK: - What is asked, and when

    @Test("Opening a hashtag's page asks each source whose sign-in holds follows whether the reader follows it — one ask, as them, of that host, listed in the run's record as that — and the line says what the source said and offers the other; opened again, nothing more is asked")
    func openingAsksOnceAsTheReader() async throws {
        let (session, server, work) = await session([Self.asked: Self.said(false)])
        try signIn(session)
        let tags = ShellPersonPages().tags
        #expect(tags.lines(of: Self.swift, in: session) == line(.asking), "before anything answered")
        await tags.opened(Self.swift, in: session)
        #expect(await server.asked == [Self.asked])
        #expect(await server.bearers == ["Bearer tok"])
        #expect(work.record.map(\.purpose) == [.followedTags])
        #expect(work.record.allSatisfy { $0.reached == Self.host && $0.source == Self.host })
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(false)))
        #expect(session.notes.isEmpty, "nothing is held")

        await tags.opened(Self.swift, in: session)
        #expect(await server.asked.count == 1, "answered: not asked again while the page stands")

        // The same hashtag in another case and width is the same page, asked as it was written.
        #expect(tags.lines(of: PostTag("#ＳＷＩＦＴ")!, in: session).map(\.standing) == [.said(false)])

        let (other, _, _) = await self.session([Self.asked: Self.said(true)])
        try signIn(other)
        let followed = ShellPersonPages().tags
        await followed.opened(Self.swift, in: other)
        #expect(followed.lines(of: Self.swift, in: other) == line(.said(true)))
    }

    @Test("With no sign-in there is no line and nobody is asked; a forum has none, signed in or not; a hashtag whose name is too long to ask about has none; and a line a sign-in was given is not drawn once it has ended")
    func onlyWhereSignedIn() async throws {
        let (session, server, work) = await session([Self.asked: Self.said(true)])
        let tags = ShellPersonPages().tags
        #expect(tags.lines(of: Self.swift, in: session).isEmpty)
        await tags.opened(Self.swift, in: session)
        await tags.again(Self.swift, at: Self.host, in: session)
        await tags.press(Self.swift, at: Self.host, in: session)
        await tags.opened(Self.swift, in: session)
        #expect(await server.asked.isEmpty)
        #expect(work.record.isEmpty)
        #expect(tags.opening(Self.swift, in: session).isEmpty)

        // Even a sign-in kept under a forum's name makes no line there.
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.forum.host, accessToken: "odd", clientID: "c", clientSecret: "s", scopes: Self.follows, asked: Self.follows
        ))
        session.mastodon.refresh()
        #expect(session.mastodon.signedInHosts.contains(Self.forum.host))
        #expect(tags.lines(of: Self.swift, in: session).isEmpty)
        await tags.opened(Self.swift, in: session)
        await tags.press(Self.swift, at: Self.forum.host, in: session)
        await tags.again(Self.swift, at: Self.forum.host, in: session)
        #expect(await server.asked.isEmpty, "a forum is asked nothing")
        #expect(work.record.isEmpty)

        try signIn(session)
        let long = try #require(PostTag("#" + String(repeating: "f", count: MastodonTagFollows.nameLength + 1)))
        #expect(tags.lines(of: long, in: session).isEmpty)
        await tags.opened(long, in: session)
        await tags.press(long, at: Self.host, in: session)
        #expect(await server.asked.isEmpty)

        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true)))
        try signOut(session)
        #expect(tags.lines(of: Self.swift, in: session).isEmpty, "ended: not drawn")
        await tags.opened(Self.swift, in: session)
        await tags.press(Self.swift, at: Self.host, in: session)
        #expect(await server.asked == [Self.asked], "and nobody is asked for nobody")
    }

    // MARK: - Where follows is not held

    @Test("Where the sign-in does not hold follows, nothing is asked and nothing is guessed: the line is the lock of how it stands — never asked, refused on the source's page, none there, held in part, the source being asked — and only a line that asks raises the question, which sends nothing")
    func whereFollowsIsNotHeld() async throws {
        let (session, server, work) = await session([Self.asked: Self.said(true)])
        let tags = ShellPersonPages().tags
        func place() -> PartWords.Place? {
            guard case .locked(let place) = tags.lines(of: Self.swift, in: session).first?.standing else { return nil }
            return place
        }

        try signIn(session, holding: Self.reads)
        #expect(place() == PartWords.Place(kind: .unasked, key: "part.follows.unasked"))
        await tags.opened(Self.swift, in: session)
        await tags.press(Self.swift, at: Self.host, in: session)
        await tags.again(Self.swift, at: Self.host, in: session)
        #expect(await server.asked.isEmpty, "nothing is asked to draw a lock")
        #expect(work.record.isEmpty)
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == .ask)

        try signIn(session, holding: Self.reads, refused: "read:follows write:follows")
        #expect(place() == PartWords.Place(kind: .refused, key: "part.ask.refused"))
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == .ask)

        try signIn(session, holding: Self.reads, asked: Self.follows)
        #expect(place() == PartWords.Place(kind: .none, key: "part.ask.none"))
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == nil, "a source with none is not asked again")

        // Held in part, and the rest never asked for: its own line, which asks for the rest.
        try signIn(session, holding: "\(Self.reads) read:follows")
        #expect(place() == PartWords.Place(kind: .partly, key: "part.follows.partly.changing"))
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == .ask)
        // Held in part, the rest asked for and not given: said, with no press.
        try signIn(session, holding: "\(Self.reads) read:follows", asked: Self.follows)
        #expect(place() == PartWords.Place(kind: .none, key: "part.ask.partly"))
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == nil)

        await tags.opened(Self.swift, in: session)
        #expect(await server.asked.isEmpty, "whether it is followed is not read where follows is not held whole")

        // The press on a line that asks raises the question about follows at that source, and no more.
        try signIn(session, holding: Self.reads)
        #expect(session.partAsks.open == nil)
        #expect(session.askFor([.follows], host: Self.host))
        #expect(session.partAsks.open?.ticked == [.follows])
        #expect(session.partAsks.open?.host == Self.host)
        #expect(await server.asked.isEmpty)
    }

    @Test("After a yes on the question the place reads again and offers Follow: the wider sign-in is another opening of the page, its one ask is whether the hashtag is followed, and nothing is followed unpressed")
    func afterAYesThePlaceReadsAgain() async throws {
        let host = "social.example"
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: host, accessToken: "held-1", clientID: "cid-old", clientSecret: "csecret-old", scopes: Self.reads, asked: Self.reads
        ))
        let server = PartServer(tokens: tokens)
        await server.answer(Self.asked, .body(Self.said(false).body))
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.deadlinesUnturned()
        await session.store.add(Source(host: host, kind: .mastodon))
        session.sources = await session.store.sources()
        session.mastodon.refresh()
        let tags = ShellPersonPages().tags

        let locked = tags.opening(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == .ask)
        await tags.opened(Self.swift, in: session)
        #expect(await !server.paths.contains(Self.asked))

        #expect(session.askFor([.follows], host: host))
        let ask = try #require(session.partAsks.open)
        session.partAsks.answer(ask, through: PartPage(), in: session)
        await session.partAsks.landed(host: host)
        #expect(session.mastodon.standing(.follows, host: host) == .held)

        let opening = tags.opening(Self.swift, in: session)
        #expect(opening != locked, "the page's task is another: it opens again by itself")
        #expect(tags.lines(of: Self.swift, in: session).map(\.standing) == [.asking])
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session).map(\.standing) == [.said(false)])
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == .follow)
        let paths = await server.paths
        #expect(paths.filter { $0 == Self.asked }.count == 1)
        #expect(!paths.contains { $0.hasSuffix("/follow") || $0.hasSuffix("/unfollow") }, "the pressed act is never sent by itself")
    }

    // MARK: - The press

    @Test("A press follows: the line reads as doing it while the source is asked, one request is out however often it is pressed, and the answer is what the line then says — followed, with the press to unfollow; unfollowing is the same the other way. Each is listed in the record as a write, and nothing but the hashtag's own addresses is ever asked")
    func aPressFollowsAndUnfollows() async throws {
        let (session, server, work) = await session([Self.asked: Self.said(false), Self.follow: Self.said(true), Self.unfollow: Self.said(false)])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == .follow)

        await server.hold(Self.follow)
        let followGuard = watching("the ask of \(Self.follow), held at its server") { await server.release(Self.follow) }
        defer { followGuard.cancel() }
        let pressed = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        defer { Task { await server.release(Self.follow) } }
        await server.arrival(of: Self.follow, by: pressed)
        #expect(tags.lines(of: Self.swift, in: session) == line(.doing(true)), "shown first")
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == nil)
        // A second press, and a third, while the first is out: nothing more is sent.
        await tags.press(Self.swift, at: Self.host, in: session)
        await tags.press(Self.swift, at: Self.host, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.doing(true)))
        #expect(await server.asked == [Self.asked, Self.follow])
        await server.release(Self.follow)
        await pressed.value
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true)))
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == .unfollow)

        await tags.press(Self.swift, at: Self.host, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(false)))
        #expect(await server.asked == [Self.asked, Self.follow, Self.unfollow])
        #expect(await server.bearers.allSatisfy { $0 == "Bearer tok" })
        #expect(work.record.map(\.purpose) == [.followedTags, .write, .write])
        #expect(work.record.allSatisfy { $0.reached == Self.host && $0.source == Self.host })

        // Holding follows alone is enough for all of it, and writes nothing else.
        #expect(session.mastodon.writing(host: Self.host, kind: .mastodon) == .reads)
        #expect(session.mastodon.bookmarks(host: Self.host) == .unavailable)
    }

    @Test("A press that does not arrive says so in its own sentence, and the line returns to what the source last said; the next press tries again and takes the sentence down; and a source that answers the other way than was pressed is believed, and said as not done")
    func aPressThatDoesNotArrive() async throws {
        let (session, server, _) = await session([Self.asked: Self.said(false), Self.follow: Self.down])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await tags.opened(Self.swift, in: session)
        await tags.press(Self.swift, at: Self.host, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(false), missed: true))
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == .follow)
        #expect(tags.lines(of: Self.swift, in: session).first?.missedWords(language: .english) == "Could not follow #swift at m.example.")

        await server.answer(Self.follow, Self.said(true))
        await tags.press(Self.swift, at: Self.host, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true)))

        // Unfollow, and nothing answers.
        await server.answer(Self.unfollow, nil)
        await tags.press(Self.swift, at: Self.host, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true), missed: false))
        #expect(tags.lines(of: Self.swift, in: session).first?.missedWords(language: .english) == "Could not unfollow #swift at m.example.")

        // The sentence was said on the page: left and come back to, the page says what the source says.
        tags.closed(Self.swift)
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(false)), "as the first read's route still says")
        await server.answer(Self.asked, Self.said(true))
        tags.closed(Self.swift)
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true)))

        // The source says it is followed still: its word stands, and the press is said as not done.
        await server.answer(Self.unfollow, Self.said(true))
        await tags.press(Self.swift, at: Self.host, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true), missed: false))
        // And an answer that does not say is no answer.
        await server.answer(Self.unfollow, PageServer.Answer(body: #"{"name":"swift"}"#))
        await tags.press(Self.swift, at: Self.host, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true), missed: false))
        #expect(session.mastodon.signedInHosts.contains(Self.host), "a failed press concludes nothing about the sign-in")
    }

    @Test("A read that fails is said on the line, with the press that asks again and no press to follow — nothing is guessed; asking again while the source is being asked asks nothing")
    func aReadThatFails() async throws {
        let (session, server, _) = await session([Self.asked: Self.down])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.unknown))
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == .again)
        await tags.press(Self.swift, at: Self.host, in: session)
        await tags.opened(Self.swift, in: session)
        #expect(await server.asked == [Self.asked], "a failure is not asked again by being drawn, and nothing is followed unseen")

        await server.answer(Self.asked, Self.said(true))
        await server.hold(Self.asked)
        defer { Task { await server.release(Self.asked) } }
        let askedGuard = watching("the ask of \(Self.asked), held at its server") { await server.release(Self.asked) }
        defer { askedGuard.cancel() }
        let again = Task { await tags.again(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.asked, times: 2, by: again)
        #expect(tags.lines(of: Self.swift, in: session) == line(.asking))
        await tags.again(Self.swift, at: Self.host, in: session)
        #expect(await server.asked.count == 2, "one ask at a time")
        await server.release(Self.asked)
        await again.value
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true)))
        await tags.again(Self.swift, at: Self.host, in: session)
        #expect(await server.asked.count == 2, "answered: asking again asks nothing")
    }

    // MARK: - Late answers

    @Test("An answer to a press lands only for the sign-in pressed for: replaced by another while the request is out, its yes shows nothing and says nothing, and the new reader's line and press are their own — the first reader's press does not stand in their way; signed out, there is no line and no sentence of a failure")
    func aSignInReplacedWhileAPressIsOut() async throws {
        let (session, server, _) = await session([Self.asked: Self.said(false), Self.follow: Self.said(true), Self.unfollow: Self.down])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await tags.opened(Self.swift, in: session)
        await server.hold(Self.follow)
        defer { Task { await server.release(Self.follow) } }
        let followGuard = watching("the ask of \(Self.follow), held at its server") { await server.release(Self.follow) }
        defer { followGuard.cancel() }
        let pressed = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.follow, by: pressed)

        try signIn(session, as: "other")
        #expect(tags.lines(of: Self.swift, in: session) == line(.asking), "another reader: nothing of the first is drawn")
        await server.release(Self.follow)
        await pressed.value
        #expect(tags.lines(of: Self.swift, in: session) == line(.asking), "the first reader's yes lands nowhere")
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(false)), "what the source says to this reader")
        #expect(await server.bearers.last == "Bearer other")

        // A press of this reader's still out, another signs in and presses: theirs goes too.
        await server.hold(Self.follow)
        let earlier = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.follow, times: 2, by: earlier)
        try signIn(session, as: "third")
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(false)))
        let theirs = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.follow, times: 3, by: theirs)
        #expect(await server.asked.filter { $0 == Self.follow }.count == 3, "the first reader's press does not stand in the way")
        #expect(tags.lines(of: Self.swift, in: session) == line(.doing(true)))
        await server.release(Self.follow)
        await earlier.value
        await theirs.value
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true)))
        #expect(await server.bearers.suffix(3) == ["Bearer other", "Bearer third", "Bearer third"])

        // A sign-in replaced that the session has not looked at yet: the answer is still not its.
        await server.answer(Self.unfollow, Self.said(false))
        await server.hold(Self.unfollow)
        defer { Task { await server.release(Self.unfollow) } }
        let unfollowGuard = watching("the ask of \(Self.unfollow), held at its server") { await server.release(Self.unfollow) }
        defer { unfollowGuard.cancel() }
        let unseen = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.unfollow, by: unseen)
        #expect(await server.asked.last == Self.unfollow)
        let held = try #require(try session.mastodon.tokens.token(host: Self.host))
        _ = try session.mastodon.tokens.forget(held)
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "fourth", clientID: "c", clientSecret: "s", scopes: Self.follows, asked: Self.follows
        ))
        await server.release(Self.unfollow)
        await unseen.value
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true)), "an answer to another sign-in's press is written nowhere")

        // And a failure for a reader who has signed out is said to nobody.
        session.mastodon.refresh()
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(false)))
        await server.answer(Self.follow, Self.down)
        await server.hold(Self.follow)
        let failing = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.follow, times: 4, by: failing)
        #expect(await server.asked.filter { $0 == Self.follow }.count == 4)
        try signOut(session)
        await server.release(Self.follow)
        await failing.value
        #expect(tags.lines(of: Self.swift, in: session).isEmpty)
        try signIn(session, as: "fifth")
        #expect(tags.lines(of: Self.swift, in: session) == line(.asking), "no failure of somebody else's press")
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(false)))
    }

    /// Pins the press's number in `act` (`PressGuard.isStill`): with the same token held again,
    /// the token cannot tell the first press's answer from the second's.
    @Test("An answer that comes back after another reader had the page and the first, back with the same sign-in, pressed again finds a press that is not its own: it does not end the later press, and the line goes on reading as doing it until that one is answered")
    func aLateAnswerIsNotTheLaterPresss() async throws {
        let (session, server, _) = await session([Self.asked: Self.said(false), Self.follow: Self.said(true)])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await tags.opened(Self.swift, in: session)
        await server.hold(Self.follow)
        defer { Task { await server.release(Self.follow) } }
        let followGuard = watching("the ask of \(Self.follow), held at its server") { await server.release(Self.follow) }
        defer { followGuard.cancel() }
        let early = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.follow, by: early)

        // Another reader looks at the page, and then the first is back with the token they had.
        try signIn(session, as: "other")
        await tags.opened(Self.swift, in: session)
        try signIn(session)
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(false)), "the premise: the first press went with its sign-in")
        let late = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.follow, times: 2, by: late)
        #expect(await server.asked.filter { $0 == Self.follow }.count == 2)
        #expect(tags.lines(of: Self.swift, in: session) == line(.doing(true)))

        await server.releaseOne(Self.follow)
        await early.value
        #expect(tags.lines(of: Self.swift, in: session) == line(.doing(true)), "the first press's answer ended the second press")
        #expect(await server.asked.filter { $0 == Self.asked }.count == 3, "the first press's answer had the page asked afresh")

        await server.release(Self.follow)
        await late.value
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true)))
    }

    @Test("A page closed while a press is out is told nothing of its answer — not a yes, not a failure; opened again meanwhile it reads as doing it and no second request goes; and what the page then says is read from the source after the press landed, never a read that was already on its way")
    func aPageClosedWhileAPressIsOut() async throws {
        let (session, server, _) = await session([Self.asked: Self.said(false), Self.follow: Self.said(true)])
        try signIn(session)
        let tags = ShellPersonPages().tags
        // Reads on a wire that goes on answering one that was called off.
        tags.reaching = { token in
            MastodonTagFollows(door: MastodonAuthorized(token: token, sender: server, store: MemoryMastodonTokens()))
        }
        await tags.opened(Self.swift, in: session)
        await server.hold(Self.follow)
        defer { Task { await server.release(Self.follow) } }
        let followGuard = watching("the ask of \(Self.follow), held at its server") { await server.release(Self.follow) }
        defer { followGuard.cancel() }
        let pressed = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.follow, by: pressed)

        tags.closed(Self.swift)
        // Opened again: a read goes out, and is held on its way.
        await server.hold(Self.asked)
        defer { Task { await server.release(Self.asked) } }
        let askedGuard = watching("the ask of \(Self.asked), held at its server") { await server.release(Self.asked) }
        defer { askedGuard.cancel() }
        let reopened = Task { await tags.opened(Self.swift, in: session) }
        await server.arrival(of: Self.asked, times: 2, by: reopened)
        #expect(tags.lines(of: Self.swift, in: session) == line(.doing(true)), "the press is still out, and reads so")
        await tags.press(Self.swift, at: Self.host, in: session)
        #expect(await server.asked.filter { $0 == Self.follow }.count == 1, "one act per hashtag at a time")

        // The press lands: it is written to no page, and the page is asked afresh.
        await server.release(Self.follow)
        await pressed.value
        // No `by:`: the read afresh is the pages' own task, begun once the press has landed.
        await met("the hashtag is asked afresh once the press landed") { await server.arrivals(of: Self.asked) >= 3 }
        #expect(await server.asked.filter { $0 == Self.asked }.count == 3, "asked afresh once the press landed")
        #expect(tags.lines(of: Self.swift, in: session) == line(.asking))
        // The read that was on its way before the press landed says what was true then.
        await server.releaseOne(Self.asked)
        await reopened.value
        #expect(tags.lines(of: Self.swift, in: session) == line(.asking), "a read already on its way does not undo the act")
        await server.answer(Self.asked, Self.said(true))
        await server.release(Self.asked)
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true)))

        // A failure for a page that was closed is said nowhere.
        await server.answer(Self.unfollow, Self.down)
        await server.hold(Self.unfollow)
        defer { Task { await server.release(Self.unfollow) } }
        let unfollowGuard = watching("the ask of \(Self.unfollow), held at its server") { await server.release(Self.unfollow) }
        defer { unfollowGuard.cancel() }
        let failing = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.unfollow, by: failing)
        tags.closed(Self.swift)
        await server.release(Self.unfollow)
        await failing.value
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true)), "as the source says, and no sentence of a press nobody is looking at")
    }

    @Test("A page opened again while a press is out, whose read is answered before the press is: once the press lands, what that read said is let go — the line reads as asking, with no press, and a press sends nothing — until the source has been read afresh")
    func aReadAnsweredBeforeThePressLanded() async throws {
        let (session, server, _) = await session([Self.asked: Self.said(false), Self.follow: Self.said(true), Self.unfollow: Self.said(false)])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await tags.opened(Self.swift, in: session)
        await server.hold(Self.follow)
        defer { Task { await server.release(Self.follow) } }
        let followGuard = watching("the ask of \(Self.follow), held at its server") { await server.release(Self.follow) }
        defer { followGuard.cancel() }
        let pressed = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.follow, by: pressed)

        tags.closed(Self.swift)
        // Opened again, and answered at once: not followed, as was true before the press landed.
        await tags.opened(Self.swift, in: session)
        #expect(await server.asked.filter { $0 == Self.asked }.count == 2)
        #expect(tags.lines(of: Self.swift, in: session) == line(.doing(true)), "the press is still out, and reads so")

        // The press lands, and the read begun after it is held on its way.
        await server.hold(Self.asked)
        defer { Task { await server.release(Self.asked) } }
        let askedGuard = watching("the ask of \(Self.asked), held at its server") { await server.release(Self.asked) }
        defer { askedGuard.cancel() }
        await server.release(Self.follow)
        await pressed.value
        // No `by:`: the read afresh is the pages' own task, begun once the press has landed.
        await met("the hashtag is asked afresh once the press landed") { await server.arrivals(of: Self.asked) >= 3 }
        #expect(await server.asked.filter { $0 == Self.asked }.count == 3, "asked afresh once the press landed")
        #expect(tags.lines(of: Self.swift, in: session) == line(.asking), "what was read before the press landed is not said after it")
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == nil)
        await tags.press(Self.swift, at: Self.host, in: session)
        #expect(await server.asked.filter { $0 != Self.asked } == [Self.follow], "nothing is pressed over a read that is out")

        await server.answer(Self.asked, Self.said(true))
        await server.release(Self.asked)
        await tags.opened(Self.swift, in: session)
        #expect(tags.lines(of: Self.swift, in: session) == line(.said(true)))
        #expect(tags.lines(of: Self.swift, in: session).first?.offers == .unfollow)
    }

    @Test("A name the source has no hashtag for is said as that, and stands: no press to follow and none to ask again, nothing more is asked while the page stays, and nothing is concluded about the sign-in; the page come back to asks afresh")
    func aNameTheSourceHasNoHashtagFor() async throws {
        let year = try #require(PostTag("#2024"))
        let asked = "/api/v1/tags/2024"
        let (session, server, _) = await session([asked: PageServer.Answer(body: Self.notFound, status: 404)])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await tags.opened(year, in: session)
        let line = try #require(tags.lines(of: year, in: session).first)
        #expect(line.standing == .absent)
        #expect(line.offers == nil)
        #expect(line.pressWords(language: .english) == nil)
        #expect(line.missedWords(language: .english) == nil)
        #expect(line.words(language: .english) == "At m.example: m.example has no such hashtag.")
        #expect(line.words(language: .taiwanese) == "在 m.example：m.example 沒有這個主題標籤。")

        await tags.press(year, at: Self.host, in: session)
        await tags.again(year, at: Self.host, in: session)
        await tags.opened(year, in: session)
        #expect(await server.asked == [asked], "said once: not asked again, and nothing is followed")
        #expect(session.mastodon.signedInHosts.contains(Self.host))

        await server.answer(asked, Self.said(false, name: "2024"))
        tags.closed(year)
        await tags.opened(year, in: session)
        #expect(tags.lines(of: year, in: session).map(\.standing) == [.said(false)])
    }

    @Test("A press is the hashtag's it was made on: another hashtag's line is not moved by it, neither while it is out nor by its answer")
    func anotherHashtagIsNotMoved() async throws {
        let rust = PostTag("#rust")!
        let (session, server, _) = await session([
            Self.asked: Self.said(false), Self.follow: Self.said(true), "/api/v1/tags/rust": Self.said(false, name: "rust"),
        ])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await tags.opened(Self.swift, in: session)
        await tags.opened(rust, in: session)
        await server.hold(Self.follow)
        defer { Task { await server.release(Self.follow) } }
        let followGuard = watching("the ask of \(Self.follow), held at its server") { await server.release(Self.follow) }
        defer { followGuard.cancel() }
        let pressed = Task { await tags.press(Self.swift, at: Self.host, in: session) }
        await server.arrival(of: Self.follow, by: pressed)
        #expect(tags.lines(of: rust, in: session).map(\.standing) == [.said(false)])
        await server.release(Self.follow)
        await pressed.value
        #expect(tags.lines(of: rust, in: session).map(\.standing) == [.said(false)])
        #expect(tags.lines(of: Self.swift, in: session).map(\.standing) == [.said(true)])
    }

    @Test("A source removed while its read is out is told nothing: there is no line, and the answer lands nowhere")
    func aSourceRemovedWhileARead() async throws {
        let (session, server, _) = await session([Self.asked: Self.said(true)])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await server.hold(Self.asked)
        defer { Task { await server.release(Self.asked) } }
        let askedGuard = watching("the ask of \(Self.asked), held at its server") { await server.release(Self.asked) }
        defer { askedGuard.cancel() }
        let opened = Task { await tags.opened(Self.swift, in: session) }
        await server.arrival(of: Self.asked, by: opened)
        session.sources = [Self.forum]
        #expect(tags.lines(of: Self.swift, in: session).isEmpty)
        await server.release(Self.asked)
        await opened.value
        #expect(tags.lines(of: Self.swift, in: session).isEmpty)
        session.sources = [Self.source, Self.forum]
        #expect(tags.lines(of: Self.swift, in: session) == line(.asking), "added again, it is asked afresh: nothing was kept for it")
    }

    // MARK: - Words

    @Test("The line says where and how it stands, in both languages: At the source — followed, not followed, asking, doing, could not ask — and a lock says its own sentence after the source's name")
    func theWords() throws {
        func words(_ standing: TagFollowLine.Standing, _ language: DummyLanguage) -> String {
            TagFollowLine(host: Self.host, tag: Self.swift, standing: standing).words(language: language)
        }
        #expect(words(.said(false), .english) == "At m.example: not followed.")
        #expect(words(.said(true), .english) == "At m.example: followed.")
        #expect(words(.asking, .english) == "At m.example: finding out whether you follow it…")
        #expect(words(.unknown, .english) == "At m.example: could not find out whether you follow it.")
        #expect(words(.doing(true), .english) == "At m.example: following…")
        #expect(words(.doing(false), .english) == "At m.example: unfollowing…")
        let unasked = PartWords.Place(kind: .unasked, key: "part.follows.unasked")
        #expect(words(.locked(unasked), .english) == "At m.example: This sign-in was not asked how you stand to people. Update permission")
        #expect(words(.locked(PartWords.Place(kind: .none, key: "part.ask.none")), .english) == "At m.example: m.example has none to allow.")

        #expect(words(.said(false), .taiwanese) == "在 m.example：未追蹤。")
        #expect(words(.said(true), .taiwanese) == "在 m.example：已追蹤。")
        #expect(words(.asking, .taiwanese) == "在 m.example：正在查詢你是否追蹤它…")
        #expect(words(.unknown, .taiwanese) == "在 m.example：無法得知你是否追蹤它。")
        #expect(words(.doing(true), .taiwanese) == "在 m.example：正在追蹤…")
        #expect(words(.doing(false), .taiwanese) == "在 m.example：正在取消追蹤…")

        let line = TagFollowLine(host: Self.host, tag: Self.swift, standing: .said(false), missed: true)
        #expect(line.pressWords(language: .english) == "Follow")
        #expect(line.pressWords(language: .taiwanese) == "追蹤")
        #expect(line.pressSpoken(language: .english) == "Follow #swift at m.example")
        #expect(line.pressSpoken(language: .taiwanese) == "在 m.example 追蹤 #swift")
        #expect(line.missedWords(language: .taiwanese) == "無法在 m.example 追蹤 #swift。")
        let followed = TagFollowLine(host: Self.host, tag: Self.swift, standing: .said(true), missed: false)
        // Followed, the row has no press: Unfollow is the one item of its `…`, named there by
        // what it does and where — red, and asking first which hashtag at which source.
        #expect(followed.press == nil && followed.pressWords(language: .english) == nil && followed.pressSpoken() == nil)
        let more = try #require(followed.more(act: {}))
        #expect(more.items.map(\.name) == [L10n.t("tag.follow.unfollow")] && more.dangers.count == 1 && more.reasons.isEmpty)
        let question = try #require(more.items.first?.question)
        #expect(question == ShellQuestion.unfollow(Self.swift, at: Self.host))
        #expect(question.chorded?.id == ShellQuestion.yes && question.chorded?.role == .destructive)
        let english = ShellQuestion.unfollow(Self.swift, at: Self.host, language: .english)
        #expect(english.title == "Unfollow #swift at m.example?" && english.choices.map(\.label) == ["Unfollow"] && english.cancel == "Cancel")
        #expect(english.line == "Posts from there will no longer come into your Home just because they carry it.")
        let taiwanese = ShellQuestion.unfollow(Self.swift, at: Self.host, language: .taiwanese)
        #expect(taiwanese.title == "在 m.example 取消追蹤 #swift？" && taiwanese.choices.map(\.label) == ["取消追蹤"] && taiwanese.cancel == "取消")
        #expect(taiwanese.line == "那裡的貼文不會再只因為帶著它而進到你的首頁。")
        #expect(followed.moreLabel(language: .english) == "More: Unfollow #swift at m.example")
        #expect(followed.moreLabel(language: .taiwanese) == "更多：在 m.example 取消追蹤 #swift")
        #expect(line.more(act: {}) == nil && line.press == .follow, "not followed, there is no `…`")
        #expect(followed.missedWords(language: .taiwanese) == "無法在 m.example 取消追蹤 #swift。")
        #expect(TagFollowLine(host: Self.host, tag: Self.swift, standing: .unknown).pressWords(language: .english) == "Try again")
        #expect(TagFollowLine(host: Self.host, tag: Self.swift, standing: .asking).pressWords(language: .english) == nil)
        #expect(SourceWork.Purpose.followedTags.isOfTheSource && !SourceWork.Purpose.followedTags.gathers)
        #expect(!SourceWork.Purpose.followedTags.symbol.isEmpty)
    }

    @Test("Every sentence of this is in the three tables, and the two Chinese tables say the same bytes")
    func theTables() throws {
        func ours(_ language: String) throws -> [String] {
            let table = try String(contentsOf: Self.shell.appending(path: "Resources/\(language).lproj/Localizable.strings"), encoding: .utf8)
            return table.components(separatedBy: "\n").filter { $0.hasPrefix("\"tag.follow.") || $0.hasPrefix("\"work.purpose.followedTags\"") }
        }
        let english = try ours("en"), taiwanese = try ours("zh-TW"), hant = try ours("zh-Hant")
        #expect(english.count == 17)
        #expect(taiwanese == hant)
        func keys(_ lines: [String]) -> [String] { lines.compactMap { $0.components(separatedBy: "\"").dropFirst().first } }
        #expect(keys(english) == keys(taiwanese))
    }

    // MARK: - The page

    @Test("The hashtag's About is handed a row for each line and the page none where it is handed none, which is the page a forum's reader always had; a row draws the sentence of a press that did not arrive under it; and the pane that opens it asks through the object, lets go when it leaves, and raises the question for follows from the lock")
    func thePage() throws {
        // The rows stand on About since F10: About is hosted, and says which rows it drew and how tall.
        func drawn(_ follows: [TagFollowLine]) -> [String: CGSize] {
            let probe = TagAboutProbe()
            let about = TagAbout(said: TagAboutSaid(follows: follows)) { EmptyView() }
            let hosted = NSHostingView(rootView: about.frame(width: 460, height: 400).environment(\.tagAboutProbe, probe))
            hosted.layoutSubtreeIfNeeded()
            return probe.sizes
        }
        let row = TagAboutSaid.lamp(on: line(.said(false))[0])
        #expect(drawn([]).isEmpty, "handed none, it draws none")
        let one = try #require(drawn(line(.said(false)))[row]), missed = try #require(drawn(line(.said(false), missed: true))[row])
        let taller: Bool = one.height > 0 && one.width == 460
        let tallest: Bool = missed.height > one.height
        #expect(taller, "a line is drawn, as wide as the page")
        #expect(tallest, "and under it the sentence of a press that did not arrive")
        let other = TagFollowLine(host: "two.example", tag: Self.swift, standing: .asking)
        #expect(Set(drawn(line(.said(true)) + [other]).keys) == [row, TagAboutSaid.lamp(on: other)], "a row for each line")
        #expect(TagPageSaid.made(of: Self.swift, held: 0).about == nil, "handed none, the page has no About to draw one on")
        #expect(TagPageSaid.made(of: Self.swift, held: 0, follows: line(.said(false))).about?.follows == line(.said(false)))

        // Followed, a row draws its `…`, named by what it holds, and no Unfollow beside the line;
        // not followed, it draws Follow and no `…`.
        func drew(_ follows: [TagFollowLine]) -> TagAboutProbe {
            let probe = TagAboutProbe()
            let about = TagAbout(said: TagAboutSaid(follows: follows)) { EmptyView() }
            let hosted = NSHostingView(rootView: about.frame(width: 460, height: 400).environment(\.tagAboutProbe, probe))
            hosted.layoutSubtreeIfNeeded()
            return probe
        }
        let followed = drew(line(.said(true)))
        #expect(followed.menus == [Self.host: line(.said(true))[0].moreLabel()] && followed.presses.isEmpty)
        let notFollowed = drew(line(.said(false)))
        #expect(notFollowed.presses == [Self.host: L10n.t("tag.follow.follow")] && notFollowed.menus.isEmpty)

        let pane = try String(contentsOf: Self.shell.appending(path: "Shell/TimelinePane.swift"), encoding: .utf8)
        #expect(pane.contains(".task(id: people?.tags.opening(tag, in: session)) { await people?.tags.opened(tag, in: session) }"))
        #expect(pane.contains(".onDisappear { people?.tags.closed(tag) }"))
        #expect(pane.contains("onAskFollows: { host in session.askFor([.follows], host: host) }"))
        #expect(pane.contains("onUnfollow: { line in _ = people?.tags.unfollowed(line, in: session) }"), "the `…` only ever unfollows")
    }
}
