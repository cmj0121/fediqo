import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #315, the people a source suggests the reader: the page that is a list of people, for a
/// list that is the reader's alone — what is asked for it and when, how it is read on and where
/// it ends, what it says where the host has none, where it is opened from and for whom, and
/// telling the source not to suggest somebody — asked first where the sign-in holds the account
/// part, and dim with its lock where it does not. And that
/// a source which is not asked who people are has no such page and no line to one.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), tied to the work that
/// made the ask where a check can name it: a held ask is let go by the check, and by a guard
/// when the run has gone still; every deadline is on a clock nobody turns.
@MainActor
@Suite("The people a source suggests", .serialized, .watched)
struct SuggestedTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let suggested = PeopleList(suggestedAt: host)

    private static let first = "/api/v2/suggestions?limit=80"
    private static func after(_ passed: Int) -> String { "\(first)&offset=\(passed)" }

    private static func stretch(_ ids: [Int]) -> PageServer.Answer {
        let entries = ids.map { #"{"source":"staff","sources":["featured"],"account":{"id":"\#($0)","acct":"p\#($0)","display_name":"Person \#($0)"}}"# }
        return PageServer.Answer(body: "[" + entries.joined(separator: ",") + "]")
    }

    private static let noSuchAddress = PageServer.Answer(body: #"{"error":"Not Found"}"#, status: 404)

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server, work)
    }

    private func signOut(_ session: ShellSession) throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        session.mastodon.refresh()
    }

    private func signIn(_ session: ShellSession, as access: String = "tok") throws {
        try signOut(session)
        try session.mastodon.tokens.save(MastodonToken(host: Self.host, accessToken: access, clientID: "c", clientSecret: "s"))
        session.mastodon.refresh()
    }

    private func ids(_ pages: ShellPeoplePages, _ session: ShellSession) -> [String] {
        pages.said(of: Self.suggested, in: session)?.people.map(\.accountID) ?? []
    }

    private static var sources: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources")
    }

    private static var shell: URL { sources.appending(path: "FediqoUI/Shell") }

    // MARK: - What is asked, and when

    @Test("Opening the people a source suggests asks it for one stretch — one ask, of eighty at most, as the reader, listed in the run's record as a list of people, and nothing held — and the page is handed who it gave; a stretch shorter than was asked for is all the source gave, said as the end; opened again, nobody is asked")
    func openingAsksOnceAsTheReader() async throws {
        let (session, server, work) = await session([Self.first: Self.stretch([3, 2, 1])])
        session.mastodon.work = work
        try signIn(session)
        let pages = ShellPersonPages().lists
        let before = try #require(pages.said(of: Self.suggested, in: session))
        #expect(before == PeopleSaid(list: Self.suggested, signedIn: true, dismissing: before.dismissing), "before anything answered")
        #expect(before.dismissing != nil, "Don't suggest stands on the people suggested, and on no other list")
        #expect(before.stateLine() == nil, "being asked is the page's toast to say, and no line of the list")

        await server.hold(Self.first)
        let firstGuard = watching("the ask of \(Self.first), held at its server") { await server.release(Self.first) }
        defer { firstGuard.cancel() }
        let opening = Task { await pages.opened(Self.suggested, in: session) }
        await server.arrival(of: Self.first, by: opening)
        let asking = pages.ask(of: Self.suggested, in: session, language: .english)
        #expect(asking.asking == "Asking m.example for the people it suggests…" && asking.stoppable, "the toast says the wait, and Stop stops it")
        await server.release(Self.first)
        await opening.value
        #expect(await server.asked == [Self.first])
        #expect(await server.bearers == ["Bearer tok"])
        let acts = work.record.filter { $0.reached == Self.host }
        #expect(acts.count == 1 && acts.allSatisfy { $0.purpose == .people && $0.source == Self.host })

        let said = try #require(pages.said(of: Self.suggested, in: session))
        #expect(said.reading == .said)
        #expect(said.people.map(\.accountID) == ["3", "2", "1"])
        #expect(!said.asking)
        #expect(said.foot == .end)
        #expect(said.sorting == nil)
        #expect(said.short == nil)
        #expect(said.footWords(.end, language: .english) == "No more people: m.example has sent all it gives.")
        #expect(said.stateLine() == nil)
        #expect(said.nothing() == nil)
        #expect(!said.offersAgain)
        #expect(pages.walked(Self.suggested, in: session) == said.people.map(\.id) && pages.canAskAgain(Self.suggested, in: session))
        let top = try #require(said.people.first)
        #expect(pages.person(top.id, on: Self.suggested, in: session)?.accountID == "3")
        #expect(session.notes.isEmpty)
        #expect(await session.store.held(host: Self.host).isEmpty)

        await pages.opened(Self.suggested, in: session)
        #expect(await server.asked.count == 1)
        // Nobody's list: of no account, counted by nobody, hidden by nobody, and one page a source.
        #expect(Self.suggested.asked == nil)
        #expect(Self.suggested.counted == nil)
        #expect(!Self.suggested.hidden)
        #expect(!Self.suggested.isDirectory)
        #expect(Self.suggested.id == PeopleList(suggestedAt: Self.host).id && Self.suggested.id != PeopleList(directoryAt: Self.host).id)
        #expect(Self.suggested.thing == .suggestions)
        #expect(Self.suggested.readByCount)
        #expect(PeopleSaid.counts(Self.suggested) == nil)
    }

    @Test("Reading on is the foot's press, one stretch a press, from how many people were passed over: a stretch as long as was asked for offers more; a second press while one is out asks nothing; somebody who arrives twice is listed once; the stretch shorter than was asked for is the end, and nothing is asked past it — where a real server would answer a failure")
    func readingOnIsPressedAndCounted() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch(Array(0..<80)), Self.after(80): Self.stretch([79, 100, 101]),
        ])
        try signIn(session)
        let pages = ShellPersonPages().lists
        await pages.opened(Self.suggested, in: session)
        #expect(pages.said(of: Self.suggested, in: session)?.foot == .more)
        await server.hold(Self.after(80))
        defer { Task { await server.release(Self.after(80)) } }
        let after80Guard = watching("the ask of \(Self.after(80)), held at its server") { await server.release(Self.after(80)) }
        defer { after80Guard.cancel() }
        let press = Task { await pages.readOn(Self.suggested, in: session) }
        await server.arrival(of: Self.after(80), by: press)
        #expect(pages.said(of: Self.suggested, in: session)?.foot == nil, "a stretch on its way is the toast's to say")
        let readingOn = pages.ask(of: Self.suggested, in: session, language: .english)
        #expect(readingOn.asking == "Reading more people…" && !readingOn.stoppable, "a reading-on is said, and not stopped")
        await pages.readOn(Self.suggested, in: session)
        #expect(await server.asked == [Self.first, Self.after(80)], "one on the wire, and no second")
        await server.release(Self.after(80))
        await press.value
        let said = try #require(pages.said(of: Self.suggested, in: session))
        #expect(said.people.count == 82 && Set(said.people.map(\.accountID)).count == 82)
        #expect(said.foot == .end)
        await pages.readOn(Self.suggested, in: session)
        #expect(await server.asked.count == 2, "nothing is asked past the end")
    }

    @Test("Suggestions are read only so far: after five whole stretches the foot says the reading stopped there and that the source may suggest more — never that it has no more — and takes no press")
    func readOnlySoFar() async throws {
        var routes = [Self.first: Self.stretch(Array(0..<80))]
        for passed in stride(from: 80, to: MastodonSuggestions.furthest, by: 80) {
            routes[Self.after(passed)] = Self.stretch(Array(passed..<(passed + 80)))
        }
        let (session, server, _) = await session(routes)
        try signIn(session)
        let pages = ShellPersonPages().lists
        await pages.opened(Self.suggested, in: session)
        for _ in 0..<6 { await pages.readOn(Self.suggested, in: session) }
        #expect(await server.asked.count == 5, "five stretches, and no sixth")
        let said = try #require(pages.said(of: Self.suggested, in: session))
        #expect(said.people.count == 400 && said.foot == .farthest)
        #expect(said.footWords(.farthest, language: .english) == "Fediqo reads the first 400 people a source suggests. m.example may suggest more.")
    }

    @Test("Where the reading stopped is decided by the place reached, not by how many could be read: at the fifth stretch one entry this build cannot read is one person not listed, and the foot still says the source may suggest more")
    func theFurthestIsAPlaceNotACount() async throws {
        var routes = [Self.first: Self.stretch(Array(0..<80))]
        for passed in stride(from: 80, to: MastodonSuggestions.furthest - 80, by: 80) {
            routes[Self.after(passed)] = Self.stretch(Array(passed..<(passed + 80)))
        }
        let whole = Self.stretch(Array(320..<399)).body
        routes[Self.after(320)] = PageServer.Answer(body: String(whole.dropLast()) + #","junk"]"#)
        let (session, server, _) = await session(routes)
        try signIn(session)
        let pages = ShellPersonPages().lists
        await pages.opened(Self.suggested, in: session)
        for _ in 0..<6 { await pages.readOn(Self.suggested, in: session) }
        #expect(await server.asked.count == 5)
        let said = try #require(pages.said(of: Self.suggested, in: session))
        #expect(said.people.count == 399)
        #expect(said.foot == .farthest)
    }

    // MARK: - Whose it is

    @Test("With no sign-in nobody is asked: a source suggests nobody anything unsigned, so the page says it could not ask and the source's page offers no line; signed in, the line is offered and the list asked as the reader; signed out again, who was given is no longer drawn and nobody is asked")
    func onlyForSomebodySignedIn() async throws {
        let (session, server, work) = await session([Self.first: Self.stretch([3, 2, 1])])
        let all = ShellPersonPages()
        let pages = all.lists
        #expect(all.more.said(at: Self.host, in: session)?.suggested == false, "no sign-in: no line")
        await pages.opened(Self.suggested, in: session)
        await pages.again(Self.suggested, in: session)
        await pages.readOn(Self.suggested, in: session)
        #expect(await server.asked.isEmpty && work.record.isEmpty)
        let unsigned = try #require(pages.said(of: Self.suggested, in: session))
        #expect(unsigned.reading == .failed)
        #expect(!unsigned.signedIn)
        #expect(unsigned.people.isEmpty)
        #expect(unsigned.stateLine() == nil && pages.ask(of: Self.suggested, in: session).failed == [Self.host], "the miss is the toast's")

        try signIn(session)
        #expect(all.more.said(at: Self.host, in: session)?.suggested == true)
        await pages.opened(Self.suggested, in: session)
        #expect(await server.bearers == ["Bearer tok"] && ids(pages, session) == ["3", "2", "1"])

        try signOut(session)
        #expect(ids(pages, session).isEmpty, "the reader's list is nobody's")
        #expect(all.more.said(at: Self.host, in: session)?.suggested == false)
        await pages.opened(Self.suggested, in: session)
        #expect(await server.asked.count == 1 && session.mastodon.ended.isEmpty)
    }

    @Test("A stretch that comes after the sign-in was replaced, ended, or its source removed lands nowhere: the list is the reader's who asked for it, and the next reader is shown none of it and asked for their own")
    func aLateAnswerLandsNowhere() async throws {
        let (session, server, _) = await session([Self.first: Self.stretch([3, 2, 1])])
        try signIn(session)
        let pages = ShellPersonPages().lists
        // A wire that goes on answering an ask that was called off.
        pages.reachingSuggestions = { _ in
            MastodonSuggestions(door: MastodonAuthorized(
                token: MastodonToken(host: Self.host, accessToken: "first", clientID: "c", clientSecret: "s"),
                sender: server, store: MemoryMastodonTokens()
            ))
        }
        // Replaced while the list is being asked.
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let firstGuard = watching("the ask of \(Self.first), held at its server") { await server.release(Self.first) }
        defer { firstGuard.cancel() }
        let out = Task { await pages.opened(Self.suggested, in: session) }
        await server.arrival(of: Self.first, by: out)
        try signIn(session, as: "other")
        await server.release(Self.first)
        await out.value
        #expect(ids(pages, session).isEmpty, "what was asked as the reader before is not the next one's")
        #expect(pages.said(of: Self.suggested, in: session)?.reading == .asking)
        await pages.opened(Self.suggested, in: session)
        #expect(await server.asked.count == 2 && ids(pages, session) == ["3", "2", "1"], "asked afresh, as them")

        // Ended while it is being asked from the top.
        await server.hold(Self.first)
        let top = Task { await pages.again(Self.suggested, in: session) }
        await server.arrival(of: Self.first, times: 3, by: top)
        try signOut(session)
        await server.release(Self.first)
        await top.value
        #expect(ids(pages, session).isEmpty && pages.said(of: Self.suggested, in: session)?.signedIn == false)

        // Its source removed while it is being asked: there is no such page, and none on its return.
        try signIn(session, as: "third")
        await server.hold(Self.first)
        let gone = Task { await pages.opened(Self.suggested, in: session) }
        await server.arrival(of: Self.first, times: 4, by: gone)
        session.sources = session.sources.filter { $0.host != Self.host }
        #expect(pages.said(of: Self.suggested, in: session) == nil)
        await server.release(Self.first)
        await gone.value
        #expect(pages.said(of: Self.suggested, in: session) == nil)
    }

    // MARK: - Where the host has none

    @Test("Suggestions are absent where the host says their address is not there: the page says so in one sentence, the run remembers it, the source's page stops offering the line, and opening it again asks nobody — until the person asks again, which asks the host afresh. An empty answer is a source suggesting nobody, and a refusal or a failure is a failure: neither is ever absent")
    func absentByItsOwnAddress() async throws {
        let (session, server, _) = await session([Self.first: Self.noSuchAddress])
        try signIn(session)
        let all = ShellPersonPages()
        let pages = all.lists
        #expect(all.more.said(at: Self.host, in: session)?.suggested == true, "offered until the host says otherwise")
        await pages.opened(Self.suggested, in: session)
        let absent = try #require(pages.said(of: Self.suggested, in: session))
        #expect(absent.reading == .absent)
        #expect(absent.people.isEmpty)
        #expect(absent.foot == nil)
        #expect(!absent.asking)
        #expect(absent.stateLine(language: .english) == "m.example does not suggest people.")
        #expect(absent.offersAgain && absent.nothing() == nil)
        #expect(all.more.hosts.has(.suggestions, at: Self.host) == .absent && all.more.hosts.has(.directory, at: Self.host) == .unsaid)
        let line = try #require(all.more.said(at: Self.host, in: session))
        #expect(!line.suggested && line.directory, "its directory is another thing")
        #expect(session.mastodon.ended.isEmpty, "no word about the sign-in")
        await pages.opened(Self.suggested, in: session)
        await pages.readOn(Self.suggested, in: session)
        #expect(await server.asked == [Self.first], "absent: opened again, nobody is asked")

        // The person asks again: the host is asked afresh, and suggests nobody now.
        await server.answer(Self.first, Self.stretch([]))
        await pages.again(Self.suggested, in: session)
        let empty = try #require(pages.said(of: Self.suggested, in: session))
        #expect(empty.reading == .said)
        #expect(empty.foot == nil)
        #expect(!empty.offersAgain)
        #expect(empty.nothing(language: .english) == "m.example suggests nobody to this sign-in.")
        #expect(all.more.hosts.has(.suggestions, at: Self.host) == .unsaid && all.more.said(at: Self.host, in: session)?.suggested == true)

        let refusals = [
            PageServer.Answer(body: #"{"error":"Record not found"}"#, status: 404),
            PageServer.Answer(body: #"{"error":"This action is outside the authorized scopes"}"#, status: 403),
            PageServer.Answer(body: "", status: 500),
        ]
        for refusal in refusals {
            let (other, failing, _) = await self.session([Self.first: refusal])
            try signIn(other)
            let fresh = ShellPersonPages()
            await fresh.lists.opened(Self.suggested, in: other)
            let failed = try #require(fresh.lists.said(of: Self.suggested, in: other))
            #expect(failed.reading == .failed)
            #expect(!failed.offersAgain, "asking again is `r`, the mark or a pull")
            #expect(fresh.more.hosts.has(.suggestions, at: Self.host) == .unsaid)
            #expect(failed.stateLine() == nil && fresh.lists.ask(of: Self.suggested, in: other).failed == [Self.host])
            #expect(fresh.more.said(at: Self.host, in: other)?.suggested == true && other.mastodon.ended.isEmpty)
            #expect(await failing.asked == [Self.first])
        }
    }

    @Test("A not-found that comes late, asked for before the person asked the host afresh and answered after, is written down nowhere: the line is still offered, and the page says what its own ask heard")
    func aNotFoundFromBeforeAskingAfresh() async throws {
        let (session, server, _) = await session([Self.first: Self.noSuchAddress])
        try signIn(session)
        let all = ShellPersonPages()
        let hosts = all.more.hosts
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let firstGuard = watching("the ask of \(Self.first), held at its server") { await server.release(Self.first) }
        defer { firstGuard.cancel() }
        let out = Task { await all.lists.opened(Self.suggested, in: session) }
        await server.arrival(of: Self.first, by: out)
        // "Ask again" on the source's page, while the ask is out.
        hosts.askAfresh(Self.host)
        await server.release(Self.first)
        await out.value
        #expect(hosts.has(.suggestions, at: Self.host) == .unsaid, "heard from before the asking afresh")
        #expect(all.more.said(at: Self.host, in: session)?.suggested == true)
        #expect(all.lists.said(of: Self.suggested, in: session)?.reading == .absent)
        // One asked for since is believed.
        await all.lists.again(Self.suggested, in: session)
        #expect(hosts.has(.suggestions, at: Self.host) == .absent && all.more.said(at: Self.host, in: session)?.suggested == false)
    }

    // MARK: - Don't suggest

    private static let reads = "read:statuses read:lists read:accounts"
    private static let account = "\(reads) write:accounts"
    private static func dismiss(_ id: Int) -> String { "/api/v1/suggestions/\(id)" }

    private func signIn(_ session: ShellSession, holding scopes: String) throws {
        try signOut(session)
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
    }

    @Test("Where the sign-in holds the account part, a suggestion's row has Don't suggest in its `…`, asked about first: at the yes the row leaves and the source is told, as the reader, written down as an act; a read from the top already on its way when the source answered does not bring them back, and the next read is the source's word — one it no longer suggests is not there")
    func dontSuggestTellsTheSource() async throws {
        let (session, server, work) = await session([
            Self.first: Self.stretch([3, 2, 1]), Self.dismiss(3): PageServer.Answer(body: "{}"),
        ])
        session.mastodon.work = work
        try signIn(session, holding: Self.account)
        let pages = ShellPersonPages().lists
        await pages.opened(Self.suggested, in: session)
        let said = try #require(pages.said(of: Self.suggested, in: session))
        #expect(said.dismissing == .offered)
        let three = try #require(said.people.first)
        let more = try #require(said.more(of: three, act: {}, language: .english))
        #expect(more.reasons.isEmpty)
        let item = try #require(more.items.first)
        #expect(more.items.count == 1 && item.isDanger && item.name == "Don't suggest" && item.answers)
        let question = try #require(item.question)
        #expect(question.title == "Tell m.example not to suggest \(three.lineHandle) again?")
        #expect(question.line == "They leave this list. You can still find them and follow them.")
        #expect(question.chorded != nil)

        await server.hold(Self.dismiss(3))
        defer { Task { await server.release(Self.dismiss(3)) } }
        let dismissGuard = watching("the ask of \(Self.dismiss(3)), held at its server") { await server.release(Self.dismiss(3)) }
        defer { dismissGuard.cancel() }
        let press = Task { await pages.press(.dismissSuggestion, on: three, of: Self.suggested, in: session) }
        await server.arrival(of: Self.dismiss(3), by: press)
        #expect(ids(pages, session) == ["2", "1"], "the row leaves at the press")

        // A read from the top set out while the press is out, and answered after it.
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let firstGuard = watching("the ask of \(Self.first), held at its server") { await server.release(Self.first) }
        defer { firstGuard.cancel() }
        let top = Task { await pages.again(Self.suggested, in: session) }
        await server.arrival(of: Self.first, times: 2, by: top)
        await server.release(Self.dismiss(3))
        await press.value
        #expect(ids(pages, session) == ["2", "1"])
        await server.release(Self.first)
        await top.value
        #expect(ids(pages, session) == ["2", "1"], "a read already on its way does not bring them back")
        #expect(await server.asked.filter { $0 == Self.dismiss(3) }.count == 1)
        #expect(work.record.contains { $0.purpose == .write && $0.reached == Self.host })

        // The next read is the source's word.
        await server.answer(Self.first, Self.stretch([2, 1]))
        await pages.again(Self.suggested, in: session)
        #expect(ids(pages, session) == ["2", "1"], "a dismissed suggestion does not come back on the next read")
        await server.answer(Self.first, Self.stretch([3, 2, 1]))
        await pages.again(Self.suggested, in: session)
        #expect(ids(pages, session) == ["3", "2", "1"], "one the source still suggests is drawn")
    }

    @Test("A dismissal that did not arrive brings the row back where it was, with the sentence that says so under it in both languages; read again from the top the sentence goes")
    func aDismissalThatFailed() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2, 1]), Self.dismiss(2): PageServer.Answer(body: "<html>", status: 500),
        ])
        try signIn(session, holding: Self.account)
        let pages = ShellPersonPages().lists
        await pages.opened(Self.suggested, in: session)
        let two = try #require(pages.said(of: Self.suggested, in: session)?.people[1])
        await pages.press(.dismissSuggestion, on: two, of: Self.suggested, in: session)
        #expect(await server.asked.contains(Self.dismiss(2)))
        let said = try #require(pages.said(of: Self.suggested, in: session))
        #expect(said.people.map(\.accountID) == ["3", "2", "1"])
        #expect(said.missed["2"] == "Could not tell m.example not to suggest \(two.lineHandle).")
        #expect(PersonActing.missedWords(.dismissSuggestion, named: "@p2", at: Self.host, language: .taiwanese) == "無法要 m.example 不再建議 @p2。")
        await pages.again(Self.suggested, in: session)
        #expect(pages.said(of: Self.suggested, in: session)?.missed.isEmpty == true)
    }

    @Test("Where the sign-in does not hold the account part, Don't suggest is dim with the lock and the part's own sentence stands at the menu's head; its press asks for the part and sends nothing; a row of any other list of people has no such item")
    func dontSuggestWithoutThePartAsks() async throws {
        let (session, server, work) = await session([Self.first: Self.stretch([3, 2, 1])])
        session.mastodon.work = work
        try signIn(session, holding: Self.reads)
        let pages = ShellPersonPages().lists
        await pages.opened(Self.suggested, in: session)
        let said = try #require(pages.said(of: Self.suggested, in: session))
        guard case .locked(let place) = said.dismissing else {
            Issue.record("Don't suggest is not dim: \(String(describing: said.dismissing))")
            return
        }
        #expect(place.asks)
        let three = try #require(said.people.first)
        var acted = 0
        let more = try #require(said.more(of: three, act: { acted += 1 }, language: .english))
        #expect(more.reasons == ["This sign-in was not asked to change your profile. Update permission"])
        let item = try #require(more.items.first)
        #expect(item.look == .dim(.askAgain) && item.symbol == SourceRow.permissionSymbol && !item.isDanger && item.answers)
        item.press { _ in }
        #expect(acted == 1)

        #expect(session.partAsks.open == nil)
        await pages.press(.dismissSuggestion, on: three, of: Self.suggested, in: session)
        #expect(session.partAsks.open?.ticked == [.account] && session.partAsks.open?.host == Self.host)
        #expect(await server.asked == [Self.first] && work.record.count == 1, "the press sends nothing")
        #expect(ids(pages, session) == ["3", "2", "1"])

        let person = Person(source: Self.source, accountID: "42", handle: "@ada@m.example", name: "Ada")
        for list in [PeopleList(directoryAt: Self.host), PeopleList(.followers, of: person), PeopleList(foundAt: Self.host, words: "ada")] {
            let other = PeopleSaid(list: list, reading: .said, people: [person])
            #expect(other.more(of: person, act: {}) == nil, "\(list.which)")
            #expect(PeoplePane.menu(for: other, of: person, asks: .constant(nil)) { _ in } == nil, "\(list.which)")
        }
    }

    // MARK: - Where it is opened from, and a forum

    @Test("The line that opens the people a source suggests is drawn on its page only where somebody answers its press, the reader is signed in there and the host has not said it has none; its press takes the sheet down and hands over that source's suggestions, a step of the walk like any list of people; nothing is asked by drawing or pressing it")
    func theLineOnTheSourcesPage() async throws {
        let (session, server, _) = await session([:])
        func height(_ said: SourceMoreSaid, opens: Bool) -> CGFloat {
            let block = VStack(spacing: 0) { SourceMoreSection(said: said, onSuggested: opens ? {} : nil) }.frame(width: 460)
            let hosted = NSHostingView(rootView: block)
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize.height
        }
        let unsigned = SourceMoreSaid(source: Self.host, account: .waiting, servers: nil, weeks: .waiting)
        var offered = unsigned
        offered.suggested = true
        #expect(!unsigned.suggested, "not offered unless said to be")
        #expect(height(offered, opens: true) > height(offered, opens: false))
        #expect(height(unsigned, opens: true) == height(offered, opens: false), "no sign-in, or absent: no line, not a dim one")
        // Offered none of the three and no directory, the people it suggests alone are a thing the page offers.
        var bare = SourceMoreSaid(source: Self.host, account: nil, servers: nil, weeks: nil)
        bare.directory = false
        #expect(bare.isAbsent(opensDirectory: true))
        bare.suggested = true
        #expect(!bare.isAbsent(opensDirectory: true) && bare.isAbsent(opensDirectory: false))
        #expect(SourceMoreSaid.suggestedLabel(language: .english) == "People it suggests")
        #expect(SourceMoreSaid.suggestedHint(language: .english) == "Closes this page and opens the people it suggests.")

        var opened: [PeopleList] = []
        let sheet = JoinSheet(session: session, onPeople: { opened.append($0) })
        #expect(JoinSheet(session: session).suggestedPress(at: Self.host) == nil, "nobody to answer: no line")
        let press = try #require(sheet.suggestedPress(at: Self.host))
        press()
        #expect(opened == [Self.suggested] && session.stage == nil)
        var walk = ShellWalk()
        let stepped = walk.walk(to: .people(Self.suggested), from: "row")
        #expect(stepped && walk.openedPeople == Self.suggested)
        #expect(await server.asked.isEmpty, "nothing is asked by drawing the line or pressing it: the page asks as it opens")
    }

    @Test("A forum has no suggestions: its page is handed no block and no line, signed in or not, nothing is asked of it by opening, asking again or reading on — and the press decides nothing by the kind of source")
    func aForumHasNone() async throws {
        let (session, server, work) = await session([:])
        try session.mastodon.tokens.save(MastodonToken(host: Self.forum.host, accessToken: "odd", clientID: "c", clientSecret: "s"))
        session.mastodon.refresh()
        let all = ShellPersonPages()
        let list = PeopleList(suggestedAt: Self.forum.host)
        #expect(all.lists.said(of: list, in: session) == nil && all.more.said(at: Self.forum.host, in: session) == nil)
        await all.lists.opened(list, in: session)
        await all.lists.again(list, in: session)
        await all.lists.readOn(list, in: session)
        #expect(all.lists.walked(list, in: session).isEmpty && !all.lists.canAskAgain(list, in: session))
        #expect(await server.asked.isEmpty && work.record.isEmpty)
        func height<Block: View>(_ block: Block) -> CGFloat {
            let hosted = NSHostingView(rootView: VStack(spacing: 0) { block }.frame(width: 460))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize.height
        }
        #expect(height(SourceMoreBlock(host: Self.forum.host, more: all.more, session: session, onDirectory: {}, onSuggested: {})) == 0)

        let sheet = try String(contentsOf: Self.shell.appending(path: "JoinSheet.swift"), encoding: .utf8)
        let press = try #require(sheet.range(of: "func suggestedPress"))
        let body = sheet[press.lowerBound...].prefix(400)
        #expect(!body.contains(".kind") && !body.contains("offers."), "the press decides nothing by the kind of source")
    }

    // MARK: - What the page says

    @Test("The head says whose suggestions they are; every sentence of the page is about the source; and each is written in each language the app speaks, with the places it fills, and the two Chinese tables alike")
    func theWords() throws {
        #expect(PeopleSaid.title(Self.suggested, language: .english) == "People m.example suggests")
        #expect(PeopleSaid.title(Self.suggested, language: .taiwanese) == "m.example 建議的人")
        #expect(PeopleSaid.dismissName(language: .taiwanese) == "不再建議")
        var said = PeopleSaid(list: Self.suggested, signedIn: true, reading: .absent)
        #expect(said.stateLine(language: .taiwanese) == "m.example 沒有提供建議的人。")
        said.reading = .said
        #expect(said.nothing(language: .taiwanese) == "m.example 沒有向這個登入建議任何人。")
        // A directory says what it said before.
        let directory = PeopleSaid(list: PeopleList(directoryAt: Self.host), reading: .absent, sorting: DirectoryChoice())
        #expect(directory.stateLine(language: .english) == "m.example does not offer a directory of people.")

        let resources = Self.sources.appending(path: "FediqoUI/Resources")
        let english = try String(contentsOf: resources.appending(path: "en.lproj/Localizable.strings"), encoding: .utf8)
        let keys = english.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\"people.suggested.") || line.hasPrefix("\"people.title.suggested\"") || line.hasPrefix("\"source.more.suggested") else { return nil }
            return line.dropFirst().split(separator: "\"").first.map(String.init)
        }
        #expect(keys.count == 11)
        #expect(!keys.contains("people.suggested.dismiss.dim"))
        #expect(keys.contains("people.suggested.dismiss.failed"))
        #expect(keys.contains("source.more.suggested.hint"))
        func places(_ text: String) -> [String] {
            text.matches(of: /%(\d\$)?[@d]/).map { String($0.output.0) }.sorted()
        }
        for key in keys {
            let written = L10n.t(key, language: .english)
            #expect(written != key, "\(key)")
            #expect(!written.contains("%d"), "\(key)")
            #expect(!written.contains("$d"), "\(key)")
            for language in DummyLanguage.allCases {
                let other = L10n.t(key, language: language)
                #expect(other != key && places(other) == places(written), "\(key) in \(language)")
            }
        }
        let taiwan = try Data(contentsOf: resources.appending(path: "zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appending(path: "zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
        // A source the person added is a 來源; nothing here calls it anything else.
        for key in keys { #expect(!L10n.t(key, language: .taiwanese).contains("站台"), "\(key)") }
    }

    @Test("The page of the people suggested is laid out to the width it is given and never past it, in light and in dark, in each state it has: asking, people with their menus, nobody, a failure and absent")
    func thePageLaidOut() {
        func size<Page: View>(_ page: Page, _ width: CGFloat, _ scheme: ColorScheme) -> CGSize {
            let hosted = NSHostingView(rootView: page.frame(width: width).environment(\.colorScheme, scheme))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize
        }
        let people = (1...3).map { Person(source: Self.source, accountID: "\($0)", handle: "@p\($0)@m.example", name: "Person \($0)") }
        var states = [PeopleSaid(list: Self.suggested, signedIn: true)]
        states.append(PeopleSaid(list: Self.suggested, signedIn: true, reading: .said, people: people, foot: .more))
        states.append(PeopleSaid(list: Self.suggested, signedIn: true, reading: .said, people: people, foot: .farthest))
        states.append(PeopleSaid(list: Self.suggested, signedIn: true, reading: .said))
        states.append(PeopleSaid(list: Self.suggested, signedIn: true, reading: .failed))
        states.append(PeopleSaid(list: Self.suggested, signedIn: true, reading: .absent))
        states.append(PeopleSaid(list: Self.suggested, signedIn: true, reading: .said, people: people, asking: true, foot: .end))
        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (390, .dark), (320, .light), (320, .dark)] {
            for said in states {
                let pane = PeoplePane(said: said, selectedID: .constant(nil), onOpen: { _ in }, onBack: {})
                #expect(size(pane, width, scheme).width == width, "\(said.reading) at \(width)")
            }
            let long = PeopleList(suggestedAt: "a-rather-long-name-of-a-server.a-rather-long-instance-name.example")
            #expect(size(PeopleHead(said: PeopleSaid(list: long)), width, scheme).width == width)
        }
        // A row with a menu is a row with its `…`: drawn, and laid out within the row.
        let probe = PersonRowProbe()
        let menu = PeoplePane.menu(
            for: PeopleSaid(list: Self.suggested, reading: .said, people: people, dismissing: .offered), of: people[0],
            asks: .constant(nil)
        ) { _ in }
        let row = PersonRow(person: people[0], menu: menu, probe: probe)
        let drawn = size(row, 390, .light)
        let dots = probe.frames[.more]
        #expect(drawn.width == 390 && dots != nil)
    }
}
