#if os(macOS)
import AppKit
import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

/// Mastodons answering for their notices by host and the id asked before, with no more to give
/// below the pages they were handed. None has the gathered read: each answers 404 to it, as a
/// server older than that read does.
private actor NoticeHosts: HTTPSender {
    enum Outcome: Sendable {
        case body(String)
        case status(Int)
        case held(Gate, String)
    }

    private var routes: [String: Outcome]
    private(set) var asked: [String] = []

    init(_ routes: [String: Outcome]) {
        self.routes = routes
    }

    func set(_ key: String, _ outcome: Outcome) {
        routes[key] = outcome
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw FixtureHTTPError.unmapped
        }
        func answer(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        guard parts.path == "/api/v1/notifications" else { return answer(#"{"error":"Not Found"}"#, 404) }
        let before = parts.queryItems?.first { $0.name == "max_id" }?.value
        let key = (parts.host ?? "") + (before.map { "?\($0)" } ?? "")
        asked.append(key)
        switch routes[key] {
        case .body(let body)?: return answer(body)
        case .status(let status)?: return answer(#"{"error":"no"}"#, status)
        case .held(let gate, let body)?:
            await gate.wait()
            try Task.checkCancellation()
            return answer(body)
        // Asked for older than it was given a page for: it has no more.
        case nil where before != nil: return answer("[]")
        case nil: throw FixtureHTTPError.unreachable
        }
    }
}

/// A token store that can be locked: who is signed in and what their sign-in may do is still
/// answered, and no token can be read.
private final class LockingTokens: MastodonTokenStore, @unchecked Sendable {
    private let held = MemoryMastodonTokens()
    private let lock = NSLock()
    private var isLocked = false

    var locked: Bool {
        get { lock.withLock { isLocked } }
        set { lock.withLock { isLocked = newValue } }
    }

    func token(host: String) throws -> MastodonToken? {
        if locked { throw ForumCredentialError.keychain(-25_308) }
        return try held.token(host: host)
    }
    func save(_ token: MastodonToken) throws { try held.save(token) }
    func forget(host: String) throws { try held.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try held.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try held.grants() }
    func bookmarking() throws -> Set<String> { try held.bookmarking() }
    func bookmarksRefused() throws -> Set<String> { try held.bookmarksRefused() }
    func noticing() throws -> Set<String> { try held.noticing() }
    func dismissing() throws -> Set<String> { try held.dismissing() }
    func noticesRefused() throws -> Set<String> { try held.noticesRefused() }
    func app(host: String) throws -> MastodonApp? { try held.app(host: host) }
    func save(_ app: MastodonApp) throws { try held.save(app) }
    func forgetApp(host: String) throws { try held.forgetApp(host: host) }
}

/// #323 — the notices page as it is drawn: each state, each row and what it tells a listener,
/// the walk a line begins and comes back from, a post too old to open, and 320 points across.
///
/// **What this reaches.** The page and the row the root draws, hosted in an `NSHostingView` over
/// a session whose sources answer from a fixture; each part reports where it was laid out and
/// what it says to a probe, so "drawn" is a frame SwiftUI gave it.
///
/// **What it does not reach.** No window is made: light and dark, a finger on a phone, the menu
/// of kinds opened and VoiceOver itself are for a person on a running app.
@Suite("The notices page, hosted", .serialized)
@MainActor
struct NoticesHostedTests {
    private static let a = "a.example"
    private static let b = "b.example"
    private static let reads = MastodonOAuth.scopes(writing: false, notices: true)
    private static let plain = MastodonOAuth.scopes(writing: false)

    /// A moment `minutes` ago, as a server writes one.
    private static func ago(_ minutes: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(-Double(minutes) * 60))
    }

    /// One notice of the single read. `post` is the id of the post it is about, written at
    /// `written` (now, or a date long past).
    private static func one(
        _ id: Int, _ type: String, by name: String = "Ada", minutes: Int, post: Int? = nil, written: String? = nil,
        words: String = "The post it is about"
    ) -> String {
        let status = post.map {
            """
            ,"status":{"id":"\($0)","uri":"https://\(a)/p/\($0)","created_at":"\(written ?? ago(minutes + 5))",\
            "content":"<p>\(words)</p>","account":{"username":"me","acct":"me","display_name":"Me"}}
            """
        } ?? ""
        let user = name.lowercased()
        return """
        {"id":"\(id)","type":"\(type)","created_at":"\(ago(minutes))",\
        "account":{"id":"\(id)","username":"\(user)","acct":"\(user)","display_name":"\(name)"}\(status)}
        """
    }

    private static func page(_ notices: String...) -> NoticeHosts.Outcome {
        .body("[" + notices.joined(separator: ",") + "]")
    }

    private static func token(_ host: String, scopes: String) -> MastodonToken {
        MastodonToken(host: host, accessToken: "tok-\(host)", clientID: "cid", clientSecret: "csecret", scopes: scopes)
    }

    /// A session holding each of `hosts` as a Mastodon, signed in with `scopes` where it names any.
    private func shell(
        _ routes: [String: NoticeHosts.Outcome], signedIn hosts: [String: String?],
        tokens: any MastodonTokenStore = MemoryMastodonTokens()
    ) async throws -> (ShellSession, NoticeHosts) {
        for (host, scopes) in hosts {
            guard let scopes else { continue }
            try tokens.save(Self.token(host, scopes: scopes))
        }
        let server = NoticeHosts(routes)
        let store = ItemStore(sources: hosts.keys.sorted().map { Source(host: $0, kind: .mastodon) }, notes: [])
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        session.noticeList.deadline = .seconds(5)
        return (session, server)
    }

    /// The root's share of the page: its lamp, its mark, and what a press was answered with.
    @MainActor
    private final class Root {
        var selected: String?
        var tooOld: String?
        var opened: [String] = []
        var people: [String] = []
        var reloads = 0
        let mark = ShellReadingMark()
        let prefs: DummyPrefs

        init() {
            let name = "fediqo.test.noticespage.\(UUID().uuidString)"
            prefs = DummyPrefs(defaults: UserDefaults(suiteName: name)!)
        }
    }

    private struct Host: View {
        let session: ShellSession
        let root: Root
        @State private var selected: String?

        var body: some View {
            NoticesPane(
                session: session,
                selectedID: Binding(get: { root.selected ?? selected }, set: { selected = $0; root.selected = $0 }),
                mark: root.mark,
                canReload: !ShellNoticeList.asked(in: session).isEmpty,
                onReload: { root.reloads += 1 },
                onOpen: { root.opened.append($0.id) },
                onOpenPerson: { person, _ in root.people.append(person.id) },
                tooOld: root.tooOld
            )
            .environment(root.prefs)
        }
    }

    private static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        view.layoutSubtreeIfNeeded()
    }

    /// The page hosted `width` across, with what it drew.
    private func hosted(
        _ session: ShellSession, root: Root = Root(), width: CGFloat = 600, layout: ShellLayout = .wide,
        type: DynamicTypeSize = .large, opening: Bool = false
    ) -> (NSView, NoticesProbe) {
        let probe = NoticesProbe()
        let view = NSHostingView(
            rootView: Host(session: session, root: root)
                .environment(\.shellNoticesProbe, probe)
                .environment(\.shellLayout, layout)
                // The page reads as it opens only where it is the place in front; a test that
                // has read already draws what is held and asks nothing more by being hosted.
                .environment(\.shellPlaceIsActive, opening)
                .dynamicTypeSize(type)
        )
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        Self.settle(view)
        return (view, probe)
    }

    private func rows(_ probe: NoticesProbe) -> [String] {
        probe.frames.compactMap { part, frame -> (String, CGFloat)? in
            if case .row(let id) = part { (id, frame.minY) } else { nil }
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    // MARK: - The states

    @Test("With nobody signed in the page is entered and says what would make it fill")
    func nobodySignedIn() async throws {
        let (session, server) = try await shell([:], signedIn: [Self.a: nil])
        #expect(session.availability.allows(.notices), "the place is entered with nobody signed in")
        #expect(session.availability.enabledPlaces.contains(.notices))

        let (view, probe) = hosted(session, opening: true)
        for _ in 0..<5 { Self.settle(view) }

        #expect((probe.frames[.nobody]?.height ?? 0) > 0, "the page drew nothing")
        #expect(probe.says[.nobody] == L10n.t("notices.empty.line"))
        #expect(probe.frames[.head] == nil, "a head with nothing to choose or read is not drawn")
        #expect(await server.asked.isEmpty, "nobody is asked with nobody signed in")
    }

    @Test("Signed in with no sign-in allowed notices, the page says so and what would be asked, names every source with what is true of it, and asks nobody")
    func signedInAndNotAllowed() async throws {
        let (session, server) = try await shell([:], signedIn: [Self.a: Self.plain, Self.b: Self.plain])
        // One was asked for notices and turned them away; the other was never asked.
        session.mastodon.refusedNotices(host: Self.b, sentWith: Self.token(Self.b, scopes: Self.plain))
        #expect(NoticesPane.hosts(in: session).map(\.notices) == [.unasked, .unavailable])

        let (view, probe) = hosted(session, opening: true)
        for _ in 0..<5 { Self.settle(view) }

        #expect((probe.frames[.notAllowed]?.height ?? 0) > 0)
        #expect(probe.says[.notAllowed] == "No sign-in on this device may read notices yet.")
        #expect(probe.says[.line("unasked:a.example")] == "a.example has not been asked for your notices.")
        #expect(probe.says[.line("refused:b.example")] == "b.example was asked for your notices and gave none.")
        #expect((probe.frames[.line("unasked:a.example")]?.height ?? 0) > 0 && (probe.frames[.line("refused:b.example")]?.height ?? 0) > 0)
        #expect(probe.frames[.nobody] == nil && probe.frames[.head] == nil)
        #expect(await server.asked.isEmpty, "a sign-in never asked for notices was asked for them")

        // With nobody left to ask, the page says that instead, and still names the source.
        let (refused, _) = try await shell([:], signedIn: [Self.b: Self.plain])
        refused.mastodon.refusedNotices(host: Self.b, sentWith: Self.token(Self.b, scopes: Self.plain))
        let (_, told) = hosted(refused)
        #expect(told.says[.notAllowed] == "No sign-in on this device may read notices.")
        #expect(told.says[.line("refused:b.example")] == "b.example was asked for your notices and gave none.")
    }

    @Test("A first read stopped before anybody answered names the source as not read, and says how to read again")
    func stoppedSaysSo() async throws {
        let gate = Gate()
        let (session, server) = try await shell([Self.a: .held(gate, "[]")], signedIn: [Self.a: Self.reads])

        let (view, probe) = hosted(session, opening: true)
        #expect(await spun(400) {
            Self.settle(view)
            return await server.asked.count == 1 && probe.says[.line("reading")] != nil
        })
        #expect(probe.frames[.line("unread:a.example")] == nil, "a source on the wire was named as not read")

        #expect(session.noticeList.stop())
        for _ in 0..<5 { Self.settle(view) }
        await gate.open()

        #expect(!session.noticeList.isReading && session.noticeList.reaches.isEmpty)
        #expect(NoticesPane.lines(in: session) == [.unread(host: Self.a)])
        #expect(probe.says[.line("unread:a.example")]
            == "a.example was not read: the read was stopped before it answered. Press the reload mark, or r, to read again.")
        #expect((probe.frames[.line("unread:a.example")]?.height ?? 0) > 0, "a head, and then a blank page")
        #expect(NoticesLine.unread(host: Self.a).words(language: .english, touch: true)
            == "a.example was not read: the read was stopped before it answered. Press the reload mark to read again.")
    }

    @Test("A read stopped after one source answered and before another did shows the first's lines and names the second as not read, and never says nothing has happened")
    func partlyStoppedSaysWhoWasNotRead() async throws {
        let gate = Gate()
        let (session, server) = try await shell([
            Self.a: Self.page(Self.one(4, "favourite", minutes: 2, post: 30)),
            Self.b: .held(gate, "[]"),
        ], signedIn: [Self.a: Self.reads, Self.b: Self.reads])

        let (view, probe) = hosted(session, opening: true)
        #expect(await spun(400) {
            Self.settle(view)
            return await server.asked.count == 2 && session.noticeList.standing(host: Self.a) == .read
        })
        #expect(session.noticeList.stop())
        for _ in 0..<5 { Self.settle(view) }
        await gate.open()

        #expect(session.noticeList.standing(host: Self.b) == .unread)
        #expect(NoticesPane.lines(in: session) == [.unread(host: Self.b)])
        #expect(rows(probe).count == 1, "the source that answered is shown")
        #expect(probe.says[.line("unread:b.example")]?.hasPrefix("b.example was not read") == true)
        let unread = try #require(probe.frames[.line("unread:b.example")]), row = try #require(probe.frames[.row(rows(probe)[0])])
        #expect(unread.maxY <= row.minY + 0.5, "it is named above the list, as a failure is")

        // And where the one that answered had nothing: the page does not say nothing happened.
        let closed = Gate()
        let (empty, asked) = try await shell([Self.a: Self.page(), Self.b: .held(closed, "[]")], signedIn: [Self.a: Self.reads, Self.b: Self.reads])
        let (other, said) = hosted(empty, opening: true)
        #expect(await spun(400) {
            Self.settle(other)
            return await asked.asked.count == 2 && empty.noticeList.standing(host: Self.a) == .read
        })
        #expect(empty.noticeList.stop())
        for _ in 0..<5 { Self.settle(other) }
        await closed.open()
        #expect(NoticesPane.none(in: empty) == .unread)
        #expect(said.says[.none] == nil, "nothing was said to have happened with a source unread")
        #expect(said.says[.line("unread:b.example")] != nil)
        // Before the page has read at all, nobody is named as left unread.
        #expect(NoticesPane.lines(in: empty, began: false).isEmpty)
    }

    @Test("A source whose sign-in cannot be read off this device is named as not asked, and why")
    func lockedSaysSo() async throws {
        let tokens = LockingTokens()
        let (session, server) = try await shell([Self.a: Self.page()], signedIn: [Self.a: Self.reads], tokens: tokens)
        tokens.locked = true

        let (view, probe) = hosted(session, opening: true)
        #expect(await spun(400) {
            Self.settle(view)
            return session.noticeList.locked == [Self.a]
        })
        for _ in 0..<5 { Self.settle(view) }

        #expect(await server.asked.isEmpty)
        #expect(NoticesPane.lines(in: session) == [.locked(host: Self.a)])
        #expect(probe.says[.line("locked:a.example")] == "This device could not read the sign-in for a.example, so it was not asked.")
        #expect((probe.frames[.line("locked:a.example")]?.height ?? 0) > 0, "a head, and then a blank page")
        #expect(NoticesPane.none(in: session) == .unread, "the line above says why, and nothing says it twice")
    }

    @Test("Opening the page reads: while the first read is on the wire it says so and which sources, and then draws the lines newest first")
    func readsAsItOpens() async throws {
        let gate = Gate()
        let (session, server) = try await shell([
            Self.a: .held(gate, "[" + [Self.one(4, "favourite", minutes: 2, post: 30), Self.one(3, "follow", by: "Bo", minutes: 9)].joined(separator: ",") + "]"),
            Self.b: Self.page(Self.one(8, "mention", by: "Cy", minutes: 5, post: 31)),
        ], signedIn: [Self.a: Self.reads, Self.b: Self.reads])

        let (view, probe) = hosted(session, opening: true)
        #expect(await spun(400) {
            Self.settle(view)
            return await server.asked.count == 2
        }, "opening the page did not read")
        #expect(await spun(400) {
            Self.settle(view)
            return probe.says[.line("reading")] != nil
        })
        #expect(probe.says[.line("reading")] == "Reading notices from a.example, b.example…"
            || probe.says[.line("reading")] == "Reading notices from a.example…")
        #expect(rows(probe).isEmpty, "nothing is drawn until every source asked has answered")
        #expect(probe.frames[.none] == nil, "nothing is said to be empty while it is being read")

        await gate.open()
        #expect(await spun(400) {
            Self.settle(view)
            return !session.noticeList.isReading && rows(probe).count == 2
        })
        // Down to where the source read least far has reached, and no further: the older
        // follow waits for the other source to be read down past it.
        let (_, after) = hosted(session)
        #expect(rows(after) == session.noticeList.lines.map(\.id))
        #expect(session.noticeList.lines.map(\.newestID) == ["4", "8"], "newest first, across both sources")
        #expect(after.frames[.line("reading")] == nil)
        #expect(after.says[.foot] == NoticesFoot.more.words())
        for _ in 0..<10 { Self.settle(view) }
        #expect(await server.asked.count == 2, "a list too short to scroll read on with nobody asking")

        #expect(await spun(400) {
            if NoticesPane.foot(in: session) == .more { await session.noticeList.readOn(in: session) }
            return NoticesPane.foot(in: session) == .end
        })
        let (_, whole) = hosted(session)
        #expect(session.noticeList.lines.map(\.newestID) == ["4", "8", "3"])
        #expect(rows(whole) == session.noticeList.lines.map(\.id))
    }

    @Test("Read, and nothing has happened: the page says so")
    func nothingToShow() async throws {
        let (session, _) = try await shell([Self.a: Self.page()], signedIn: [Self.a: Self.reads])
        await session.noticeList.read(in: session)

        let (_, probe) = hosted(session)

        #expect(probe.says[.none] == "Nothing has happened to you on these sources yet.")
        #expect((probe.frames[.head]?.height ?? 0) > 0, "the head stays, with the read on it")
        #expect(rows(probe).isEmpty)
    }

    @Test("A source that failed is named above the list with a way to ask again, and the others' lines are shown")
    func oneSourceFailed() async throws {
        let (session, server) = try await shell([
            Self.a: Self.page(Self.one(4, "favourite", minutes: 2, post: 30)),
            "\(Self.a)?4": Self.page(),
            Self.b: .status(503),
        ], signedIn: [Self.a: Self.reads, Self.b: Self.reads])
        await session.noticeList.read(in: session)

        let (view, probe) = hosted(session)
        for _ in 0..<5 { Self.settle(view) }
        #expect(await server.asked.filter { $0.hasPrefix(Self.b) } == [Self.b], "a failed source was asked again unpressed")
        #expect(probe.says[.linePress("failed:b.example")] == "", "asking again is offered, and waits on nothing")
        #expect(NoticesPane.retryHint(waits: true, language: .english) == "A read is on its way. Try again once it has ended.")

        #expect(probe.says[.line("failed:b.example")] == "Could not read notices from b.example. What it sent before is still here.")
        #expect(rows(probe).count == 1, "the source that answered is shown")
        #expect(NoticesPane.lines(in: session) == [.failed(host: Self.b, why: .unreachable, again: true)])
        let failure = try #require(probe.frames[.line("failed:b.example")])
        let row = try #require(probe.frames[.row(rows(probe)[0])])
        #expect(failure.minY != row.minY && failure.height > 0)

        // The press beside its name asks that source again, and only that one.
        await server.set(Self.b, Self.page(Self.one(8, "mention", by: "Cy", minutes: 5, post: 31)))
        let before = await server.asked.count
        let pane = NoticesPane(
            session: session, selectedID: .constant(nil), mark: ShellReadingMark(), canReload: true, onReload: {},
            onOpen: { _ in }, onOpenPerson: { _, _ in }
        )
        pane.retry(Self.b)
        #expect(await spun(400) {
            Self.settle(view)
            return session.noticeList.failures.isEmpty && !session.noticeList.isReading
        })
        #expect(Array(await server.asked[before...]) == [Self.b])
        #expect(await spun(400) {
            if NoticesPane.foot(in: session) == .more { await session.noticeList.readOn(in: session) }
            return NoticesPane.foot(in: session) == .end
        })
        let (_, after) = hosted(session)
        #expect(rows(after).count == 2 && after.frames[.line("failed:b.example")] == nil)
    }

    @Test("A source that can no longer be asked is named with no way to ask again")
    func refusedSourceOffersNoRetry() async throws {
        let (session, _) = try await shell([
            Self.a: Self.page(Self.one(4, "favourite", minutes: 2, post: 30)),
            "\(Self.a)?4": Self.page(),
            Self.b: .status(403),
        ], signedIn: [Self.a: Self.reads, Self.b: Self.reads])
        await session.noticeList.read(in: session)

        #expect(NoticesPane.lines(in: session) == [.failed(host: Self.b, why: .refused, again: false)])
        let (_, probe) = hosted(session)
        #expect(probe.says[.line("failed:b.example")] == "b.example would not let this sign-in read notices. What it sent before is still here.")
        #expect(rows(probe).count == 1)
    }

    @Test("After a relaunch the page draws what this device holds while its sources are still being asked, and the foot says they are being read — not to wait for a source named above")
    func heldNoticesAreDrawnWhileTheDoorIsHeld() async throws {
        let routes = [
            Self.a: Self.page(Self.one(4, "favourite", minutes: 2, post: 30), Self.one(3, "follow", by: "Bo", minutes: 9)),
        ]
        let (first, _) = try await shell(routes, signedIn: [Self.a: Self.reads])
        await first.noticeList.read(in: first)
        await first.noticeList.kept()
        let held = await first.store.noticesHeld().notices
        #expect(held.first?.notices.count == 2 && held.first?.before != nil, "the premise: held, with more below")

        // The next run: the store as a launch reads it, and a source that does not answer yet.
        let tokens = MemoryMastodonTokens()
        try tokens.save(Self.token(Self.a, scopes: Self.reads))
        let gate = Gate()
        let server = NoticeHosts([Self.a: .held(gate, "[" + Self.one(4, "favourite", minutes: 2, post: 30) + "]")])
        let store = ItemStore(sources: [Source(host: Self.a, kind: .mastodon)], notes: [], notices: held)
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()

        let (still, before) = hosted(session)
        Self.settle(still)
        #expect(rows(before).count == 2, "drawn with nobody asked")
        #expect(await server.asked.isEmpty)
        #expect(before.says[.foot] == "Older notices can be read. Press here, or scroll to here, to read them.")

        let (view, probe) = hosted(session, opening: true)
        #expect(await spun { Self.settle(view); return await server.asked == [Self.a] })
        Self.settle(view)
        #expect(rows(probe).count == 2, "what is held stays drawn while the source is asked")
        #expect(probe.says[.foot] == "Reading the newest notices…")
        #expect(probe.says[.foot] != NoticesFoot.held.words())
        await gate.open()
        #expect(await spun { Self.settle(view); return !session.noticeList.isReading })
    }

    @Test("A short list reads on only when its foot is pressed, and says when there is no more")
    func theFootReadsOnWhenPressed() async throws {
        let (session, server) = try await shell([
            Self.a: Self.page(Self.one(4, "favourite", minutes: 2, post: 30), Self.one(3, "follow", by: "Bo", minutes: 9)),
            "\(Self.a)?3": Self.page(Self.one(2, "reblog", by: "Cy", minutes: 20, post: 30)),
        ], signedIn: [Self.a: Self.reads])
        await session.noticeList.read(in: session)
        #expect(NoticesPane.foot(in: session) == .more)

        let (view, probe) = hosted(session)
        for _ in 0..<10 { Self.settle(view) }
        #expect(probe.says[.foot] == "Older notices can be read. Press here, or scroll to here, to read them.")
        #expect(await server.asked == [Self.a], "the foot in view of a list too short to scroll read on by itself")

        // A pointer that selects the last line selects it, and reads nothing.
        let root = Root()
        root.selected = session.noticeList.lines.last?.id
        let (clicked, lit) = hosted(session, root: root)
        for _ in 0..<10 { Self.settle(clicked) }
        #expect(lit.frames[.row(root.selected ?? "")] != nil)
        #expect(await server.asked == [Self.a], "selecting the last line read on")

        // Each press reads one stretch more.
        let pane = NoticesPane(
            session: session, selectedID: .constant(nil), mark: ShellReadingMark(), canReload: true, onReload: {},
            onOpen: { _ in }, onOpenPerson: { _, _ in }
        )
        pane.readOn()
        #expect(await spun(400) {
            Self.settle(view)
            return session.noticeList.lines.count == 3 && !session.noticeList.isReading
        })
        #expect(await server.asked == [Self.a, "\(Self.a)?3"])
        pane.readOn()
        #expect(await spun(400) {
            Self.settle(view)
            return NoticesPane.foot(in: session) == .end
        })
        let (_, after) = hosted(session)
        #expect(after.says[.foot] == "No older notices: every source has sent all it has.")
        #expect(rows(after).count == 3)
    }

    @Test("A hand's scroll reads on only where it ends having brought the foot into view, past lines that are shown")
    func theFootReadsByItselfOnlyUnderAHand() {
        let hand = NoticeHand()
        // Scrolled down by hand until the foot came into view.
        #expect(!hand.scrolled(wasByHand: false, isByHand: true, shown: 12))
        hand.footInView = true
        #expect(hand.scrolled(wasByHand: true, isByHand: false, shown: 12))
        // The foot still in view — the stretch brought nothing shown — and the list moved again,
        // or pulled at its top: it was in view as the scroll began, so nothing is read unpressed.
        #expect(!hand.scrolled(wasByHand: false, isByHand: true, shown: 12))
        #expect(!hand.scrolled(wasByHand: true, isByHand: false, shown: 12), "a short list read one more stretch unpressed")
        // A hand's scroll that ends with the foot out of view leaves nothing behind for a
        // later arrival nobody's hand made.
        hand.footInView = false
        #expect(!hand.scrolled(wasByHand: false, isByHand: true, shown: 12))
        #expect(!hand.scrolled(wasByHand: true, isByHand: false, shown: 12))
        hand.footInView = true
        #expect(!hand.scrolled(wasByHand: false, isByHand: false, shown: 12), "the list put somewhere by a key read on")
        // Nothing shown: reading on is a press.
        hand.footInView = false
        _ = hand.scrolled(wasByHand: false, isByHand: true, shown: 0)
        hand.footInView = true
        #expect(!hand.scrolled(wasByHand: true, isByHand: false, shown: 0))
        #expect(NoticesFoot.readsByItself(footInViewAtStart: false, footInViewAtEnd: true, shown: 1))
    }

    @Test("The kinds left out are not drawn and the head says how many; narrowed to nothing, the page says how many lines are hidden and asks nothing by itself")
    func narrowed() async throws {
        let (session, server) = try await shell([
            Self.a: Self.page(Self.one(4, "favourite", minutes: 2, post: 30), Self.one(3, "follow", by: "Bo", minutes: 9)),
            "\(Self.a)?3": Self.page(Self.one(2, "favourite", by: "Cy", minutes: 20, post: 30)),
            "\(Self.a)?2": Self.page(Self.one(1, "favourite", by: "Di", minutes: 30, post: 30)),
        ], signedIn: [Self.a: Self.reads])
        await session.noticeList.read(in: session)
        let root = Root()

        root.prefs.noticesHidden = ["favourite"]
        let (_, some) = hosted(session, root: root)
        #expect(rows(some) == [session.noticeList.lines[1].id])
        #expect(some.says[.head] == "1 kind left out")

        // Every line hidden, and older ones to be had: the foot is there to press, and coming
        // into view it reads nothing — or the whole history would be read with nothing shown.
        root.prefs.noticesHidden = ["favourite", "follow"]
        let (view, none) = hosted(session, root: root)
        for _ in 0..<20 { Self.settle(view) }
        #expect(rows(none).isEmpty)
        #expect(none.says[.none] == "2 notices read so far are all of kinds you left out. Show a kind again above, or read older ones below.")
        #expect(none.says[.foot] == NoticesFoot.more.words())
        #expect(await server.asked == [Self.a], "a list narrowed to nothing read on by itself")
        #expect(!session.noticeList.isReading && session.noticeList.lines.count == 2)

        // With no older ones to be had, the words do not send the reader to a foot that has none.
        #expect(NoticesNone.narrowed(2).words(language: .english, older: false)
            == "2 notices read so far are all of kinds you left out. Show a kind again above.")

        root.prefs.noticesHidden = []
        let (_, all) = hosted(session, root: root)
        #expect(rows(all).count == 2 && all.says[.head] == "Every kind")
        #expect(await server.asked == [Self.a], "narrowing asked a source something")
    }

    // MARK: - A row

    @Test("Each row is drawn with the glyph of what happened, who, the post, its source and when, and tells a listener all of it")
    func rowsAndTheirWords() async throws {
        let (session, _) = try await shell([
            Self.a: Self.page(
                Self.one(5, "mention", minutes: 1, post: 31, words: "Hello there"),
                Self.one(4, "favourite", by: "Bo", minutes: 2, post: 30),
                Self.one(3, "follow", by: "Cy", minutes: 9),
                Self.one(2, "annual_report", by: "Di", minutes: 12)
            ),
        ], signedIn: [Self.a: Self.reads])
        await session.noticeList.read(in: session)
        let lines = session.noticeList.lines
        #expect(lines.count == 4)

        let (_, page) = hosted(session)
        for notice in lines {
            #expect(page.says[.row(notice.id)] == NoticeWords.spoken(notice), "the label the page's row set is not what the words say")
        }

        for notice in lines {
            let probe = NoticeRowProbe()
            let row = NSHostingView(rootView: NoticeRow(notice: notice, probe: probe).frame(width: 600))
            row.frame = NSRect(origin: .zero, size: row.fittingSize)
            row.layoutSubtreeIfNeeded()
            #expect(probe.spoken == NoticeWords.spoken(notice))
            #expect(probe.spoken?.contains("From a.example") == true)
            for part in [NoticeRowProbe.Part.glyph, .who, .source, .age] {
                #expect((probe.frames[part]?.width ?? 0) > 0, "\(notice.kind.type): \(part) was not drawn")
            }
            // What happened is drawn as words only where the glyph is one many kinds share.
            #expect((probe.frames[.whatWords] != nil) == !NoticeWords.symbolSays(notice), "\(notice.kind.type): what happened is drawn twice, or not at all")
            #expect((probe.frames[.excerpt] != nil) == (notice.post != nil), "the post's words are drawn exactly where there is a post")
            #expect(probe.frames[.tooOld] == nil)
        }
        let heard = lines.map { NoticeWords.spoken($0, language: .english) }
        #expect(heard[0].hasPrefix("Ada mentioned you: Hello there. From a.example, "))
        #expect(heard[1].hasPrefix("Bo favourited your post: The post it is about. From a.example, "))
        #expect(heard[2].hasPrefix("Cy followed you. From a.example, "))
        #expect(heard[3].hasPrefix("A notice of a kind Fediqo does not know yet: annual_report (Di). From a.example, "))
    }

    @Test("A row about a post its author covered draws and says what it was covered with, and its words are nowhere on the page")
    func aCoveredPostStaysCoveredOnItsRow() async throws {
        func covered(_ id: Int, post: Int, _ cover: String) -> String {
            """
            {"id":"\(id)","type":"mention","created_at":"\(Self.ago(id))",\
            "account":{"id":"\(id)","username":"ada","acct":"ada","display_name":"Ada"},\
            "status":{"id":"\(post)","uri":"https://\(Self.a)/p/\(post)","created_at":"\(Self.ago(id + 5))",\
            "content":"<p>What was put under the cover</p>",\(cover),\
            "account":{"username":"ada","acct":"ada","display_name":"Ada"}}}
            """
        }
        let (session, _) = try await shell([
            Self.a: Self.page(
                covered(1, post: 31, #""sensitive":false,"spoiler_text":"Spoilers for the finale""#),
                covered(2, post: 32, #""sensitive":true,"spoiler_text":"""#),
                Self.one(3, "mention", minutes: 3, post: 33, words: "Said in the open")
            ),
        ], signedIn: [Self.a: Self.reads])
        await session.noticeList.read(in: session)
        let lines = session.noticeList.lines
        #expect(lines.map { $0.post?.body } == ["What was put under the cover", "What was put under the cover", "Said in the open"])

        let (_, page) = hosted(session)
        let said = lines.compactMap { page.says[.row($0.id)] }
        #expect(said.count == 3)
        #expect(said[0].hasPrefix("Ada mentioned you: Author's warning: Spoilers for the finale. From a.example, "))
        #expect(said[1].hasPrefix("Ada mentioned you: Covered. From a.example, "))
        #expect(said[2].hasPrefix("Ada mentioned you: Said in the open. From a.example, "))
        #expect(!page.says.values.contains { $0.contains("under the cover") }, "a covered post's words are said on the page")

        for (notice, shown) in zip(lines, ["Author's warning: Spoilers for the finale", "Covered", "Said in the open"]) {
            let probe = NoticeRowProbe()
            let row = NSHostingView(rootView: NoticeRow(notice: notice, probe: probe).frame(width: 600))
            row.frame = NSRect(origin: .zero, size: row.fittingSize)
            row.layoutSubtreeIfNeeded()
            #expect(NoticeWords.excerpt(notice, language: .english) == shown)
            #expect(probe.spoken == NoticeWords.spoken(notice) && probe.spoken?.contains("under the cover") == false)
            #expect((probe.frames[.excerpt]?.height ?? 0) > 0, "a covered post's line says nothing of it")
        }
    }

    @Test("At 320 points nothing of a row is cut and it still says its source, at every size of text the app reaches and past it",
          arguments: [DynamicTypeSize.xSmall, .large, .xxLarge, .xxxLarge, .accessibility1, .accessibility2])
    func nothingCutAt320(_ type: DynamicTypeSize) throws {
        let width: CGFloat = 320
        let source = Source(host: "a-rather-long-instance-name.example", kind: .mastodon)
        let people = [
            NoticePerson(handle: "@ada@elsewhere.example", name: "Ada Augusta Lovelace of the Analytical Engine"),
            NoticePerson(handle: "@bo@elsewhere.example", name: "Bo"),
        ]
        let post = Note(
            id: "https://a.example/p/30", source: source, author: "Me", handle: "@me", body: String(repeating: "words and more words ", count: 12),
            postedAt: Date().addingTimeInterval(-600), categories: [], statusID: "30"
        )
        let notice = Notice(
            source: source, handle: .gathered(key: "favourite-30-1"), kind: .favourite, people: people, count: 12,
            post: post, at: Date().addingTimeInterval(-34 * 86_400), newestID: "9", oldestID: "1"
        )
        let probe = NoticeRowProbe()
        let row = NoticeRow(notice: notice, tooOld: true, probe: probe)
            .environment(\.shellLayout, .narrow)
            .dynamicTypeSize(type)
        let hosted = NSHostingView(rootView: row.frame(width: width))
        hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
        hosted.layoutSubtreeIfNeeded()

        let inside = width - 2 * ShellSpace.pad
        for part in [NoticeRowProbe.Part.head, .glyph, .excerpt, .tooOld] {
            let frame = try #require(probe.frames[part], "\(part) was not laid out at \(type)")
            #expect(frame.minX >= -0.5 && frame.maxX <= inside + 0.5, "\(type): \(part) runs past the row")
        }
        let age = try #require(probe.frames[.age]), head = try #require(probe.frames[.head])
        #expect(age.maxX <= head.maxX + 0.5 && age.minX >= head.minX, "\(type): the age is cut")
        let whole = Self.ideal(Text(notice.at, format: .relative(presentation: .numeric, unitsStyle: .narrow))
            .shellFont(.reading).lineLimit(1), type).width
        #expect(age.width >= whole - 0.5, "\(type): the age is drawn short")

        // Every line says its source: the pill is its host or its host's first letter, whole.
        let pill = try #require(probe.frames[.source], "\(type): the line stopped saying its source")
        let letter = Self.ideal(Text("a").shellFont(.mark).lineLimit(1), type).width
        #expect(pill.width >= letter + 2 * ShellSpace.tight, "\(type): the pill is an empty shape")
        #expect(pill.minX >= head.minX - 0.5 && pill.maxX <= age.minX + 0.5, "\(type): the pill is not inside the line")
        #expect(NoticeRow.Pill.allCases.allSatisfy { $0.says(source.host) != nil }, "no rung gives the source up")

        // The words that are not meant to be cut short stand at the height they ask for.
        let glyph = try #require(probe.frames[.glyph]), tooOld = try #require(probe.frames[.tooOld])
        let saidOld = Self.wrapped(Text(NoticeRow.tooOldWords()).shellFont(.meta), width: tooOld.width, type)
        #expect(tooOld.height >= saidOld - 0.5, "\(type): the too-old words are cut")
        #expect(glyph.width >= Self.glyphSide(type) - 0.5 && glyph.height >= Self.glyphSide(type) - 0.5, "\(type): the glyph is squeezed")
        #expect(probe.frames[.whatWords] == nil, "\(type): what a glyph of its own says is drawn as words too")
        if let who = probe.frames[.who] {
            #expect(who.width > 0 && who.minX >= glyph.maxX - 0.5 && who.maxX <= pill.minX + 0.5)
        }
    }

    // MARK: - The glyph and the name

    /// The side of the square a row's glyph stands in.
    private static func glyphSide(_ type: DynamicTypeSize) -> CGFloat {
        DummyItemRow.Box.vis * ShellType.multiple(at: type)
    }

    private static let source = Source(host: a, kind: .mastodon)
    private static let ada = NoticePerson(handle: "@ada@elsewhere.example", name: "Ada")

    private static func made(_ kind: Notice.Kind, people: [NoticePerson] = [ada], count: Int = 1, words: String? = nil) -> Notice {
        let post = words.map {
            Note(
                id: "https://a.example/p/30", source: source, author: "Me", handle: "@me", body: $0,
                postedAt: Date().addingTimeInterval(-600), categories: [], statusID: "30"
            )
        }
        return Notice(
            source: source, handle: .one(id: "1"), kind: kind, people: people, count: count, post: post,
            at: Date().addingTimeInterval(-120), newestID: "1", oldestID: "1"
        )
    }

    private static func laidOut(
        _ notice: Notice, width: CGFloat, type: DynamicTypeSize = .large, menu: Bool = false
    ) -> NoticeRowProbe {
        let probe = NoticeRowProbe()
        let row = NoticeRow(
            notice: notice, menu: menu ? NoticeRow.Menu(more: { ShellMore(items: []) }, asks: .constant(nil)) : nil, probe: probe
        )
        .environment(\.shellLayout, width < 400 ? .narrow : .wide)
        .dynamicTypeSize(type)
        let hosted = NSHostingView(rootView: row.frame(width: width))
        hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
        hosted.layoutSubtreeIfNeeded()
        return probe
    }

    @Test("Every kind's line opens on the glyph of what happened, whole in one square at one edge, with the name after it; the glyph's words are what happened, and a listener hears what it did",
          arguments: [600, 320] as [CGFloat])
    func theGlyphHeadsEveryLine(_ width: CGFloat) throws {
        let kinds: [Notice.Kind] = NoticeWords.named + [.server("admin.sign_up"), .server("moderation_warning"), .unknown("annual_report")]
        let side = Self.glyphSide(.large)
        for kind in kinds {
            let notice = Self.made(kind, words: "The post it is about")
            let probe = Self.laidOut(notice, width: width)
            let glyph = try #require(probe.frames[.glyph], "\(kind.type): no glyph"), head = try #require(probe.frames[.head])
            #expect(abs(glyph.width - side) <= 0.5 && abs(glyph.height - side) <= 0.5, "\(kind.type): the glyph's square is \(glyph.size)")
            #expect(abs(glyph.minX) <= 0.5 && glyph.minY >= head.minY - 0.5 && glyph.maxY <= head.maxY + 0.5, "\(kind.type): the glyph is not at the head of the first line")
            let drawn = Self.ideal(Image(systemName: NoticeWords.symbol(notice)).shellFont(DummyItemRow.visRole), .large)
            #expect(drawn.width > 0 && drawn.width <= side + 0.5 && drawn.height <= side + 0.5, "\(kind.type): \(NoticeWords.symbol(notice)) is no glyph, or runs out of its square")
            let who = try #require(probe.frames[.who], "\(kind.type): nobody is named")
            #expect(abs(who.minX - (glyph.maxX + ShellSpace.snug)) <= 0.5 && who.minY >= head.minY - 0.5 && who.maxY <= head.maxY + 0.5, "\(kind.type): the name does not follow the glyph")
            #expect(who.width >= Self.ideal(Text("Ada").shellFont(.name).lineLimit(1), .large).width - 0.5, "\(kind.type): the name is cut")
            #expect(probe.glyphSays == NoticeWords.what(notice), "\(kind.type): the glyph does not say what happened")
            #expect(probe.spoken == NoticeWords.spoken(notice))
            // Words under the name only where the glyph is one many kinds share.
            if NoticeWords.symbolSays(notice) {
                #expect(probe.frames[.whatWords] == nil, "\(kind.type): what its glyph says is drawn as words too")
            } else {
                let words = try #require(probe.frames[.whatWords], "\(kind.type): nothing on the line says what happened")
                #expect(words.minY >= head.maxY - 0.5 && words.height >= Self.wrapped(Text(NoticeWords.what(notice)).shellFont(.meta), width: words.width, .large) - 0.5)
            }
        }
        // What a listener hears is what it was before the glyph stood at the head.
        let heard = [Notice.Kind.mention, .favourite, .follow, .unknown("annual_report")].map {
            NoticeWords.spoken(Self.made($0, words: $0 == .follow ? nil : "Hello there"), language: .english)
        }
        #expect(heard[0].hasPrefix("Ada mentioned you: Hello there. From a.example, "))
        #expect(heard[1].hasPrefix("Ada favourited your post: Hello there. From a.example, "))
        #expect(heard[2].hasPrefix("Ada followed you. From a.example, "))
        #expect(heard[3].hasPrefix("A notice of a kind Fediqo does not know yet: annual_report (Ada): Hello there. From a.example, "))
    }

    @Test("A line that names nobody says what happened in the name's place, whole, and is no glyph alone",
          arguments: [600, 320] as [CGFloat], [DummyFontSize.standard.dynamicType, DummyFontSize.largest.dynamicType])
    func aLineNamingNobody(_ width: CGFloat, _ type: DynamicTypeSize) throws {
        for kind in [Notice.Kind.server("moderation_warning"), .server("severed_relationships"), .server("made_up"), .unknown("annual_report")] {
            let notice = Self.made(kind, people: [])
            let probe = Self.laidOut(notice, width: width, type: type, menu: true)
            let what = NoticeWords.what(notice)
            let glyph = try #require(probe.frames[.glyph]), head = try #require(probe.frames[.head])
            let words = try #require(probe.frames[.whatWords], "\(kind.type): the line is a glyph alone")
            #expect(probe.frames[.who] == nil)
            #expect(abs(words.minX - (glyph.maxX + ShellSpace.snug)) <= 0.5 && words.minY >= head.minY - 0.5 && words.maxY <= head.maxY + 0.5, "\(kind.type): what happened is not in the name's place")
            let asks = Self.wrapped(Text(what).shellFont(.name, weight: .regular), width: words.width, type)
            #expect(words.height >= asks - 0.5, "\(kind.type) at \(type): what happened is cut: \(words.height) of \(asks)")
            let pill = try #require(probe.frames[.source]), age = try #require(probe.frames[.age])
            #expect(words.maxX <= pill.minX + 0.5 && pill.maxX <= age.minX + 0.5 && age.maxX <= head.maxX + 0.5)
            #expect(probe.glyphSays == what && probe.spoken == NoticeWords.spoken(notice))
        }
        #expect(NoticeWords.what(Self.made(.unknown("annual_report"), people: []), language: .english) == "A notice of a kind Fediqo does not know yet: annual_report")
        #expect(NoticeWords.spoken(Self.made(.server("moderation_warning"), people: []), language: .english).hasPrefix("The server's moderators sent you a warning. From a.example, "))
    }

    @Test("At 320 points a line with its glyph, a name, its post and its three dots cuts nothing: the name whole after the glyph, the source and the age whole, the dots whole under the first line beside the post's words",
          arguments: [DummyFontSize.standard.dynamicType, DummyFontSize.largest.dynamicType])
    func aNamedLineAt320(_ type: DynamicTypeSize) throws {
        let width: CGFloat = 320, inside = width - 2 * ShellSpace.pad
        let named = NoticePerson(handle: "@ada@elsewhere.example", name: "Ada L.")
        let notice = Self.made(.favourite, people: [named], words: String(repeating: "words and more words ", count: 12))
        let probe = Self.laidOut(notice, width: width, type: type, menu: true)

        let head = try #require(probe.frames[.head]), glyph = try #require(probe.frames[.glyph])
        let who = try #require(probe.frames[.who]), pill = try #require(probe.frames[.source]), age = try #require(probe.frames[.age])
        let excerpt = try #require(probe.frames[.excerpt]), dots = try #require(probe.frames[.more])
        for (part, frame) in probe.frames {
            #expect(frame.minX >= -0.5 && frame.maxX <= inside + 0.5, "\(type): \(part) runs past the row")
        }
        // The first line: each part at the width it asks for, in order.
        let side = Self.glyphSide(type)
        #expect(abs(glyph.width - side) <= 0.5 && abs(glyph.height - side) <= 0.5, "\(type): the glyph is squeezed")
        let name = Self.ideal(Text("Ada L.").shellFont(.name).lineLimit(1), type).width
        #expect(who.width >= name - 0.5, "\(type): the name is cut: \(who.width) of \(name)")
        let when = Self.ideal(Text(notice.at, format: .relative(presentation: .numeric, unitsStyle: .narrow))
            .shellFont(.reading).lineLimit(1), type).width
        #expect(age.width >= when - 0.5, "\(type): the age is cut")
        let letter = Self.ideal(Text("a").shellFont(.mark).lineLimit(1), type).width
        #expect(pill.width >= letter + 2 * ShellSpace.tight, "\(type): the pill is an empty shape")
        #expect(glyph.maxX <= who.minX + 0.5 && who.maxX <= pill.minX + 0.5 && pill.maxX <= age.minX + 0.5 && age.maxX <= head.maxX + 0.5, "\(type): the first line's parts lie over one another")
        // Under it: the dots whole, beside the post's words and not over them.
        let box = Self.ideal(Image(systemName: ShellMore.symbol).modifier(ShellGlyphBox()), type)
        #expect(dots.width >= box.width - 1 && dots.height >= box.height - 1, "\(type): the three dots are squeezed")
        #expect(dots.minY >= head.maxY - 0.5 && excerpt.minY >= head.maxY - 0.5 && excerpt.maxX <= dots.minX + 0.5, "\(type): the three dots are not under the first line, beside the words")
        let lines = Self.wrapped(Text(try #require(NoticeWords.excerpt(notice))).shellFont(.body).lineLimit(NoticeRow.excerptLines), width: excerpt.width, type)
        #expect(excerpt.height >= lines - 0.5, "\(type): the post's words stand short of their two lines")
        #expect(probe.spoken == NoticeWords.spoken(notice))

        // A line with nothing under its first — a follow — still has its dots there, whole.
        let follow = Self.laidOut(Self.made(.follow, people: [named]), width: width, type: type, menu: true)
        let alone = try #require(follow.frames[.more]), first = try #require(follow.frames[.head])
        #expect(alone.width >= box.width - 1 && alone.height >= box.height - 1 && alone.minY >= first.maxY - 0.5 && alone.maxX <= inside + 1)
        #expect((follow.frames[.who]?.width ?? 0) >= name - 0.5, "\(type): a follow's name is cut")
    }

    /// The size a view asks for with nothing holding it in.
    private static func ideal(_ view: some View, _ type: DynamicTypeSize) -> CGSize {
        NSHostingView(rootView: view.fixedSize().dynamicTypeSize(type)).fittingSize
    }

    /// How tall words stand when they are wrapped to `width` and nothing is cut.
    private static func wrapped(_ text: some View, width: CGFloat, _ type: DynamicTypeSize) -> CGFloat {
        NSHostingView(
            rootView: text.fixedSize(horizontal: false, vertical: true).frame(width: width).dynamicTypeSize(type)
        ).fittingSize.height
    }

    @Test("At 320 points nothing on the page is cut short: the head's name and marks whole, each source's words at the height they ask for and its press whole",
          arguments: [DummyFontSize.standard.dynamicType, DynamicTypeSize.accessibility1])
    func thePageAt320(_ type: DynamicTypeSize) async throws {
        let (session, _) = try await shell([
            Self.a: Self.page(Self.one(4, "favourite", minutes: 2, post: 30), Self.one(3, "follow", by: "Bo", minutes: 9)),
            "a-rather-long-instance-name.example": .status(503),
        ], signedIn: [Self.a: Self.reads, "a-rather-long-instance-name.example": Self.reads, "c.example": Self.plain])
        await session.noticeList.read(in: session)
        let root = Root()
        root.prefs.noticesHidden = ["poll"]

        let (view, probe) = hosted(session, root: root, width: 320, layout: .narrow, type: type)
        for _ in 0..<3 { Self.settle(view) }
        #expect(rows(probe).count == 2)
        for (part, frame) in probe.frames {
            #expect(frame.minX >= -0.5 && frame.maxX <= 320.5, "\(type): \(part) runs past a page 320 points across")
        }

        // The head: the name whole, the two marks whole and clear of it; the words about the
        // kinds whole where they are drawn, and given up where there is no room.
        let title = try #require(probe.frames[.title])
        #expect(title.width >= Self.ideal(Text(ShellPlace.notices.title).shellFont(.name).lineLimit(1), type).width - 0.5, "\(type): the place's name is cut")
        let box = Self.ideal(Image(systemName: NoticeKindsMenu.symbol).modifier(ShellGlyphBox()), type)
        for mark in [NoticesProbe.Part.kindsMark, .reloadMark] {
            let frame = try #require(probe.frames[mark], "\(type): \(mark) is not drawn")
            #expect(frame.width >= box.width - 0.5 && frame.height >= box.height - 0.5, "\(type): \(mark) is squeezed")
            #expect(frame.minX >= title.maxX - 0.5 || frame.minY >= title.maxY - 0.5, "\(type): \(mark) lies over the name")
        }
        if let words = probe.frames[.kindsWords] {
            let whole = Self.ideal(Text(NoticeWords.narrowed(root.prefs.noticesHidden)).shellFont(.meta).lineLimit(1), type).width
            #expect(words.width >= whole - 0.5 && words.minX >= title.maxX - 0.5, "\(type): the words about the kinds are cut")
        }

        // Each source's line: its words at the height they ask for at the width they have,
        // and the press beside or under them whole.
        let lines = NoticesPane.lines(in: session)
        #expect(lines.map(\.id) == ["failed:a-rather-long-instance-name.example", "unasked:c.example"])
        for line in lines {
            let words = try #require(probe.frames[.lineWords(line.id)], "\(type): \(line.id) is not drawn")
            let asks = Self.wrapped(Text(line.words()).shellFont(.meta), width: words.width, type)
            #expect(words.height >= asks - 0.5, "\(type): \(line.id) is cut: \(words.height) of \(asks)")
        }
        let press = try #require(probe.frames[.linePress("failed:a-rather-long-instance-name.example")])
        let button = Self.ideal(ShellLinkButton(L10n.t("notices.retry")) {}, type)
        #expect(press.width >= button.width - 0.5 && press.height >= button.height - 0.5, "\(type): the press to ask again is cut")

        // The foot's words wrap too.
        let foot = try #require(probe.frames[.foot])
        #expect(foot.height >= Self.wrapped(Text(NoticesFoot.more.words()).shellFont(.meta), width: 320 - 2 * ShellSpace.pad, type) - 0.5)

        // And the two pages with no list.
        let (empty, _) = try await shell([:], signedIn: [Self.a: nil])
        let (nobody, said) = hosted(empty, width: 320, layout: .narrow, type: type)
        Self.settle(nobody)
        let whole = try #require(said.frames[.nobody])
        #expect(whole.maxX <= 320.5 && whole.height > 0)
        let (unasked, _) = try await shell([:], signedIn: ["a-rather-long-instance-name.example": Self.plain])
        let (notAllowed, told) = hosted(unasked, width: 320, layout: .narrow, type: type)
        Self.settle(notAllowed)
        let named = try #require(told.frames[.lineWords("unasked:a-rather-long-instance-name.example")])
        let asks = Self.wrapped(
            Text(NoticesLine.unasked(host: "a-rather-long-instance-name.example").words()).shellFont(.meta), width: named.width, type
        )
        #expect(named.maxX <= 320.5 && named.height >= asks - 0.5, "\(type): the source's words are cut")
    }

    // MARK: - Opening

    @Test("A line's post is held on opening, the walk opens it in its conversation, and leaving the walk is back on the line")
    func theWalkOpenedAndReturnedFrom() async throws {
        let (session, _) = try await shell([
            Self.a: Self.page(Self.one(4, "favourite", minutes: 2, post: 30), Self.one(3, "follow", by: "Bo", minutes: 9)),
            "\(Self.a)?3": Self.page(),
        ], signedIn: [Self.a: Self.reads])
        await session.noticeList.read(in: session)
        let line = try #require(session.noticeList.lines.first)
        guard case .post(let post) = NoticeWords.opens(line) else {
            Issue.record("a favourite opens its post")
            return
        }
        #expect(session.notes.isEmpty, "the post was held before anybody opened it")

        // The press on the page reaches the root with the line, once selected and pressed again.
        let root = Root()
        let (_, page) = hosted(session, root: root)
        #expect(page.frames[.row(line.id)] != nil)
        let pane = NoticesPane(
            session: session, selectedID: .constant(line.id), mark: root.mark, canReload: true, onReload: {},
            onOpen: { root.opened.append($0.id) }, onOpenPerson: { _, _ in }
        )
        pane.press(line)
        #expect(root.opened == [line.id])

        // What the root does with it: the post held, then one step of the timeline place's walk.
        let row = try #require(await session.landed(noticePost: post))
        #expect(session.held(row) != nil, "the conversation opens from what is held")
        var walk = ShellWalk()
        let errand = try #require(NoticeErrand.setOut(to: .thread(row), for: line.id, on: &walk, lamp: nil))
        #expect(walk.openedThread == row)

        let probe = PaneProbe()
        let timeline = NSHostingView(rootView: Walked(session: session, standing: walk.standing).environment(\.shellPaneProbe, probe))
        timeline.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        for _ in 0..<5 { Self.settle(timeline) }
        #expect(probe.under.height > 0, "the conversation is drawn on the timeline place")

        // Leaving it: the errand is over, and Notices has the line again — lit, and kept as
        // the one being read for a finger.
        let left = walk.back()
        #expect(left != nil)
        #expect(errand.isOver(walk))
        root.selected = errand.notice
        root.mark.keep(errand.notice)
        let (_, back) = hosted(session, root: root)
        #expect(back.frames[.row(line.id)] != nil)
        #expect(root.mark.id == line.id && root.mark.lamp(for: line.id).lit)
    }

    /// The timeline place standing on a step of the walk, as the root draws it.
    private struct Walked: View {
        let session: ShellSession
        let standing: ShellStep?
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()
        @State private var prefs = DummyPrefs(defaults: UserDefaults(suiteName: "fediqo.test.noticeswalk.\(UUID().uuidString)")!)

        var body: some View {
            TimelinePane(
                session: session, selectedID: $selected, standing: standing, onOpenPerson: { _ in }, decks: $decks,
                playback: playback, onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in },
                onOpenThread: { _ in }, jumpToTop: 0, onBack: {},
                ways: TimelineWays(canSearch: false, onSearch: {}, canReload: false, onReload: {}),
                search: ShellSearch()
            )
            .environment(prefs)
        }
    }

    @Test("A notice about a person leads to that person, by the row and by its name")
    func aPersonIsOpened() async throws {
        let (session, _) = try await shell(
            [Self.a: Self.page(Self.one(3, "follow", by: "Bo", minutes: 9))], signedIn: [Self.a: Self.reads]
        )
        await session.noticeList.read(in: session)
        let line = try #require(session.noticeList.lines.first)
        guard case .person(let person) = NoticeWords.opens(line) else {
            Issue.record("a follow leads to the person")
            return
        }
        #expect(person.name == "Bo" && person.host == Self.a)
        var walk = ShellWalk()
        let errand = try #require(NoticeErrand.setOut(to: .person(person), for: line.id, on: &walk, lamp: "lamp"))
        #expect(walk.openedPerson == person)
        #expect(session.heldPosts(of: person).isEmpty, "what this device holds of them, which may be nothing")
        let left = walk.back()
        #expect(left?.lamp == "lamp" && errand.isOver(walk))
    }

    @Test("A post the store refuses as older than the person keeps says so on its line, and opens nothing")
    func tooOldSaysSo() async throws {
        let (session, _) = try await shell([
            Self.a: Self.page(Self.one(4, "favourite", minutes: 2, post: 30, written: "2019-03-01T00:00:00.000Z")),
        ], signedIn: [Self.a: Self.reads])
        _ = await session.store.setRetention(months: 3)
        await session.noticeList.read(in: session)
        let line = try #require(session.noticeList.lines.first)
        guard case .post(let post) = NoticeWords.opens(line) else {
            Issue.record("a favourite opens its post")
            return
        }

        #expect(await session.landed(noticePost: post) == nil, "a post older than the person keeps was held")
        #expect(session.notes.isEmpty)

        // The page hands the line the word, and the label that row sets carries it.
        let root = Root()
        let (_, before) = hosted(session, root: root)
        #expect(before.says[.row(line.id)] == NoticeWords.spoken(line))
        root.tooOld = line.id
        let (_, probe) = hosted(session, root: root)
        #expect(probe.frames[.row(line.id)] != nil)
        let heard = try #require(probe.says[.row(line.id)])
        #expect(heard.hasPrefix(NoticeWords.spoken(line)) && heard.hasSuffix(NoticeRow.tooOldWords()), "the page's row does not say the post is too old")

        let said = NoticeRowProbe()
        let row = NSHostingView(rootView: NoticeRow(notice: line, tooOld: true, probe: said).frame(width: 600))
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        row.layoutSubtreeIfNeeded()
        #expect((said.frames[.tooOld]?.height ?? 0) > 0, "the line does not say why nothing opened")
        #expect(NoticeRow.tooOldWords(language: .english) == "This post is older than this device keeps, so it cannot be opened here.")
        #expect(said.spoken?.hasSuffix(NoticeRow.tooOldWords()) == true, "a listener is told too")
        #expect(NoticeRow.tooOldWords(language: .taiwanese) != NoticeRow.tooOldWords(language: .english))
    }

    @Test("A source held to the bound is drawn as a line above the list, whole, saying its older notices are not shown")
    func aFullSourceIsDrawn() async throws {
        let (session, _) = try await shell([
            Self.a: Self.page(Self.one(4, "favourite", minutes: 2), Self.one(3, "favourite", minutes: 4)),
            Self.b: Self.page(Self.one(8, "mention", by: "Cy", minutes: 5)),
            "\(Self.b)?8": Self.page(),
        ], signedIn: [Self.a: Self.reads, Self.b: Self.reads])
        session.noticeList.capacity = 2
        await session.noticeList.read(in: session)
        #expect(session.noticeList.fullHosts == [Self.a])

        for width in [600, 320] as [CGFloat] {
            let (_, probe) = hosted(session, width: width, layout: width < 400 ? .narrow : .wide)
            let words = NoticesLine.full(host: Self.a).words()
            #expect(probe.says[.line("full:a.example")] == words, "what a listener is read is the line's own words")
            let line = try #require(probe.frames[.line("full:a.example")])
            let said = try #require(probe.frames[.lineWords("full:a.example")])
            #expect(said.height > 0 && said.maxX <= width + 1, "the words were cut at \(width)")
            #expect(probe.frames[.linePress("full:a.example")] == nil, "nothing is offered to press: a reload reads the newest")
            let first = try #require(rows(probe).first.flatMap { probe.frames[.row($0)] })
            #expect(line.maxY <= first.minY + 1, "the name stands above the lines")
            #expect(rows(probe).count == 3)
        }
    }
}
#endif
