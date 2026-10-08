import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A write is shown first and sent after: the mark changes at the press, the source is asked
/// afterwards, and a refusal, a failure or no answer in time puts it back and says so — for a
/// boost, a favourite and a bookmark, put and taken back, and for taking a post back, whose row
/// leaves at the question's yes.
///
/// What a test can reach: what the row's mark is drawn as, named and counted while the request
/// is held on the wire, and what the store holds under it; each way of not arriving putting the
/// mark back and saying its line; a read landing meanwhile, and the source's later word; a
/// second press; the row taken back leaving every list and coming back. What it cannot: the mark
/// and the line drawn on a Mac and a phone, in light and dark, and VoiceOver reading them.
@Suite("A write is shown first and sent after")
@MainActor
struct ShownFirstTests {
    init() {
        L10n.language = .english
    }

    private static let host = "social.example"

    /// How the source answers a write.
    enum Answer: Sendable {
        /// It does it, and says so.
        case yes
        /// It answers with the post as it was: the write did not take.
        case unmoved
        case status(Int)
        case unreachable
        /// Nothing came in time: the write may have landed.
        case timedOut
        /// A 401 it stands by when asked who this is: the sign-in is over.
        case ended
    }

    /// One source as its signed-in reader `me` sees it: Home holding post 9, somebody else's,
    /// and post 1, their own; the three acts on 9, and taking 1 back. **A write waits on the
    /// gate before anything changes**, so a press is caught between leaving and being answered.
    private actor Server: HTTPSender {
        private var marks: [PostAct: Bool]
        private var mineIsThere = true
        private var answer: Answer
        private var gate: Gate?
        private var over = false
        private(set) var writes: [String] = []

        init(_ said: Bool, answering answer: Answer) {
            marks = [.favourite: said, .boost: said, .bookmark: said]
            self.answer = answer
        }

        func hold(_ gate: Gate?) { self.gate = gate }

        func answers(_ answer: Answer) { self.answer = answer }

        /// The mark moved somewhere else — another app — with nothing asked from here.
        func elsewhere(_ act: PostAct, _ on: Bool) { marks[act] = on }

        private var nine: String {
            """
            {"id":"9","uri":"https://social.example/users/ada/statuses/9",
             "created_at":"2024-06-02T00:00:00.000Z","content":"<p>hello</p>","visibility":"public",
             "favourited":\(marks[.favourite]!),"reblogged":\(marks[.boost]!),"bookmarked":\(marks[.bookmark]!),
             "reblogs_count":\(2 + (marks[.boost]! ? 1 : 0)),"favourites_count":\(3 + (marks[.favourite]! ? 1 : 0)),
             "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
            """
        }

        private let one = """
        {"id":"1","uri":"https://social.example/users/me/statuses/1",
         "created_at":"2024-06-01T00:00:00.000Z","content":"<p>mine</p>","visibility":"public",
         "account":{"username":"me","acct":"me","display_name":"Me"}}
        """

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let url = request.url else { throw FixtureHTTPError.unmapped }
            func answered(_ body: String, _ status: Int = 200) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
            switch url.path {
            case "/api/v1/accounts/verify_credentials": return over ? answered("{}", 401) : answered(#"{"acct":"me"}"#)
            case "/oauth/revoke": return answered("{}")
            case "/api/v1/timelines/home": return answered(mineIsThere ? "[\(nine),\(one)]" : "[\(nine)]")
            default: break
            }
            let write: (act: PostAct, on: Bool)
            switch url.path {
            case "/api/v1/statuses/9/favourite": write = (.favourite, true)
            case "/api/v1/statuses/9/unfavourite": write = (.favourite, false)
            case "/api/v1/statuses/9/reblog": write = (.boost, true)
            case "/api/v1/statuses/9/unreblog": write = (.boost, false)
            case "/api/v1/statuses/9/bookmark": write = (.bookmark, true)
            case "/api/v1/statuses/9/unbookmark": write = (.bookmark, false)
            case "/api/v1/statuses/1" where request.httpMethod == "DELETE": write = (.withdraw, true)
            default: throw FixtureHTTPError.unmapped
            }
            writes.append("\(write.act) \(write.on)")
            // How it answers is settled as the request arrives, however long it is held.
            let answer = answer
            await gate?.wait()
            switch answer {
            case .yes:
                if write.act == .withdraw { mineIsThere = false } else { marks[write.act] = write.on }
            case .unmoved: break
            case .status(let code): return answered("{}", code)
            case .unreachable: throw URLError(.notConnectedToInternet)
            case .timedOut: throw URLError(.timedOut)
            case .ended:
                over = true
                return answered("{}", 401)
            }
            return answered(write.act == .withdraw ? "{}" : nine)
        }
    }

