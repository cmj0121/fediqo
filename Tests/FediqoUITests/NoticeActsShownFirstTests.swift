import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #323, shown first — the four acts on notices from the person's yes to the source's answer,
/// on stub doors each held at a gate: what leaves what is drawn at the yes, what a refusal, a
/// failure and a request out of time bring back and say, and what a read, a sign-out, a Clear
/// or a second act does in between.
///
/// **No clock is waited for.** A request out of time is the stub failing as the door does.
/// Every interleaving is pinned by a gate the test opens, and the guard each one turns on is
/// named in its test.
@MainActor
@Suite("Acting on notices, shown first: the yes, and what the source's answer then does")
struct NoticeActsShownFirstTests {
    private typealias F = NoticeActFixture
    private static let a = F.a
    private static let b = F.b
    private static let policy = "/api/v2/notifications/policy"
    private static let requests = "/api/v1/notifications/requests"
    private static let dismiss4 = F.post(F.a, "/api/v1/notifications/4/dismiss")
    private static let dismiss3 = F.post(F.a, "/api/v1/notifications/3/dismiss")
    private static let clear = F.post(F.a, "/api/v1/notifications/clear")

    private func ids(_ notices: [Notice]) -> [String] {
        notices.map { "\($0.source.host.prefix(1))\($0.newestID)" }
    }

    private static let top = F.page(F.one(4, by: "Ada", minutes: 2), F.one(3, "follow", by: "Bo", minutes: 9))

    /// Two sources read to their ends: `a` acts, `b` only reads; `a` holds two people's
    /// notices back, its held-back line opened.
    private func two(
        _ extra: [String: NoticeActServer.Outcome] = [:]
    ) async throws -> (ShellSession, NoticeActServer, MemoryMastodonTokens) {
        var routes: [String: NoticeActServer.Outcome] = [
            F.get(Self.a): Self.top,
            F.get(Self.b): F.page(F.one(8, "mention", by: "Cy", minutes: 5)),
            F.get(Self.a, Self.policy): F.policy(requests: 2, notices: 4),
            F.get(Self.a, Self.requests): .body("[" + F.request(71, by: "Eve", count: 3) + "," + F.request(72, by: "Flo", count: 1) + "]"),
        ]
        routes.merge(extra) { _, new in new }
        let shell = try await F.shell(routes, signedIn: [Self.a: F.acts, Self.b: F.reads])
        let list = shell.0.noticeList
        await list.read(in: shell.0)
        await list.readOn(in: shell.0)
        await list.readOn(in: shell.0)
        await list.acts.look(in: shell.0)
        await list.acts.open(host: Self.a, in: shell.0)
        #expect(ids(list.lines) == ["a4", "b8", "a3"])
        return shell
    }