    /// A session signed in to act as `me`, holding what Home last brought — post 9 with every
    /// mark `said`, and post 1 — the timeline that reads Home, and what the strip said aloud.
    private func shell(
        _ said: Bool = false, answering answer: Answer = .yes
    ) async throws -> (ShellSession, Server, TimelineQuery) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
            scopes: MastodonOAuth.scopes(writing: true)
        ))
        let server = Server(said, answering: answer)
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        let session = ShellSession(
            http: FixtureHTTP(), store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.said.announce = { _ in }
        session.mastodon.refresh()
        await session.mastodon.verifyAll()
        await session.reloadFromStore()
        let home = TimelineDefinition(name: "Home", rules: [
            try #require(Rule.category(.home, in: .source(host: Self.host), sources: session.sources)),
        ])
        session.written = [home]
        await session.reload.timeline(.written(home.id), in: session)
        #expect(session.notes.count == 2, "the premise: Home brought both posts")
        return (session, server, .written(home.id))
    }

    private func row(_ session: ShellSession, _ id: String = "9") throws -> DummyItem {
        DummyItem(try #require(session.notes.first { $0.statusID == id }))
    }

    /// The mark as the row draws it now: off the session's standings, over what it holds.
    private func mark(_ act: PostAct, _ session: ShellSession) throws -> ItemMark {
        let row = try row(session)
        return ItemActs.mark(act, on: row, acting: session.acting(on: row), language: .english)
    }

    private static func held(_ act: PostAct, _ note: Note?) -> Bool? {
        switch act {
        case .favourite: note?.favourited
        case .boost: note?.boosted
        case .bookmark: note?.bookmarked
        case .answer, .withdraw: nil
        }
    }

    private static func count(_ act: PostAct, _ on: Bool) -> Int? {
        switch act {
        case .boost: 2 + (on ? 1 : 0)
        case .favourite: 3 + (on ? 1 : 0)
        case .bookmark, .answer, .withdraw: nil
        }
    }

    /// A write caught on the wire: the press made, and its request held at the server.
    private func pressed(
        _ session: ShellSession, _ server: Server, _ press: @escaping @MainActor () async -> Void
    ) async -> (press: Task<Void, Never>, gate: Gate, watchdog: Task<Void, Never>) {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        await server.hold(gate)
        let before = await server.writes.count
        let task = Task { await press() }
        #expect(await spun { await server.writes.count == before + 1 }, "the request is on the wire")
        return (task, gate, watchdog)
    }

    /// Everything has settled: no press is out, nothing is left out of what is drawn, and every
    /// mark the row draws is what the store holds.
    private func nothingDrawnTheStoreDoesNotHold(_ session: ShellSession) async throws {
        #expect(!session.acts.standings.values.contains { $0 != .failed }, "a press is still out")
        #expect(session.acts.leaving.isEmpty)
        let stored = await session.store.all()
        #expect(Set(session.notes.map(\.key)) == Set(stored.map(\.key)), "a row is drawn that is not held, or held and not drawn")
        let nine = stored.first { $0.statusID == "9" }
        for act in [PostAct.boost, .favourite, .bookmark] {
            let drawn = try mark(act, session)
            #expect(drawn.done == (Self.held(act, nine) == true), "\(act) is drawn as the store does not hold it")
            #expect(drawn.count == Self.count(act, Self.held(act, nine) == true))
        }
    }

    // MARK: - Shown at the press

    @Test(
        "At the press the mark is drawn done or taken back, counted and named, over a store that has not moved; the source's yes changes nothing drawn",
        .timeLimit(.minutes(1)),
        arguments: [PostAct.boost, .favourite, .bookmark], [true, false]
    )
    func shownAtThePress(act: PostAct, on: Bool) async throws {
        let (session, server, _) = try await shell(!on)
        var saved = 0
        session.persist = { saved += 1 }
        let item = try row(session)
        let out = await pressed(session, server) { await session.toggle(act, on: item) }
        defer { out.watchdog.cancel() }

        #expect(session.acts.standing(of: item.id, act) == .pressed(to: on))
        let atPress = try mark(act, session)
        #expect(atPress.done == on, "the mark waited for the source")
        #expect(atPress.glyph == ItemActs.glyph(act, standing: nil), "its own glyph, not a wait")
        #expect(atPress.count == Self.count(act, on), "the count moved with the mark")
        #expect(atPress.spoken == ItemActs.name(act, done: on, language: .english), "named for what the next press does")
        #expect(Self.held(act, session.notes.first { $0.statusID == "9" }) == !on, "the press was written into what is held")
        #expect(Self.held(act, await session.store.all().first { $0.statusID == "9" }) == !on, "a press is never in the store")
        #expect(saved == 0, "a press is never written down")

        await out.gate.open()
        await out.press.value
        #expect(session.acts.standings.isEmpty)
        #expect(try mark(act, session) == atPress, "the source's yes changed what is drawn")
        #expect(Self.held(act, await session.store.all().first { $0.statusID == "9" }) == on, "what the source said is what is held")
        #expect(session.said.lines.isEmpty)
        await session.saved()
        #expect(saved == 1)
        try await nothingDrawnTheStoreDoesNotHold(session)
    }

    // MARK: - Put back, and said

    @Test("A refusal, a failure, a source that would not, and no answer in time each put the mark back and say their own line, once", .timeLimit(.minutes(1)))
    func putBackAndSaid() async throws {
        let cases: [(Answer, WriteWhy, String)] = [
            (.status(403), .refused, "social.example would not let this sign-in change the boost of Ada's post. It is as it was."),
            (.unreachable, .unreachable, "social.example could not be reached, so the boost of Ada's post did not change. It is as it was."),
            (.status(500), .declined, "social.example did not change the boost of Ada's post. It is as it was."),
            (.timedOut, .unconfirmed, "social.example did not confirm the boost of Ada's post changed. Reload to see."),
            (.unmoved, .declined, "social.example did not change the boost of Ada's post. It is as it was."),
        ]
        for (answer, why, words) in cases {
            let (session, server, _) = try await shell(false, answering: answer)
            var spoken: [String] = []
            session.said.announce = { spoken.append($0) }
            let item = try row(session)
            let out = await pressed(session, server) { await session.toggle(.boost, on: item) }
            #expect(try mark(.boost, session).done, "shown first, whatever comes of it")

            await out.gate.open()
            await out.press.value
            out.watchdog.cancel()

            let back = try mark(.boost, session)
            #expect(!back.done && back.count == 2, "\(why): the mark is not as the source last said")
            #expect(session.said.lines == [Said(.act(.boost, row: item.id), why, host: Self.host, of: .by("Ada"))])
            #expect(session.said.lines.first?.words(language: .english) == words)
            #expect(spoken == [words], "a revert is announced through the strip, once")
            if case .unmoved = answer {
                // The source answered, and its word is taken: there is nothing to try again.
                #expect(session.acts.standings.isEmpty)
            } else {
                #expect(session.acts.standing(of: item.id, .boost) == .failed)
                #expect(back.glyph == "exclamationmark.triangle")
                #expect(back.spoken == "Boost did not arrive. Press to try again.")
            }
            try await nothingDrawnTheStoreDoesNotHold(session)
        }
    }

    @Test("The same act succeeding takes its line down; a bookmark the source forbids is said on the strip beside the row's own sentence")
    func theLineGoesWhenTheActLands() async throws {
        let (session, server, _) = try await shell(false, answering: .unreachable)
        let item = try row(session)
        await session.toggle(.favourite, on: item)
        #expect(session.said.lines.map(\.what) == [.act(.favourite, row: item.id)])
        await server.answers(.yes)
        await session.toggle(.favourite, on: item)
        #expect(session.said.lines.isEmpty, "the act landed and its failure is still said")
        #expect(try mark(.favourite, session).done)

        await server.answers(.status(403))
        await session.toggle(.bookmark, on: item)
        #expect(session.said.lines == [Said(.act(.bookmark, row: item.id), .refused, host: Self.host, of: .by("Ada"))])
        #expect(session.rowRefusal?.key == "account.bookmarks.refused" && session.toast != nil, "beside them, not instead")
        #expect(try !mark(.bookmark, session).done)
    }

    // MARK: - A read meanwhile, and the source's later word

    @Test(
        "A read landing while the press is out does not undo it on screen; a read asked after the answer is the source's word, and wins",
        .timeLimit(.minutes(1)),
        arguments: [PostAct.boost, .favourite, .bookmark], [true, false]
    )
    func aReadMeanwhile(act: PostAct, on: Bool) async throws {
        let (session, server, home) = try await shell(!on)
        let item = try row(session)
        let out = await pressed(session, server) { await session.toggle(act, on: item) }
        defer { out.watchdog.cancel() }

        // The source has not been answered for yet, so this read says what it said before.
        await session.reload.timeline(home, in: session)
        #expect(Self.held(act, await session.store.all().first { $0.statusID == "9" }) == !on, "the premise: the read landed under the press")
        #expect(try mark(act, session).done == on, "a read landing meanwhile undid the press")
        #expect(try mark(act, session).count == Self.count(act, on))

        await out.gate.open()
        await out.press.value
        #expect(try mark(act, session).done == on)
        try await nothingDrawnTheStoreDoesNotHold(session)

        // Undone elsewhere, and a reload asked now: the source's word, and taken.
        await server.elsewhere(act, !on)
        await session.reload.timeline(home, in: session)
        #expect(try mark(act, session).done == !on, "the source's later word did not win")
        try await nothingDrawnTheStoreDoesNotHold(session)
    }

    // MARK: - A second press

    @Test("The last press wins: pressed again while the first is out, the mark turns at once and nothing is sent; at the answer the other request goes, or none where the answer is already what is wanted", .timeLimit(.minutes(1)))
    func theLastPressWins() async throws {
        // Boost, then take it back: two requests, in the order pressed, and it ends not boosted.
        let (session, server, _) = try await shell(false)
        let item = try row(session)
        let out = await pressed(session, server) { await session.toggle(.boost, on: item) }
        defer { out.watchdog.cancel() }
        await session.toggle(.boost, on: try row(session))
        #expect(await server.writes == ["boost true"], "never two on the wire")
        #expect(try !mark(.boost, session).done && mark(.boost, session).count == 2, "the second press did not turn the mark")
        #expect(try mark(.boost, session).spoken == "Boost")
        #expect(session.acts.standing(of: item.id, .boost) == .pressed(to: false))
        // Another mark's press is its own.
        let other = Task { await session.toggle(.favourite, on: item) }
        #expect(await spun { await server.writes == ["boost true", "favourite true"] })
        await out.gate.open()
        await out.press.value
        await other.value
        #expect(await server.writes == ["boost true", "favourite true", "boost false"])
        #expect(try !mark(.boost, session).done && mark(.favourite, session).done)
        #expect(session.acts.standings.isEmpty && session.said.lines.isEmpty)
        try await nothingDrawnTheStoreDoesNotHold(session)

        // Boost, take back, boost: any number of presses come to the last, and one request.
        let (again, thrice, _) = try await shell(false)
        let post = try row(again)
        let held = await pressed(again, thrice) { await again.toggle(.boost, on: post) }
        defer { held.watchdog.cancel() }
        await again.toggle(.boost, on: post)
        await again.toggle(.boost, on: post)
        #expect(try mark(.boost, again).done)
        await held.gate.open()
        await held.press.value
        #expect(await thrice.writes == ["boost true"], "the answer was already what is wanted")
        #expect(try mark(.boost, again).done)
        try await nothingDrawnTheStoreDoesNotHold(again)
    }

    @Test("The second of two presses failing puts the mark to what the source last said — the first, which landed — and says one line", .timeLimit(.minutes(1)))
    func theSecondOfTwoFails() async throws {
        let (session, server, _) = try await shell(false)
        let item = try row(session)
        let out = await pressed(session, server) { await session.toggle(.boost, on: item) }
        defer { out.watchdog.cancel() }
        await server.answers(.unreachable)
        await session.toggle(.boost, on: item)
        #expect(try !mark(.boost, session).done)

        await out.gate.open()
        await out.press.value
        #expect(await server.writes == ["boost true", "boost false"])
        let back = try mark(.boost, session)
        #expect(back.done && back.count == 3, "the source last said it is boosted")
        #expect(session.acts.standing(of: item.id, .boost) == .failed)
        #expect(session.said.lines == [Said(.act(.boost, row: item.id), .unreachable, host: Self.host, of: .by("Ada"))])
        try await nothingDrawnTheStoreDoesNotHold(session)
    }

    @Test("A press made while the source's answer is being adopted is not lost: it is asked for, and the mark ends as pressed", .timeLimit(.minutes(1)))
    func aPressWhileTheAnswerIsAdopted() async throws {
        let (session, server, _) = try await shell(false)
        let item = try row(session)
        let out = await pressed(session, server) { await session.toggle(.boost, on: item) }
        defer { out.watchdog.cancel() }
        // The adopt of the answer is held in flight, and the press is made then.
        let hold = Gate()
        let holdGuard = hangGuard(hold)
        defer { holdGuard.cancel() }
        var adopting = 0
        session.adopting = {
            adopting += 1
            await hold.wait()
        }
        await out.gate.open()
        #expect(await spun { adopting == 1 }, "the answer is being adopted")
        #expect(await session.store.all().first { $0.statusID == "9" }?.boosted == true, "the premise: the answer has landed")
        await session.toggle(.boost, on: item)
        #expect(await server.writes == ["boost true"], "nothing is sent while one is out")
        await hold.open()
        await out.press.value
        #expect(await server.writes == ["boost true", "boost false"], "the late press was dropped")
        #expect(try !mark(.boost, session).done, "the mark snapped back to what was not last pressed")
        #expect(session.acts.standings.isEmpty && session.said.lines.isEmpty)
        try await nothingDrawnTheStoreDoesNotHold(session)
    }

    /// One adopt held in flight, and let go from the main actor with no hop in between.
    @MainActor
    private final class Held {
        var entered = 0
        private var waiting: CheckedContinuation<Void, Never>?

        /// The first adopt to come waits here; every later one passes.
        func wait() async {
            entered += 1
            guard entered == 1 else { return }
            await withCheckedContinuation { waiting = $0 }
        }

        func letGo() {
            waiting?.resume()
            waiting = nil
        }
    }

    @Test("A taking back that fails while another adopt is settling an older failure keeps its standing and its line, and the post is back", .timeLimit(.minutes(1)))
    func aTakingBackFailsWhileAnAdoptIsInFlight() async throws {
        let (session, server, _) = try await shell(false, answering: .unreachable)
        let nine = try row(session), mine = try row(session, "1")
        // Another miss standing, for an adopt to be settling.
        await session.toggle(.favourite, on: nine)
        #expect(session.acts.standing(of: nine.id, .favourite) == .failed)
        let out = await pressed(session, server) { await session.withdraw(mine) }
        defer { out.watchdog.cancel() }
        #expect(!session.notes.contains { $0.key.rowID == mine.id })

        // An adopt in flight: it has assigned what is held, the post left out, and has the
        // older miss to settle…
        let held = Held()
        session.adopting = { await held.wait() }
        let inFlight = Task { _ = await session.setKept(true, on: nine) }
        #expect(await spun { held.entered == 1 })
        // …and it goes on at the very moment the taking back fails: the failure is said before
        // its own adopt has drawn the post again, and this adopt settles in between.
        session.said.announce = { _ in held.letGo() }
        await out.gate.open()
        await out.press.value
        await inFlight.value
        #expect(held.entered >= 2, "the premise: the failure's own adopt came after")

        #expect(session.acts.standing(of: mine.id, .withdraw) == .failed, "the failure was taken for the post having gone")
        #expect(session.said.lines.contains(Said(.act(.withdraw, row: mine.id), .unreachable, host: Self.host, of: .yours)), "the post came back with nothing said")
        #expect(session.notes.contains { $0.key.rowID == mine.id }, "the post is not back")
        #expect(session.acts.standing(of: nine.id, .favourite) == .failed)
    }

    @Test("An answer that says the mark did not move is not said where the person has since pressed back to that: the mark is what they last pressed", .timeLimit(.minutes(1)))
    func unmovedIsWhatWasLastPressed() async throws {
        let (session, server, _) = try await shell(false, answering: .unmoved)
        let item = try row(session)
        let out = await pressed(session, server) { await session.toggle(.boost, on: item) }
        defer { out.watchdog.cancel() }
        await session.toggle(.boost, on: item)
        await out.gate.open()
        await out.press.value
        #expect(await server.writes == ["boost true"], "the source's word is not asked a second time")
        #expect(try !mark(.boost, session).done)
        #expect(session.said.lines.isEmpty, "\"did not change\" was said of a mark that is as it was last pressed")
        #expect(session.acts.standings.isEmpty)
    }

    @Test("A failure is let go only by a read asked after it: pressed and pressed back, or the second of two failing and pressed back again, what was held all along proves nothing", .timeLimit(.minutes(1)))
    func aMissIsNotSettledByWhatWasHeld() async throws {
        // Pressed, pressed back, and the one request runs out of time: wanted is what is held.
        let (session, server, home) = try await shell(false, answering: .timedOut)
        let item = try row(session)
        let out = await pressed(session, server) { await session.toggle(.boost, on: item) }
        await session.toggle(.boost, on: item)
        await out.gate.open()
        await out.press.value
        out.watchdog.cancel()
        let line = Said(.act(.boost, row: item.id), .unconfirmed, host: Self.host, of: .by("Ada"))
        #expect(session.acts.standing(of: item.id, .boost) == .failed && session.said.lines == [line])
        // What is held is read again, with nothing asked of the source: a post lands beside it.
        await session.setKept(true, on: try row(session, "1"))
        await session.reloadFromStore()
        #expect(session.acts.standing(of: item.id, .boost) == .failed, "notes read again took a held mark for a read of the post")
        #expect(session.said.lines == [line])
        // The write had landed after all, and a read asked now says so — not what was wanted.
        await server.elsewhere(.boost, true)
        await session.reload.timeline(home, in: session)
        #expect(session.acts.standing(of: item.id, .boost) == .failed && session.said.lines == [line])

        // The first landed, the second failed, and by then it was pressed back to the first.
        let (other, second, _) = try await shell(false)
        let post = try row(other)
        let held = await pressed(other, second) { await other.toggle(.boost, on: post) }
        await other.toggle(.boost, on: post)
        // Two requests go: the first is answered, the second is held too and then fails.
        let again = Gate()
        let guardTask = hangGuard(again)
        defer { guardTask.cancel() }
        await second.answers(.unreachable)
        await second.hold(again)
        await held.gate.open()
        #expect(await spun { await second.writes == ["boost true", "boost false"] })
        await other.toggle(.boost, on: post)
        #expect(other.acts.standing(of: post.id, .boost) == .pressed(to: true))
        await again.open()
        await held.press.value
        held.watchdog.cancel()
        // Boosted is what the source last said and what was last pressed; the failure stands.
        #expect(other.acts.standing(of: post.id, .boost) == .failed, "the adopt after the failure took the first answer for a later read")
        #expect(other.said.lines == [Said(.act(.boost, row: post.id), .unreachable, host: Self.host, of: .by("Ada"))], "a line with no standing behind it, or none")
        #expect(try mark(.boost, other).done)
    }

    // MARK: - A sign-in that is not there any more

    @Test("A source that ends the sign-in on a write is said once, by the notice that says a sign-in ended: no line outlives its source, and no standing", .timeLimit(.minutes(1)))
    func theSignInEnded() async throws {
        #expect(WriteWhy(MastodonAuthError.signedOut) == .refused, "a source that answered was said not to have been reached")
        let (session, server, _) = try await shell(false, answering: .ended)
        let item = try row(session)
        let out = await pressed(session, server) { await session.toggle(.boost, on: item) }
        #expect(try mark(.boost, session).done)
        await out.gate.open()
        await out.press.value
        out.watchdog.cancel()

        #expect(session.mastodon.ended == [Self.host], "what says a sign-in ended")
        #expect(session.said.lines.isEmpty, "a line was said about a source whose sign-in is gone")
        #expect(session.acts.standings.isEmpty)
        #expect(!session.acts(on: try row(session)).offers(.boost))
    }

    @Test("A sign-out or a Clear while a press is out leaves no line and no standing, whatever the late answer", .timeLimit(.minutes(1)))
    func signedOutOrClearedMeanwhile() async throws {
        for answer in [Answer.yes, .unreachable, .status(403), .unmoved] {
            for clears in [false, true] {
                let (session, server, _) = try await shell(false, answering: answer)
                let boosted = try row(session), mine = try row(session, "1")
                // One that had failed before, standing with its line.
                await server.answers(.unreachable)
                await session.toggle(.favourite, on: boosted)
                #expect(session.said.lines.count == 1 && session.acts.standing(of: boosted.id, .favourite) == .failed)
                await server.answers(answer)
                let out = await pressed(session, server) { await session.toggle(.boost, on: boosted) }
                let taking = Task { await session.withdraw(mine) }
                #expect(await spun { await server.writes.count == 3 })

                if clears { await session.clear(host: Self.host) } else { await session.signOut(host: Self.host) }
                #expect(session.acts.standings.isEmpty && session.acts.leaving.isEmpty, "\(answer), clear \(clears): a standing outlived the sign-in")
                #expect(session.said.lines.isEmpty)

                await out.gate.open()
                await out.press.value
                await taking.value
                out.watchdog.cancel()
                #expect(session.acts.standings.isEmpty && session.acts.leaving.isEmpty, "\(answer), clear \(clears): the late answer left a standing")
                #expect(session.said.lines.isEmpty, "\(answer), clear \(clears): the late answer said a line about a source no longer signed in to")
                let stored = await session.store.all()
                #expect(Set(session.notes.map(\.key)) == Set(stored.map(\.key)))
            }
        }
    }

    // MARK: - A failure that had landed after all

    @Test("A read that lands after a failure and shows the mark as the press wanted lets the failure go, and its line", .timeLimit(.minutes(1)))
    func aMissThatLanded() async throws {
        let (session, server, home) = try await shell(false, answering: .timedOut)
        let item = try row(session)
        await session.toggle(.boost, on: item)
        #expect(session.acts.standing(of: item.id, .boost) == .failed && session.said.lines.count == 1)
        // A read that says what it said before changes nothing: it still did not arrive.
        await session.reload.timeline(home, in: session)
        #expect(session.acts.standing(of: item.id, .boost) == .failed && session.said.lines.count == 1)

        await server.elsewhere(.boost, true)
        await session.reload.timeline(home, in: session)
        #expect(session.acts.standings.isEmpty, "\"did not arrive\" stands beside a mark the source says is set")
        #expect(session.said.lines.isEmpty)
        let now = try mark(.boost, session)
        #expect(now.done && now.spoken == "Take the boost back" && now.glyph == "arrow.2.squarepath")
    }

    // MARK: - The line

    @Test("A line names whose post it was — by name made fit for a line, or as the person's own — in every language")
    func theLineNamesThePost() {
        let row = NoteKey(host: Self.host, id: "a").rowID
        func words(_ act: PostAct, _ why: WriteWhy, _ whose: Said.Whose, _ language: DummyLanguage) -> String {
            Said(.act(act, row: row), why, host: Self.host, of: whose).words(language: language)
        }
        #expect(words(.favourite, .unreachable, .by("Ada\nLovelace"), .english)
            == "social.example could not be reached, so the favourite on Ada Lovelace's post did not change. It is as it was.")
        #expect(words(.bookmark, .refused, .by("Ada"), .english)
            == "social.example would not let this sign-in change the bookmark on Ada's post. It is as it was.")
        #expect(words(.withdraw, .declined, .yours, .english) == "social.example did not take your post back. It is still here.")
        #expect(words(.boost, .unreachable, .by("Ada"), .taiwanese) == "轉發 Ada 的貼文：連不上 social.example，沒有變動。它和原來一樣。")
        #expect(words(.favourite, .unconfirmed, .yours, .taiwanese) == "收藏你的貼文：social.example 沒有確認已變動。重新載入看看。")
        #expect(words(.bookmark, .declined, .by("Ada"), .taiwanese) == "為 Ada 的貼文加書籤：social.example 沒有變動。它和原來一樣。")
        #expect(words(.withdraw, .refused, .yours, .taiwanese) == "收回你的貼文：social.example 不讓這個登入收回。它還在這裡。")
        for language in [DummyLanguage.english, .taiwanese] {
            for act in [PostAct.boost, .favourite, .bookmark, .withdraw] {
                for why in [WriteWhy.refused, .unreachable, .declined, .unconfirmed] {
                    let said = words(act, why, .by("Ada"), language)
                    #expect(!said.contains("said.") && said.contains("Ada") && said.contains(Self.host), "\(act) \(why) in \(language): \(said)")
                }
            }
        }
    }

    @Test("More than three lines about one act at one source are drawn as one that says how many, and taking it down takes them all; three are drawn each")
    func aBurstFolds() {
        let said = ShellSaid()
        said.announce = { _ in }
        func boost(_ id: Int, _ host: String = Self.host) -> Said {
            Said(.act(.boost, row: NoteKey(host: host, id: "\(id)").rowID), .unreachable, host: host, of: .by("Ada"))
        }
        let star = Said(.act(.favourite, row: NoteKey(host: Self.host, id: "1").rowID), .refused, host: Self.host, of: .by("Ada"))
        for id in 1...3 { said.say(boost(id)) }
        #expect(said.folded == said.lines, "three are each drawn")
        said.say(star)
        said.say(boost(9, "other.example"))
        said.say(boost(4))
        let folded = said.folded
        #expect(folded.map(\.id) == [Said.foldID(.boost, host: Self.host), boost(9, "other.example").id, star.id])
        #expect(folded[0].many == 4)
        #expect(folded[0].words(language: .english) == "4 boosts at social.example did not go through. Reload to see where each stands.")
        #expect(folded[0].words(language: .taiwanese) == "social.example 上有 4 個轉發沒有完成。重新載入看看各自的狀況。")
        for language in [DummyLanguage.english, .taiwanese] {
            for act in PostAct.allCases {
                #expect(L10n.t("said.act.\(act).many", language: language) != "said.act.\(act).many")
            }
        }
        said.takeDown(folded[0].id)
        #expect(said.lines == [boost(9, "other.example"), star])
    }

    @Test("The list behind the strip's count is not opened while the root has a sheet or a question up")
    func theListWaitsForTheRoot() async throws {
        let (session, _, _) = try await shell()
        #expect(!session.raisesOverPages && SaidStrip.opensAll(held: session.raisesOverPages))
        #expect(session.askToWithdraw(try row(session, "1")))
        #expect(session.raisesOverPages && !SaidStrip.opensAll(held: session.raisesOverPages))
        session.cancelWithdraw()
        #expect(!session.raisesOverPages)
    }

    // MARK: - Taking a post back

    @Test("At the question's yes the post leaves every list, over a store that still holds it; the source's yes lets it go, and its write is waited for before the press is done", .timeLimit(.minutes(1)))
    func takenBackLeavesAtTheYes() async throws {
        let (session, server, home) = try await shell()
        let mine = try row(session, "1")
        var writtenWhileOut: [Bool] = []
        session.persist = { writtenWhileOut.append(session.acts.leaving.contains(mine.id)) }
        #expect(session.askToWithdraw(mine))
        let out = await pressed(session, server) { await session.withdraw(mine) }
        defer { out.watchdog.cancel() }

        #expect(session.withdrawing == nil)
        #expect(session.acts.leaving == [mine.id])
        #expect(session.acting(on: mine).standings[.withdraw] == .pressed(to: true), "what keeps its menu from offering it again")
        #expect(session.notes.map(\.statusID) == ["9"], "the row waited for the source")
        #expect(session.timelineItems(latest: nil).map(\.statusID) == ["9"])
        #expect(session.held(mine.id) == nil)
        #expect(await session.store.all().count == 2, "nothing goes from the store before the source says so")
        #expect(!session.askToWithdraw(mine) && !session.withdrawAsked(mine), "asked twice")
        // A read landing meanwhile brings the post again, and it is still not drawn.
        await session.reload.timeline(home, in: session)
        #expect(session.notes.map(\.statusID) == ["9"], "a read landing meanwhile drew it again")
        #expect(writtenWhileOut.isEmpty)

        await out.gate.open()
        await out.press.value
        #expect(writtenWhileOut == [true], "it is off the disk before anything says it went (#292)")
        #expect(session.notes.map(\.statusID) == ["9"])
        #expect(await session.store.all().map(\.statusID) == ["9"])
        #expect(session.acts.standings.isEmpty && session.said.lines.isEmpty)
        try await nothingDrawnTheStoreDoesNotHold(session)
    }

    @Test("A taking back that does not arrive draws the post again where it was and says why", .timeLimit(.minutes(1)))
    func takenBackComesBack() async throws {
        let cases: [(Answer, WriteWhy, String)] = [
            (.status(403), .refused, "social.example would not let this sign-in take your post back. It is still here."),
            (.unreachable, .unreachable, "social.example could not be reached, so your post was not taken back. It is still here."),
            (.timedOut, .unconfirmed, "social.example did not confirm your post was taken back. Reload to see."),
        ]
        for (answer, why, words) in cases {
            let (session, server, _) = try await shell(answering: answer)
            let before = session.notes
            let drawn = session.timelineItems(latest: nil).map(\.id)
            let mine = try row(session, "1")
            var saved = 0
            session.persist = { saved += 1 }
            let out = await pressed(session, server) { await session.withdraw(mine) }
            #expect(!session.notes.contains { $0.key.rowID == mine.id })

            await out.gate.open()
            await out.press.value
            out.watchdog.cancel()

            #expect(session.notes == before, "\(why): the post is not back where it was")
            #expect(session.timelineItems(latest: nil).map(\.id) == drawn)
            #expect(session.acts.standing(of: mine.id, .withdraw) == .failed)
            #expect(session.said.lines == [Said(.act(.withdraw, row: mine.id), why, host: Self.host, of: .yours)])
            #expect(session.said.lines.first?.words(language: .english) == words)
            #expect(saved == 0, "nothing went, so nothing is written")
            try await nothingDrawnTheStoreDoesNotHold(session)
        }
    }

    @Test("A row taken back leaves an open conversation at the yes, and is drawn there again where it was when the source does not take it", .timeLimit(.minutes(1)))
    func takenBackInAnOpenConversation() async throws {
        let host = "one.example"
        func status(_ id: String) -> String {
            """
            {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)","in_reply_to_id":"9",
             "created_at":"2024-01-01T00:00:00.000Z","content":"<p>answer \(id)</p>",
             "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
            """
        }
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
            scopes: MastodonOAuth.scopes(writing: true)
        ))
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = ActServer([
            "/api/v1/accounts/verify_credentials": .json(#"{"acct":"ada"}"#),
            "/api/v1/statuses/11": .fail,
            "/api/v1/statuses/9/context": .json(#"{"ancestors":[],"descendants":[\#(status("10")),\#(status("11"))]}"#),
        ], holding: "/api/v1/statuses/11", gate: gate)
        let source = Source(host: host, kind: .mastodon)
        let root = Note(
            id: "https://\(host)/users/bo/statuses/9", source: source, author: "Bo", handle: "@bo@\(host)",
            body: "the post", postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public], statusID: "9"
        )
        let http = FixtureHTTP()
        let session = ShellSession(
            http: http, store: ItemStore(sources: [source], notes: [root]),
            mastodon: MastodonSessions(tokens: tokens, sender: server), posts: ForumPosts(http: http)
        )
        session.said.announce = { _ in }
        session.mastodon.refresh()
        await session.mastodon.verifyAll()
        await session.reloadFromStore()
        let item = DummyItem(root)
        await session.reload.opened(item, in: session)
        func answers() -> [String?] {
            session.conversations.conversation(around: item).descendants.map(\.item.statusID)
        }
        #expect(answers() == ["10", "11"], "the premise: the thread draws both answers")
        let mine = try #require(session.conversations.conversation(around: item).descendants.map(\.item).first { $0.statusID == "11" })

        let press = Task { await session.withdraw(mine) }
        #expect(await spun { await server.methods.contains("DELETE") }, "the request is on the wire")
        #expect(answers() == ["10"], "the answer waited for the source")

        await gate.open()
        await press.value
        #expect(answers() == ["10", "11"], "the answer is not back where it was")
        #expect(session.said.lines == [Said(.act(.withdraw, row: mine.id), .unreachable, host: host, of: .yours)])
    }

    @Test("Every copy a taking back leaves out is drawn again when it fails, when its source is cleared, and at a Clear of everything")
    func leavingIsLetGoOf() {
        let acts = ShellActs()
        let here = NoteKey(host: Self.host, id: "a").rowID
        let copy = NoteKey(host: "other.example", id: "a").rowID
        #expect(acts.begin(here, .withdraw, taking: [here, copy]))
        #expect(acts.leaving == [here, copy] && acts.isOnItsWay(here, .withdraw))
        #expect(!acts.begin(here, .withdraw, taking: [here, copy]), "one already out")
        acts.failed(here, .withdraw)
        #expect(acts.leaving.isEmpty && acts.standing(of: here, .withdraw) == .failed)

        #expect(acts.begin(here, .withdraw, taking: [here, copy]))
        acts.forget(host: Self.host)
        #expect(acts.leaving.isEmpty && acts.standings.isEmpty)

        #expect(acts.begin(here, .withdraw, taking: [here]))
        acts.landed(here, .withdraw)
        #expect(acts.leaving.isEmpty)
        #expect(acts.begin(here, .withdraw, taking: [here]))
        acts.clear()
        #expect(acts.leaving.isEmpty && acts.standings.isEmpty)
    }
}