    private func line(_ id: String, in session: ShellSession) throws -> Notice {
        try #require(session.noticeList.reaches.values.flatMap(\.notices).first {
            "\($0.source.host.prefix(1))\($0.newestID)" == id
        })
    }

    private func strip(_ session: ShellSession) -> [String] {
        session.said.lines.map { $0.words(language: .english) }
    }

    /// Counts what the strip says aloud.
    @MainActor
    private final class Heard {
        var lines: [String] = []
    }

    private func hearing(_ session: ShellSession) -> Heard {
        let heard = Heard()
        session.said.announce = { heard.lines.append($0) }
        return heard
    }

    /// One of the four acts, with the request it makes and what it is on the wire under.
    enum Act: String, CaseIterable, Sendable {
        case dismiss, dismissAll, letThrough, letGo

        var act: ShellNoticeActs.Act {
            switch self {
            case .dismiss: .dismiss
            case .dismissAll: .dismissAll
            case .letThrough: .letThrough
            case .letGo: .letGo
            }
        }

        /// The request it makes of `a.example`.
        var path: String {
            switch self {
            case .dismiss: "POST a.example/api/v1/notifications/4/dismiss"
            case .dismissAll: "POST a.example/api/v1/notifications/clear"
            case .letThrough: "POST a.example/api/v1/notifications/requests/71/accept"
            case .letGo: "POST a.example/api/v1/notifications/requests/71/dismiss"
            }
        }
    }

    private func start(_ act: Act, in session: ShellSession) throws -> Task<Void, Never> {
        let acts = session.noticeList.acts
        switch act {
        case .dismiss:
            let notice = try line("a4", in: session)
            return Task { await acts.dismiss(notice, in: session) }
        case .dismissAll:
            return Task { await acts.dismissAll(host: Self.a, in: session) }
        case .letThrough, .letGo:
            let eve = try #require(acts.requests[Self.a]?.first)
            return Task { act == .letThrough ? await acts.letThrough(eve, in: session) : await acts.letGo(eve, in: session) }
        }
    }

    /// What the page draws while `act` is out.
    private func expectGone(_ act: Act, in session: ShellSession) {
        let list = session.noticeList, acts = list.acts
        switch act {
        case .dismiss: #expect(ids(list.lines) == ["b8", "a3"], "\(act)")
        case .dismissAll: #expect(ids(list.lines) == ["b8"], "\(act)")
        case .letThrough, .letGo:
            #expect(acts.listed(host: Self.a).map(\.requestID) == ["72"], "\(act)")
            #expect(acts.shownHeld(host: Self.a) == NoticesHeld(requests: 1, notices: 1), "\(act)")
            #expect(acts.onItsWay.isEmpty, "\(act): said to be on its way before the source said yes")
        }
        // Nothing held has moved.
        #expect(ids(list.reaches[Self.a]?.notices ?? []) == ["a4", "a3"], "\(act)")
        #expect(acts.requests[Self.a]?.map(\.requestID) == ["71", "72"], "\(act)")
        #expect(acts.held(host: Self.a) == NoticesHeld(requests: 2, notices: 4), "\(act)")
    }

    /// Everything drawn as it was before the yes, each in its place.
    private func expectBack(in session: ShellSession, _ note: String) {
        let list = session.noticeList, acts = list.acts
        #expect(ids(list.lines) == ["a4", "b8", "a3"], "\(note)")
        #expect(acts.listed(host: Self.a).map(\.requestID) == ["71", "72"], "\(note)")
        #expect(acts.shownHeld(host: Self.a) == NoticesHeld(requests: 2, notices: 4), "\(note)")
        #expect(acts.shownHolders == [Self.a] && acts.opened == [Self.a], "\(note)")
        #expect(acts.onItsWay.isEmpty && acts.acting.isEmpty, "\(note)")
    }

    // MARK: - The yes, and each answer

    @Test("Each act leaves what is drawn at the yes, before its source answers, and what is held only on the source's yes",
          arguments: Act.allCases)
    func leavesAtTheYes(_ act: Act) async throws {
        let gate = Gate()
        let (session, server, _) = try await two([act.path: .held(gate, "{}")])
        let heard = hearing(session)
        let list = session.noticeList, acts = list.acts
        let eve = try #require(acts.requests[Self.a]?.first)

        let task = try start(act, in: session)
        #expect(await spun { await server.count(act.path) == 1 })
        expectGone(act, in: session)
        #expect(acts.acting.count == 1)

        await gate.open()
        await task.value
        #expect(acts.acting.isEmpty && session.said.lines.isEmpty && heard.lines.isEmpty)
        #expect(await server.posts == [act.path])
        switch act {
        case .dismiss:
            #expect(ids(list.lines) == ["b8", "a3"] && ids(list.reaches[Self.a]?.notices ?? []) == ["a3"])
        case .dismissAll:
            #expect(ids(list.lines) == ["b8"] && list.reaches[Self.a]?.notices.isEmpty == true)
        case .letThrough, .letGo:
            #expect(acts.requests[Self.a]?.map(\.requestID) == ["72"])
            #expect(acts.held(host: Self.a) == NoticesHeld(requests: 1, notices: 1))
            #expect(acts.shownHeld(host: Self.a) == acts.held(host: Self.a))
            #expect(acts.onItsWay == (act == .letThrough ? [eve] : []))
        }
    }

    /// A way a request comes to nothing, as the stub answers it once its gate opens.
    enum Cause: String, CaseIterable, Sendable {
        case refused, declined, unreachable, unconfirmed

        var why: WriteWhy {
            switch self {
            case .refused: .refused
            case .declined: .declined
            case .unreachable: .unreachable
            case .unconfirmed: .unconfirmed
            }
        }

        func outcome(_ gate: Gate) -> NoticeActServer.Outcome {
            switch self {
            case .refused: .held(gate, "{}", 403)
            case .declined: .held(gate, "{}", 503)
            case .unreachable: .fails(gate, .notConnectedToInternet)
            case .unconfirmed: .fails(gate, .timedOut)
            }
        }
    }

    @Test("A refusal, a failure, no answer at all and a request out of time each draw it again where it was, and say the cause once, on the strip and aloud",
          arguments: Act.allCases, Cause.allCases)
    func everyFailureBringsItBack(_ act: Act, _ cause: Cause) async throws {
        let gate = Gate()
        let (session, server, _) = try await two([act.path: cause.outcome(gate)])
        let heard = hearing(session)

        let task = try start(act, in: session)
        #expect(await spun { await server.count(act.path) == 1 })
        expectGone(act, in: session)
        #expect(session.said.lines.isEmpty, "said before the source answered")

        await gate.open()
        await task.value
        expectBack(in: session, "\(act) \(cause)")
        // The sentence the act and the cause have, and which notice or whose it was about.
        let words = NoticeActs.words(.init(act: act.act, why: cause.why), host: Self.a, language: .english)
        #expect(session.said.lines.map(\.what) == [.notice(act.act)] && session.said.lines.map(\.why) == [cause.why])
        let which: String
        switch act {
        case .dismiss: which = " The notice: Ada favourited your post."
        case .dismissAll: which = ""
        case .letThrough, .letGo: which = " From: @eve@a.example (Eve)."
        }
        #expect(strip(session) == [words + which] && !words.contains("notices.act."))
        #expect(session.said.lines.first?.many == 1)
        #expect(heard.lines.count == 1, "the line coming back was not said aloud once")
        #expect(session.noticeList.acts.said.isEmpty && NoticesPane.said(in: session).isEmpty, "said above the list as well")
        #expect(session.mastodon.dismisses(host: Self.a))
    }

    @Test("A sign-in replaced while an act is out, with nobody told: the answer changes nothing and says nothing, and what was hidden is drawn again",
          arguments: Act.allCases, [200, 403])
    func aReplacedSignInDrawsItAgain(_ act: Act, _ status: Int) async throws {
        let gate = Gate()
        let (session, server, tokens) = try await two([act.path: .held(gate, "{}", status)])
        let heard = hearing(session)
        let task = try start(act, in: session)
        #expect(await spun { await server.count(act.path) == 1 })
        try tokens.save(F.token(Self.a, scopes: F.acts, access: "tok-other"))

        await gate.open()
        await task.value
        expectBack(in: session, "\(act) \(status)")
        #expect(ids(session.noticeList.reaches[Self.a]?.notices ?? []) == ["a4", "a3"])
        #expect(session.said.lines.isEmpty && heard.lines.isEmpty)
    }

    // MARK: - A read meanwhile

    @Test("A read landing while a dismissal is out changes what is held underneath and draws nothing hidden; the answer then settles it")
    func aReadLandsMeanwhile() async throws {
        for status in [200, 503] {
            let gate = Gate()
            let (session, server, _) = try await two([Self.dismiss4: .held(gate, "{}", status)])
            let list = session.noticeList
            let task = try start(.dismiss, in: session)
            #expect(await spun { await server.count(Self.dismiss4) == 1 })

            // The source still names the line, and one newer.
            await server.set(F.get(Self.a), F.page(
                F.one(5, by: "Di", minutes: 1), F.one(4, by: "Ada", minutes: 2), F.one(3, "follow", by: "Bo", minutes: 9)
            ))
            await list.read(in: session)
            #expect(ids(list.lines) == ["a5", "b8", "a3"], "\(status): a read drew a line that is on its way out")
            #expect(ids(list.reaches[Self.a]?.notices ?? []) == ["a5", "a4", "a3"])

            await gate.open()
            await task.value
            #expect(ids(list.lines) == (status == 200 ? ["a5", "b8", "a3"] : ["a5", "a4", "b8", "a3"]), "\(status)")
            #expect(session.said.lines.count == (status == 200 ? 0 : 1))
        }
    }

    /// Pins the strike by moment (`ShellNoticeList.undismissed`): a read sent after the yes
    /// and before the answer is one today's "on the wire at the answer" would also catch —
    /// and one that lands after the answer must not bring the line back either way.
    @Test("A read sent between the yes and the source's answer, landing after it and still naming the line, does not bring it back")
    func aReadSentBeforeTheAnswerIsOutrun() async throws {
        let answer = Gate(), reading = Gate()
        let (session, server, _) = try await two([Self.dismiss4: .held(answer, "{}")])
        let list = session.noticeList
        let task = try start(.dismiss, in: session)
        #expect(await spun { await server.count(Self.dismiss4) == 1 })

        await server.set(F.get(Self.a), .held(reading, "[" + [F.one(4, by: "Ada", minutes: 2), F.one(3, "follow", by: "Bo", minutes: 9)].joined(separator: ",") + "]"))
        let asked = await server.count(F.get(Self.a))
        let read = Task { await list.read(in: session) }
        #expect(await spun { await server.count(F.get(Self.a)) == asked + 1 })

        await answer.open()
        await task.value
        #expect(ids(list.lines) == ["b8", "a3"])
        await reading.open()
        await read.value
        #expect(ids(list.lines) == ["b8", "a3"], "a line its source dismissed came back with a read sent before the answer")
        #expect(ids(list.reaches[Self.a]?.notices ?? []) == ["a3"])
    }

    /// Pins `ShellNoticeList.outrun`, both ways: a stretch sent before the source emptied is
    /// not taken, and one sent after lets go of the mark.
    @Test("A read sent before its source dismissed everything, landing after, brings none of its lines back; the next read is the source's word")
    func aReadOutrunByDismissingAll() async throws {
        let answer = Gate(), reading = Gate()
        let (session, server, _) = try await two([Self.clear: .held(answer, "{}")])
        let list = session.noticeList
        let task = try start(.dismissAll, in: session)
        #expect(await spun { await server.count(Self.clear) == 1 })

        await server.set(F.get(Self.a), .held(reading, "[" + [F.one(4, by: "Ada", minutes: 2), F.one(3, "follow", by: "Bo", minutes: 9)].joined(separator: ",") + "]"))
        let asked = await server.count(F.get(Self.a))
        let read = Task { await list.read(in: session) }
        #expect(await spun { await server.count(F.get(Self.a)) == asked + 1 })

        await answer.open()
        await task.value
        #expect(ids(list.lines) == ["b8"])
        await reading.open()
        await read.value
        #expect(ids(list.lines) == ["b8"] && list.reaches[Self.a]?.notices.isEmpty == true, "lines a source dismissed came back with a read sent before")

        await server.set(F.get(Self.a), F.page(F.one(5, by: "Di", minutes: 1)))
        await list.read(in: session)
        #expect(ids(list.lines).contains("a5"), "a source that emptied was never read again")
    }

    /// Pins `ShellNoticeList.left(of:)`: a read that fails puts back what its source held
    /// when it set out, and that is from before the dismissal.
    @Test("A read sent before a dismissal's answer that then fails puts back what the source held, less what it has dismissed since",
          arguments: [Act.dismiss, .dismissAll])
    func aFailedReadDoesNotPutItBack(_ act: Act) async throws {
        let answer = Gate(), reading = Gate()
        let (session, server, _) = try await two([act.path: .held(answer, "{}")])
        let list = session.noticeList
        let task = try start(act, in: session)
        #expect(await spun { await server.count(act.path) == 1 })
        await server.set(F.get(Self.a), .held(reading, "{}", 503))
        let asked = await server.count(F.get(Self.a))
        let read = Task { await list.read(in: session) }
        #expect(await spun { await server.count(F.get(Self.a)) == asked + 1 })

        await answer.open()
        await task.value
        await reading.open()
        await read.value
        #expect(list.standing(host: Self.a) == .failed(.unreachable))
        #expect(ids(list.reaches[Self.a]?.notices ?? []) == (act == .dismiss ? ["a3"] : []), "a failed read put back what its source had dismissed")
        #expect(ids(list.lines) == (act == .dismiss ? ["b8", "a3"] : ["b8"]))
    }

    /// Pins that a mark is weighed against when the stretch was sent, and let go of by a
    /// later one: without it a line the source names again would be struck for the run.
    @Test("The source's later word wins: a line it names again in a read sent after the dismissal is drawn")
    func aLaterReadNamingItAgainIsDrawn() async throws {
        let (session, _, _) = try await two([Self.dismiss4: .body("{}")])
        let list = session.noticeList
        try await start(.dismiss, in: session).value
        #expect(ids(list.lines) == ["b8", "a3"])

        // Asked after the answer, and it names the line: the source's word now.
        await list.read(in: session)
        #expect(ids(list.lines) == ["a4", "b8", "a3"], "a line stayed struck against a read sent after its dismissal")
    }

    @Test("A dismissal not confirmed in time draws the line again; the next read settles it, taking the line where the source no longer names it")
    func theNextReadSettlesWhatWasNotConfirmed() async throws {
        let (session, server, _) = try await two([Self.dismiss4: .fails(nil, .timedOut)])
        let list = session.noticeList
        try await start(.dismiss, in: session).value
        #expect(ids(list.lines) == ["a4", "b8", "a3"])
        #expect(session.said.lines.map(\.what) == [.notice(.dismiss)] && session.said.lines.map(\.why) == [.unconfirmed])

        // It had landed all the same.
        await server.set(F.get(Self.a), F.page(F.one(3, "follow", by: "Bo", minutes: 9)))
        await list.read(in: session)
        #expect(ids(list.lines) == ["b8", "a3"], "a line the source dismissed is still shown after a read")
        #expect(list.acts.acting.isEmpty)
    }

    /// Pins `held()` in `perform`: a failure is said only of what is still held.
    @Test("A dismissal that fails after a read has shown the line gone at its source says nothing: nothing is still here")
    func aFailureOfALineSinceGoneSaysNothing() async throws {
        let gate = Gate()
        let (session, server, _) = try await two([Self.dismiss4: .held(gate, "{}", 503)])
        let list = session.noticeList
        let heard = hearing(session)
        let task = try start(.dismiss, in: session)
        #expect(await spun { await server.count(Self.dismiss4) == 1 })
        await server.set(F.get(Self.a), F.page(F.one(3, "follow", by: "Bo", minutes: 9)))
        await list.read(in: session)
        #expect(ids(list.reaches[Self.a]?.notices ?? []) == ["a3"])

        await gate.open()
        await task.value
        #expect(ids(list.lines) == ["b8", "a3"])
        #expect(session.said.lines.isEmpty && heard.lines.isEmpty, "a line that is gone was said to be still here")
    }

    /// Pins `whole` in `ShellNoticeList.rebuild`: what is drawn is held still for a first
    /// stretch, and a line leaving and coming back must still do both.
    @Test("While another source's first stretch is on the wire, a dismissed line still leaves at the yes and is drawn again where it was on a failure")
    func aLineLeavesAndReturnsWhileTheListIsHeldStill() async throws {
        let first = Gate(), answer = Gate()
        let (session, server, tokens) = try await F.shell([
            F.get(Self.a): Self.top,
            F.get(Self.b): .held(first, "[" + F.one(8, "mention", by: "Cy", minutes: 5) + "]"),
            Self.dismiss4: .held(answer, "{}", 503),
        ], signedIn: [Self.a: F.acts, Self.b: F.plain])
        let list = session.noticeList
        await list.read(in: session)
        await list.readOn(in: session)
        #expect(ids(list.lines) == ["a4", "a3"])
        // b may now be read, and is on its first stretch.
        try tokens.save(F.token(Self.b, scopes: F.reads))
        session.mastodon.refresh()
        let read = Task { await list.read(in: session) }
        #expect(await spun { await server.count(F.get(Self.b)) == 1 && list.standing(host: Self.a) == .read })
        #expect(list.reaches[Self.b]?.isOnFirstStretch == true)

        let task = try start(.dismiss, in: session)
        #expect(await spun { await server.count(Self.dismiss4) == 1 })
        #expect(ids(list.lines) == ["a3"], "the line stayed drawn after the yes")
        await answer.open()
        await task.value
        #expect(ids(list.lines) == ["a4", "a3"], "the line did not come back")
        #expect(session.said.lines.count == 1)

        await first.open()
        await read.value
        #expect(ids(list.lines).prefix(2) == ["a4", "b8"])
    }

    // MARK: - Sign-out and Clear

    @Test("A sign-out or a Clear while an act is out: nothing stays hidden, and the answer still to come changes nothing and says nothing",
          arguments: Act.allCases, [false, true])
    func lettingGoOfTheSourceMidFlight(_ act: Act, _ clears: Bool) async throws {
        for cause in [Cause.declined, .unconfirmed] {
            let gate = Gate()
            let (session, server, _) = try await two([act.path: cause.outcome(gate)])
            let heard = hearing(session)
            let list = session.noticeList, acts = list.acts
            let task = try start(act, in: session)
            #expect(await spun { await server.count(act.path) == 1 })

            if clears { await session.clear(host: Self.a) } else { await session.signOut(host: Self.a) }
            #expect(acts.acting.isEmpty, "\(cause): an act stayed out to a source let go of")
            #expect(acts.hidden.isEmpty && ids(list.lines) == ["b8"])

            await gate.open()
            await task.value
            #expect(session.said.lines.isEmpty && heard.lines.isEmpty, "\(cause): a line about a source no longer there")
            #expect(acts.acting.isEmpty && acts.requests[Self.a] == nil && acts.onItsWay.isEmpty)
            #expect(ids(list.lines) == ["b8"])
        }
    }

    /// Pins the flight in `perform`: with the same token held again, the token cannot tell
    /// the first press's answer from the second's.
    @Test("An answer that comes back after a sign-out and a sign-in again finds an entry that is not its own: it does not end the later press, take its line or say anything")
    func aLateAnswerIsNotTheLaterPresss() async throws {
        let first = Gate(), second = Gate()
        let (session, server, tokens) = try await two([Self.dismiss4: .held(first, "{}")])
        let list = session.noticeList, acts = list.acts
        let early = try start(.dismiss, in: session)
        #expect(await spun { await server.count(Self.dismiss4) == 1 })

        await session.signOut(host: Self.a)
        try tokens.save(F.token(Self.a, scopes: F.acts))
        session.mastodon.refresh()
        await list.read(in: session)
        #expect(ids(list.reaches[Self.a]?.notices ?? []) == ["a4", "a3"])

        await server.set(Self.dismiss4, .held(second, "{}", 503))
        let late = try start(.dismiss, in: session)
        #expect(await spun { await server.count(Self.dismiss4) == 2 })
        let name = try line("a4", in: session).id

        await first.open()
        await early.value
        #expect(acts.acting == [name], "the first press's answer ended the second press")
        #expect(ids(list.reaches[Self.a]?.notices ?? []) == ["a4", "a3"], "the first press's yes took the line the second is about")
        #expect(!list.lines.contains { $0.id == name } && session.said.lines.isEmpty)

        await second.open()
        await late.value
        #expect(acts.acting.isEmpty && list.lines.contains { $0.id == name })
        #expect(session.said.lines.map(\.what) == [.notice(.dismiss)] && session.said.lines.map(\.why) == [.declined])
    }

    // MARK: - Two acts at once

    /// Pins `missed` in `perform`: a line on the strip is one an act a source, and only the
    /// same line landing takes it down.
    @Test("Two dismissals out at one source: each is hidden and settled by its own answer, and one landing does not take down what is said of the other")
    func twoDismissalsAtOnce() async throws {
        let four = Gate(), three = Gate()
        let (session, server, _) = try await two([
            Self.dismiss4: .held(four, "{}", 503), Self.dismiss3: .held(three, "{}"),
        ])
        let list = session.noticeList, acts = list.acts
        let a4 = try line("a4", in: session), a3 = try line("a3", in: session)
        let first = Task { await acts.dismiss(a4, in: session) }
        let second = Task { await acts.dismiss(a3, in: session) }
        #expect(await spun { await server.posts.count == 2 })
        #expect(ids(list.lines) == ["b8"] && acts.acting == [a4.id, a3.id])

        await four.open()
        await first.value
        #expect(ids(list.lines) == ["a4", "b8"] && acts.acting == [a3.id])
        #expect(strip(session) == ["a.example did not dismiss the notice. It is still here. The notice: Ada favourited your post."])

        await three.open()
        await second.value
        #expect(ids(list.lines) == ["a4", "b8"] && acts.acting.isEmpty)
        #expect(strip(session) == ["a.example did not dismiss the notice. It is still here. The notice: Ada favourited your post."], "another line's dismissal took down what was said of this one")

        // The same line landing takes it down.
        await server.set(Self.dismiss4, .body("{}"))
        await acts.dismiss(a4, in: session)
        #expect(ids(list.lines) == ["b8"] && session.said.lines.isEmpty)
    }

    /// Pins that the strip's line stands for every name that failed (`missed`), not the last.
    @Test("Two dismissals that fail at one source are one line saying how many; when one of them later lands the line stands for the other and names it, and goes when that one lands too",
          arguments: [DummyLanguage.english, .taiwanese])
    func aLineStandsForEveryFailure(_ language: DummyLanguage) async throws {
        let (session, server, _) = try await two([Self.dismiss4: .status(503), Self.dismiss3: .status(403)])
        let heard = hearing(session)
        let list = session.noticeList, acts = list.acts
        let a4 = try line("a4", in: session), a3 = try line("a3", in: session)
        func said() -> [String] { session.said.lines.map { $0.words(language: language) } }
        let english = language == .english

        await acts.dismiss(a4, in: session)
        #expect(session.said.lines.map(\.about) == [.notice(a4)])
        #expect(said() == [english
            ? "a.example did not dismiss the notice. It is still here. The notice: Ada favourited your post."
            : "a.example 沒有移除這則通知。它還在這裡。通知：\(NoticeWords.act(a4, language: language))。"])
        await acts.dismiss(a3, in: session)
        #expect(session.said.lines.map(\.many) == [2] && session.said.lines.first?.about == nil)
        #expect(said() == [english
            ? "2 notices on a.example were not dismissed. Read again to see where each stands."
            : "a.example 上有 2 則通知沒有移除。再讀取一次看看各自的狀況。"])
        #expect(heard.lines.count == 2)

        // The second is asked again and lands: the first is still back in the list, and said.
        await server.set(Self.dismiss3, .body("{}"))
        await acts.dismiss(a3, in: session)
        #expect(ids(list.lines) == ["a4", "b8"])
        #expect(session.said.lines.map(\.about) == [.notice(a4)] && session.said.lines.map(\.why) == [.refused], "a line that failed was left with nothing said of it")
        #expect(said().first?.contains(NoticeWords.act(a4, language: language)) == true)
        #expect(heard.lines.count == 2, "a line that only counts fewer was said aloud again")

        await server.set(Self.dismiss4, .body("{}"))
        await acts.dismiss(a4, in: session)
        #expect(ids(list.lines) == ["b8"] && session.said.lines.isEmpty)
    }

    @Test("A line said not to have been dismissed that a read then shows gone is no longer said; one the read still names is")
    func aReadTakesDownWhatItShowsGone() async throws {
        let (session, server, _) = try await two([Self.dismiss4: .status(503), Self.dismiss3: .status(503)])
        let list = session.noticeList, acts = list.acts
        await acts.dismiss(try line("a4", in: session), in: session)
        await acts.dismiss(try line("a3", in: session), in: session)
        #expect(session.said.lines.map(\.many) == [2])

        // Still both there: nothing has said either went.
        await list.read(in: session)
        #expect(session.said.lines.map(\.many) == [2])
        // The source no longer names one.
        await server.set(F.get(Self.a), F.page(F.one(3, "follow", by: "Bo", minutes: 9)))
        await list.read(in: session)
        #expect(session.said.lines.map(\.many) == [1])
        // The one left, as it was when its dismissal failed.
        guard case .notice(let left)? = session.said.lines.first?.about else {
            Issue.record("the line left names no notice")
            return
        }
        #expect(left.newestID == "3")
        await server.set(F.get(Self.a), F.page())
        await list.read(in: session)
        #expect(session.said.lines.isEmpty)
    }

    @Test("Two requests that were not let go are one line saying how many; a reading that no longer lists one leaves the other, named")
    func requestsAreCountedToo() async throws {
        let (session, server, _) = try await two([
            F.post(Self.a, Self.requests + "/71/dismiss"): .status(503), F.post(Self.a, Self.requests + "/72/dismiss"): .status(503),
        ])
        let acts = session.noticeList.acts
        let listed = try #require(acts.requests[Self.a])
        await acts.letGo(listed[0], in: session)
        await acts.letGo(listed[1], in: session)
        #expect(strip(session) == ["2 people's notices held on a.example were not let go. Read again to see where each stands."])

        await server.set(F.get(Self.a, Self.requests), .body("[" + F.request(72, by: "Flo", count: 1) + "]"))
        await acts.open(host: Self.a, in: session)
        #expect(strip(session) == ["a.example did not let the notices go. What it holds is still listed. From: @flo@a.example (Flo)."])
    }

    /// Pins `afterUnconfirmed`: only a line already asked for once, with no answer heard.
    @Test("A gathered line whose dismissal was not confirmed in time, asked again: the source knowing no such line is the first ask having landed. Without that, the same answer is a failure")
    func aRetryAfterNoAnswerReadsGoneAsGone() async throws {
        let path = F.post(Self.a, "/api/v2/notifications/favourite-9-1/dismiss")
        for timedOutFirst in [true, false] {
            let (session, server, _) = try await F.shell([
                F.get(Self.a, "/api/v2/notifications"): F.gathered(count: 5, newest: 12),
                path: timedOutFirst ? .fails(nil, .timedOut) : .status(404),
            ], signedIn: [Self.a: F.acts])
            let list = session.noticeList
            await list.read(in: session)
            let notice = try #require(list.lines.first)

            await list.acts.dismiss(notice, in: session)
            #expect(list.lines == [notice], "\(timedOutFirst)")
            #expect(session.said.lines.map(\.why) == [timedOutFirst ? .unconfirmed : .declined])

            await server.set(path, .status(404))
            await list.acts.dismiss(notice, in: session)
            #expect(list.lines.isEmpty == timedOutFirst, "\(timedOutFirst)")
            #expect(session.said.lines.isEmpty == timedOutFirst, "\(timedOutFirst)")
            #expect(await server.count(path) == 2)
        }
    }

    @Test("Dismissing one while dismissing all is out at its source: whichever answers first, nothing dismissed is drawn, nothing still there stays hidden, and no line says what is no longer true")
    func oneWhileAllIsOut() async throws {
        // The one fails first, then all lands: said while true, taken down once all went.
        do {
            let one = Gate(), all = Gate()
            let (session, server, _) = try await two([Self.dismiss4: .held(one, "{}", 503), Self.clear: .held(all, "{}")])
            let list = session.noticeList
            let single = try start(.dismiss, in: session), every = try start(.dismissAll, in: session)
            #expect(await spun { await server.posts.count == 2 })
            #expect(ids(list.lines) == ["b8"])
            await one.open()
            await single.value
            #expect(ids(list.lines) == ["b8"], "a line was drawn while dismissing all is out")
            #expect(session.said.lines.map(\.what) == [.notice(.dismiss)] && session.said.lines.map(\.why) == [.declined])
            await all.open()
            await every.value
            #expect(ids(list.lines) == ["b8"] && list.reaches[Self.a]?.notices.isEmpty == true)
            #expect(session.said.lines.isEmpty, "a notice was still said to be here after all were dismissed")
        }
        // All lands first, then the one fails: there is nothing left to say it of.
        do {
            let one = Gate(), all = Gate()
            let (session, server, _) = try await two([Self.dismiss4: .held(one, "{}", 503), Self.clear: .held(all, "{}")])
            let list = session.noticeList
            let single = try start(.dismiss, in: session), every = try start(.dismissAll, in: session)
            #expect(await spun { await server.posts.count == 2 })
            await all.open()
            await every.value
            await one.open()
            await single.value
            #expect(ids(list.lines) == ["b8"] && session.said.lines.isEmpty && list.acts.acting.isEmpty)
        }
        // All fails while the one is still out, and the one then lands.
        do {
            let one = Gate(), all = Gate()
            let (session, server, _) = try await two([Self.dismiss4: .held(one, "{}"), Self.clear: .held(all, "{}", 403)])
            let list = session.noticeList
            let single = try start(.dismiss, in: session), every = try start(.dismissAll, in: session)
            #expect(await spun { await server.posts.count == 2 })
            await all.open()
            await every.value
            #expect(ids(list.lines) == ["b8", "a3"], "a line whose own dismissal is still out was drawn")
            #expect(session.said.lines.map(\.what) == [.notice(.dismissAll)] && session.said.lines.map(\.why) == [.refused])
            await one.open()
            await single.value
            #expect(ids(list.lines) == ["b8", "a3"] && ids(list.reaches[Self.a]?.notices ?? []) == ["a3"])
            #expect(session.said.lines.map(\.what) == [.notice(.dismissAll)] && session.said.lines.map(\.why) == [.refused])
        }
    }

    @Test("The same act asked twice while it is out is sent once")
    func theSameActTwiceIsSentOnce() async throws {
        let gate = Gate()
        let (session, server, _) = try await two([Self.dismiss4: .held(gate, "{}")])
        let first = try start(.dismiss, in: session)
        #expect(await spun { await server.count(Self.dismiss4) == 1 })
        try await start(.dismiss, in: session).value
        #expect(await server.count(Self.dismiss4) == 1 && session.noticeList.acts.acting.count == 1)
        await gate.open()
        await first.value
        #expect(await server.posts == [Self.dismiss4])
    }

    // MARK: - What is held back

    /// Pins `outrun` in `ShellNoticeActs`: a reading of the requests sent before the yes.
    @Test("A reading of what a source holds back, sent before it let a request go and landing after, does not list that request again")
    func aStaleReadingOfRequestsIsNotTaken() async throws {
        let reading = Gate()
        let go = F.post(Self.a, Self.requests + "/71/dismiss")
        let (session, server, _) = try await two([go: .body("{}")])
        let acts = session.noticeList.acts
        let both = "[" + F.request(71, by: "Eve", count: 3) + "," + F.request(72, by: "Flo", count: 1) + "]"
        await server.set(F.get(Self.a, Self.requests), .held(reading, both))
        let asked = await server.count(F.get(Self.a, Self.requests))
        let read = Task { await acts.open(host: Self.a, in: session) }
        #expect(await spun { await server.count(F.get(Self.a, Self.requests)) == asked + 1 })

        try await start(.letGo, in: session).value
        #expect(acts.requests[Self.a]?.map(\.requestID) == ["72"])
        await reading.open()
        await read.value
        #expect(acts.requests[Self.a]?.map(\.requestID) == ["72"], "a request let go came back with a reading sent before")
        #expect(acts.held(host: Self.a) == NoticesHeld(requests: 1, notices: 1))

        // The next reading is the source's word.
        await server.set(F.get(Self.a, Self.requests), .body("[" + F.request(72, by: "Flo", count: 1) + "," + F.request(73, by: "Gil", count: 2) + "]"))
        await acts.open(host: Self.a, in: session)
        #expect(acts.requests[Self.a]?.map(\.requestID) == ["72", "73"])
    }

    /// Pins `outrun` where what a source holds is looked at: the count, as the requests.
    @Test("A look at what a source holds back, sent before it let a request go and landing after, does not put the count back")
    func aStaleLookIsNotTaken() async throws {
        let looking = Gate()
        let go = F.post(Self.a, Self.requests + "/71/dismiss")
        let (session, server, _) = try await two([go: .body("{}")])
        let acts = session.noticeList.acts
        await server.set(F.get(Self.a, Self.policy), .held(looking, #"{"summary":{"pending_requests_count":2,"pending_notifications_count":4}}"#))
        let asked = await server.count(F.get(Self.a, Self.policy))
        let look = Task { await acts.look(in: session) }
        #expect(await spun { await server.count(F.get(Self.a, Self.policy)) == asked + 1 })

        try await start(.letGo, in: session).value
        #expect(acts.held(host: Self.a) == NoticesHeld(requests: 1, notices: 1))
        await looking.open()
        await look.value
        #expect(acts.held(host: Self.a) == NoticesHeld(requests: 1, notices: 1), "a count from before the request left was taken")
        #expect(acts.requests[Self.a]?.map(\.requestID) == ["72"])

        // The next look is the source's word.
        await server.set(F.get(Self.a, Self.policy), F.policy(requests: 3, notices: 9))
        await acts.look(in: session)
        #expect(acts.held(host: Self.a) == NoticesHeld(requests: 3, notices: 9))
    }

    @Test("The last request leaving takes the held-back line off the page at the yes, and a failure draws it again, still open")
    func theLastRequestLeaving() async throws {
        let gate = Gate()
        let through = F.post(Self.a, Self.requests + "/71/accept")
        let (session, server, _) = try await two([
            F.get(Self.a, Self.policy): F.policy(requests: 1, notices: 3),
            F.get(Self.a, Self.requests): .body("[" + F.request(71, by: "Eve", count: 3) + "]"),
            through: .held(gate, "{}", 500),
        ])
        let acts = session.noticeList.acts
        #expect(acts.shownHolders == [Self.a])
        let task = try start(.letThrough, in: session)
        #expect(await spun { await server.count(through) == 1 })
        #expect(acts.shownHolders.isEmpty && acts.shownHeld(host: Self.a) == nil, "a source was said to hold what is on its way out")
        #expect(acts.holders == [Self.a] && acts.opened == [Self.a])

        await gate.open()
        await task.value
        #expect(acts.shownHolders == [Self.a] && acts.opened == [Self.a] && acts.listed(host: Self.a).count == 1)
        #expect(strip(session) == ["a.example did not let the notices through. What it holds is still listed. From: @eve@a.example (Eve)."])
    }

    // MARK: - Counts

    @Test("While a line is hidden the floor, how far each source was read, the bound and its full line are as they were, and the count of what the kinds leave out is of what is drawn")
    func countsWhileHidden() async throws {
        let gate = Gate()
        let (session, server, _) = try await F.shell([
            F.get(Self.a): Self.top,
            F.get(Self.b): F.page(F.one(8, "mention", by: "Cy", minutes: 5)),
            Self.dismiss4: .held(gate, "{}", 503),
        ], signedIn: [Self.a: F.acts, Self.b: F.reads])
        let list = session.noticeList
        list.capacity = 1
        await list.read(in: session)
        // Each source handed over more than the one line held of it.
        #expect(list.fullHosts == [Self.a, Self.b] && ids(list.reaches[Self.a]?.notices ?? []) == ["a4"])
        let floor = list.floor, reached = list.reaches[Self.a]?.reached, drawn = list.lines.count
        func narrowed() -> Int? {
            if case .narrowed(let held) = NoticesPane.none(unread: [], in: session) { held } else { nil }
        }
        #expect(narrowed() == drawn)

        let task = try start(.dismiss, in: session)
        #expect(await spun { await server.count(Self.dismiss4) == 1 })
        #expect(!list.lines.contains { $0.newestID == "4" } && list.lines.count == drawn - 1)
        #expect(list.fullHosts == [Self.a, Self.b] && list.isFull, "a hidden line made a source held to its bound look read whole")
        #expect(list.floor == floor && list.reaches[Self.a]?.reached == reached)
        #expect(ids(list.reaches[Self.a]?.notices ?? []) == ["a4"])
        #expect(narrowed() == (drawn - 1 > 0 ? drawn - 1 : nil))

        await gate.open()
        await task.value
        #expect(list.lines.count == drawn && narrowed() == drawn && list.fullHosts == [Self.a, Self.b] && list.floor == floor)
    }

    // MARK: - The lamp

    @Test("The lamp on a line the person dismissed goes to the line that takes its place; a line that left any other way leaves nothing lit; a line drawn again does not take the lamp back")
    func theLamp() {
        let was = ["a", "b", "c", "d"]
        func lamp(_ selected: String?, now: [String], leaving: Set<String> = []) -> String? {
            NoticesPane.lamp(selected, was: was, now: now, leaving: leaving.contains)
        }
        // Still drawn, or nothing lit: as it was.
        #expect(lamp("b", now: ["a", "b", "d"]) == "b")
        #expect(lamp(nil, now: ["a", "c"], leaving: ["b"]) == nil)
        // Dismissed: the next one down, and past another that left with it.
        #expect(lamp("b", now: ["a", "c", "d"], leaving: ["b"]) == "c")
        #expect(lamp("b", now: ["a", "d"], leaving: ["b", "c"]) == "d")
        // The last line: the one above. The only line: nothing.
        #expect(lamp("d", now: ["a", "b", "c"], leaving: ["d"]) == "c")
        #expect(lamp("d", now: [], leaving: ["a", "b", "c", "d"]) == nil)
        // Left by the choice of kinds, or by its source's own word: not the lamp's.
        #expect(lamp("b", now: ["a", "c", "d"]) == nil)
        // Drawn again after a failure, the lamp having moved on: it stays where it went.
        #expect(NoticesPane.lamp("c", was: ["a", "c", "d"], now: was, leaving: { _ in false }) == "c")
    }

    /// Pins that what moves the lamp is taken at the yes (`ShellNoticeList.leftAtYes`): the
    /// page draws after the press, and the source may have answered by then.
    @Test("A lit line whose dismissal the source has already answered when the page draws still hands the lamp to its neighbour; one drawn again after a failure is no longer the person's to have sent away")
    func theLampAfterTheAnswerLanded() async throws {
        let (session, server, _) = try await two([Self.dismiss4: .body("{}"), Self.dismiss3: .status(503)])
        let list = session.noticeList
        let a4 = try line("a4", in: session).id, a3 = try line("a3", in: session).id
        let was = list.lines.map(\.id)

        // Pressed and answered before anything was drawn again.
        try await start(.dismiss, in: session).value
        #expect(list.acts.acting.isEmpty && list.reaches[Self.a]?.notices.contains { $0.id == a4 } == false)
        #expect(await server.count(Self.dismiss4) == 1)
        let now = list.lines.map(\.id)
        #expect(NoticesPane.lamp(a4, was: was, now: now, leaving: list.leftAtYes) == now.first, "the lamp went dark")

        // Refused: the line is drawn again, and a later leaving of it is not by the person's yes.
        await list.acts.dismiss(try line("a3", in: session), in: session)
        #expect(list.lines.contains { $0.id == a3 } && !list.leftAtYes(a3))
        #expect(list.leftAtYes(a4))
    }

    @Test("The list says which lines are on their way out by the person's own yes, and no others")
    func whatIsLeaving() async throws {
        let one = Gate(), all = Gate()
        let (session, server, _) = try await two([Self.dismiss4: .held(one, "{}", 503), Self.clear: .held(all, "{}", 503)])
        let list = session.noticeList
        let a4 = try line("a4", in: session).id, a3 = try line("a3", in: session).id, b8 = try line("b8", in: session).id
        #expect(![a4, a3, b8].contains(where: list.leftAtYes))

        let single = try start(.dismiss, in: session)
        #expect(await spun { await server.count(Self.dismiss4) == 1 })
        #expect(list.leftAtYes(a4) && !list.leftAtYes(a3) && !list.leftAtYes(b8))
        let every = try start(.dismissAll, in: session)
        #expect(await spun { await server.count(Self.clear) == 1 })
        #expect(list.leftAtYes(a4) && list.leftAtYes(a3) && !list.leftAtYes(b8))

        await one.open()
        await all.open()
        await single.value
        await every.value
        #expect(![a4, a3, b8].contains(where: list.leftAtYes))
    }
}
