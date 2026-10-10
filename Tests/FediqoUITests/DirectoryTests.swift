import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #315, a source's directory of people: the page that is a list of people, for a list that is
/// nobody's — what is asked for it and when, how it is read on and chosen, what it says where
/// the host has none, and where it is opened from. And that a source which is not asked who
/// people are has no such page and no line to one.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), and each ends by
/// itself: a held ask is let go in a `defer`, and by the server after its patience.
@MainActor
@Suite("A source's directory of people", .serialized, .timeLimit(.minutes(1)))
struct DirectoryTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let directory = PeopleList(directoryAt: host)

    private static let first = "/api/v1/directory?order=active&limit=80"
    private static let newest = "/api/v1/directory?order=new&limit=80"
    private static let local = "/api/v1/directory?order=active&limit=80&local=true"
    private static func after(_ passed: Int, of ask: String = first) -> String { "\(ask)&offset=\(passed)" }

    private static func stretch(_ ids: [Int]) -> PageServer.Answer {
        PageServer.Answer(body: "[" + ids.map { #"{"id":"\#($0)","acct":"p\#($0)","display_name":"Person \#($0)"}"# }.joined(separator: ",") + "]")
    }

    private static let switchedOff = PageServer.Answer(body: #"{"error":"Not Found"}"#, status: 404)

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        let work = SourceWork()
        session.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server, work)
    }

    private func signIn(_ session: ShellSession) throws {
        try session.mastodon.tokens.save(MastodonToken(host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s"))
        session.mastodon.refresh()
    }

    private func ids(_ pages: ShellPeoplePages, _ session: ShellSession) -> [String] {
        pages.said(of: Self.directory, in: session)?.people.map(\.accountID) ?? []
    }

    private static var shell: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI/Shell")
    }

    // MARK: - What is asked, and when

    @Test("Opening a directory asks its source for one stretch — one ask, of eighty at most, in the order a source gives unasked, as the reader where they are signed in, listed in the run's record as a list of people, and nothing held — and the page is handed who it gave and how it is read; opened again, nobody is asked")
    func openingAsksOnceAsTheReader() async throws {
        let (session, server, work) = await session([Self.first: Self.stretch([3, 2, 1])])
        session.mastodon.work = work
        try signIn(session)
        let pages = ShellPersonPages().lists
        let before = try #require(pages.said(of: Self.directory, in: session))
        #expect(before == PeopleSaid(list: Self.directory, signedIn: true, sorting: DirectoryChoice()), "before anything answered")
        #expect(before.stateLine(language: .english) == "Asking m.example for its directory…")

        await pages.opened(Self.directory, in: session)
        #expect(await server.asked == [Self.first])
        #expect(await server.bearers == ["Bearer tok"], "as the reader: the source leaves out whom they block or mute")
        let acts = work.record.filter { $0.reached == Self.host }
        #expect(acts.count == 1 && acts.allSatisfy { $0.purpose == .people && $0.source == Self.host })

        let said = try #require(pages.said(of: Self.directory, in: session))
        #expect(said.reading == .said && said.people.map(\.accountID) == ["3", "2", "1"] && said.foot == .more && !said.asking)
        #expect(said.sorting == DirectoryChoice(order: .active, localOnly: false) && said.choosesSorting)
        #expect(said.stateLine() == nil && said.nothing() == nil && !said.offersAgain && said.short == nil)
        #expect(pages.walked(Self.directory, in: session) == said.people.map(\.id) && pages.canAskAgain(Self.directory, in: session))
        #expect(pages.person(said.people[0].id, on: Self.directory, in: session)?.accountID == "3")
        #expect(session.notes.isEmpty)
        #expect(await session.store.held(host: Self.host).isEmpty)

        await pages.opened(Self.directory, in: session)
        #expect(await server.asked.count == 1)
        // A directory is nobody's list: of no account, counted by nobody, hidden by nobody, and one page a source.
        #expect(Self.directory.isDirectory && Self.directory.asked == nil && Self.directory.counted == nil && !Self.directory.hidden)
        #expect(Self.directory.id == PeopleList(directoryAt: Self.host).id && PeopleSaid.counts(Self.directory) == nil)
        #expect(PeopleList.Which.ofSomebody == [.following, .followers])
    }

    @Test("Reading on is the foot's press, one stretch a press, from how many people were passed over and by nothing else; somebody who arrives twice is listed once; an empty stretch is the end, and nothing is asked past it; a second press while a stretch is out asks nothing")
    func readingOnIsPressedAndCounted() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2, 1]), Self.after(3): Self.stretch([1, 9]), Self.after(5): Self.stretch([]),
        ])
        let pages = ShellPersonPages().lists
        await pages.opened(Self.directory, in: session)
        await server.hold(Self.after(3))
        defer { Task { await server.release(Self.after(3)) } }
        let press = Task { await pages.readOn(Self.directory, in: session) }
        await server.arrival(of: Self.after(3))
        #expect(pages.said(of: Self.directory, in: session)?.foot == .reading)
        await pages.readOn(Self.directory, in: session)
        #expect(await server.asked == [Self.first, Self.after(3)], "one on the wire, and no second")
        await server.release(Self.after(3))
        await press.value
        #expect(ids(pages, session) == ["3", "2", "1", "9"] && pages.said(of: Self.directory, in: session)?.foot == .more)

        await pages.readOn(Self.directory, in: session)
        #expect(await server.asked.last == Self.after(5), "on from how many the source gave, not from how many are drawn")
        let said = try #require(pages.said(of: Self.directory, in: session))
        #expect(said.people.count == 4 && said.foot == .end && said.short == nil)
        #expect(said.footWords(.end, language: .english) == "No more people: m.example has sent all it gives.")
        await pages.readOn(Self.directory, in: session)
        #expect(await server.asked.count == 3, "nothing is asked past the end")

        // A last stretch that brought people and named no next is where reading stops, not the end.
        let stop = MastodonDirectory.furthest - 80
        let (far, _, _) = await self.session([Self.first: Self.stretch([1])])
        let reading = ShellPersonPages().lists
        reading.reachingDirectory = { source in
            MastodonDirectory(http: FixtureHTTP(["/api/v1/directory": .text("[" + (0..<80).map { #"{"id":"\#($0)","acct":"p\#($0)"}"# }.joined(separator: ",") + "]")]), host: source.host)
        }
        await reading.opened(Self.directory, in: far)
        #expect(reading.said(of: Self.directory, in: far)?.foot == .more && stop > 0)
    }

    @Test("With no sign-in a directory is asked for with no token; once the reader signs in, what nobody was given is let go and it is asked afresh as them; signed out again, afresh as nobody — and a not-found by the signed-in door makes it absent as one by the plain client does")
    func asWhoeverIsSignedIn() async throws {
        let (session, server, _) = await session([Self.first: Self.stretch([3, 2, 1])])
        let all = ShellPersonPages()
        let pages = all.lists
        await pages.opened(Self.directory, in: session)
        #expect(await server.bearers == [""] && pages.said(of: Self.directory, in: session)?.signedIn == false)

        try signIn(session)
        #expect(ids(pages, session).isEmpty, "nobody's directory is not the reader's")
        await pages.opened(Self.directory, in: session)
        #expect(await server.bearers == ["", "Bearer tok"] && ids(pages, session) == ["3", "2", "1"])
        await pages.opened(Self.directory, in: session)
        #expect(await server.asked.count == 2)

        _ = try session.mastodon.tokens.forget(try #require(try session.mastodon.tokens.token(host: Self.host)))
        session.mastodon.refresh()
        #expect(ids(pages, session).isEmpty, "nor the reader's anybody's")
        await pages.opened(Self.directory, in: session)
        #expect(await server.bearers == ["", "Bearer tok", ""])

        try signIn(session)
        await server.answer(Self.first, Self.switchedOff)
        await pages.opened(Self.directory, in: session)
        #expect(await server.bearers.last == "Bearer tok" && pages.said(of: Self.directory, in: session)?.reading == .absent)
        #expect(all.more.hosts.has(.directory, at: Self.host) == .absent && session.mastodon.ended.isEmpty)
    }

    @Test("A not-found that comes late, asked for before the person asked the host afresh and answered after, is written down nowhere — from a directory, from what is rising, and from what a host says of itself — and one asked for since is")
    func aNotFoundFromBeforeAskingAfresh() async throws {
        let (session, server, _) = await session([Self.first: Self.switchedOff])
        let all = ShellPersonPages()
        let hosts = all.more.hosts
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let out = Task { await all.lists.opened(Self.directory, in: session) }
        await server.arrival(of: Self.first)
        // "Ask again" on the source's page, while the directory's ask is out.
        hosts.askAfresh(Self.host)
        await server.release(Self.first)
        await out.value
        #expect(hosts.has(.directory, at: Self.host) == .unsaid, "heard from before the asking afresh")
        #expect(all.more.said(at: Self.host, in: session)?.directory == true)
        #expect(all.lists.said(of: Self.directory, in: session)?.reading == .absent, "the page says what its own ask heard")

        let before = hosts.round(at: Self.host)
        hosts.notFound(.activity, at: Self.host, round: before)
        #expect(hosts.has(.activity, at: Self.host) == .absent)
        hosts.askAfresh(Self.host)
        #expect(hosts.round(at: Self.host) == before + 1)
        hosts.notFound(.risingTags, at: Self.host, round: before)
        hosts.notFound(.knownServers, at: "M.Example", round: before)
        #expect(hosts.has(.risingTags, at: Self.host) == .unsaid && hosts.has(.knownServers, at: Self.host) == .unsaid)
        hosts.notFound(.risingTags, at: "M.Example", round: hosts.round(at: Self.host))
        #expect(hosts.has(.risingTags, at: Self.host) == .absent)
        for file in ["ShellRising.swift", "ShellSourceMore.swift", "ShellPeople.swift"] {
            let text = try String(contentsOf: Self.shell.appending(path: file), encoding: .utf8)
            #expect(text.contains("hosts.round(at:") && text.contains("hosts.notFound("), "\(file)")
            #expect(text.components(separatedBy: "hosts.notFound(").dropFirst().allSatisfy { $0.prefix(80).contains("round: round)") }, "\(file)")
        }
    }

    // MARK: - How it is read

    @Test("Choosing an order, or only the people who live there, asks from the top in the source's own word for it — one ask — and what comes replaces who stood; reading on then goes on that way; the choice the page already stands by asks nothing; and an ask for a choice that fails leaves the page, and its control, as they were")
    func choosingAsksFromTheTop() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2, 1]), Self.newest: Self.stretch([7, 8]), Self.after(2, of: Self.newest): Self.stretch([9]),
            Self.after(3): Self.stretch([4]),
        ])
        let pages = ShellPersonPages().lists
        await pages.opened(Self.directory, in: session)
        await pages.choose(DirectoryChoice(order: .active), for: Self.directory, in: session)
        #expect(await server.asked == [Self.first], "the way it is already read asks nothing")

        let new = DirectoryChoice(order: .new)
        await pages.choose(new, for: Self.directory, in: session)
        #expect(await server.asked == [Self.first, Self.newest])
        #expect(ids(pages, session) == ["7", "8"] && pages.said(of: Self.directory, in: session)?.sorting == new)
        await pages.readOn(Self.directory, in: session)
        #expect(await server.asked.last == Self.after(2, of: Self.newest) && ids(pages, session) == ["7", "8", "9"])
        // `r` asks from the top the way the page stands.
        await pages.again(Self.directory, in: session)
        #expect(await server.asked.last == Self.newest && ids(pages, session) == ["7", "8"])

        // Only the people who live there, in the order in force — which this source does not answer.
        let localNew = PeopleSaid.choosing(localOnly: true, from: new)
        #expect(localNew == DirectoryChoice(order: .new, localOnly: true))
        await pages.choose(localNew, for: Self.directory, in: session)
        #expect(await server.asked.last == Self.newest + "&local=true")
        let failed = try #require(pages.said(of: Self.directory, in: session))
        #expect(failed.sorting == new && failed.people.map(\.accountID) == ["7", "8"] && failed.againFailed && !failed.asking)
        #expect(failed.stateLine(language: .english) == "Could not ask m.example again. Who it gave before is still here.")
        #expect(failed.offersAgain && failed.choosesSorting)

        await pages.choose(PeopleSaid.choosing(.active, from: new), for: Self.directory, in: session)
        #expect(ids(pages, session) == ["3", "2", "1"] && pages.said(of: Self.directory, in: session)?.againFailed == false)
        await pages.readOn(Self.directory, in: session)
        #expect(await server.asked.last == Self.after(3))
        // A list of somebody's has no such choice, and choosing for one asks nobody.
        let followers = PeopleList(.followers, of: Person(source: Self.source, accountID: "42", handle: "@ada@m.example", name: "Ada"))
        let asked = await server.asked.count
        await pages.choose(new, for: followers, in: session)
        #expect(await server.asked.count == asked && pages.said(of: followers, in: session)?.sorting == nil)
    }

    @Test("A choice made while the directory is being asked asks nothing and changes nothing; a choice made while a stretch is being read on calls that stretch off, and what it brings late does not land")
    func chosenWhileOnTheWire() async throws {
        let (session, server, _) = await session([
            Self.first: Self.stretch([3, 2, 1]), Self.newest: Self.stretch([7, 8]), Self.after(3): Self.stretch([4, 5]),
        ])
        let pages = ShellPersonPages().lists
        // Wires that go on answering an ask that was called off.
        pages.reachingDirectory = { MastodonDirectory(http: server, host: $0.host) }
        let new = DirectoryChoice(order: .new)
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let opening = Task { await pages.opened(Self.directory, in: session) }
        await server.arrival(of: Self.first)
        #expect(pages.said(of: Self.directory, in: session)?.choosesSorting == false)
        await pages.choose(new, for: Self.directory, in: session)
        await pages.again(Self.directory, in: session)
        #expect(await server.asked == [Self.first] && pages.said(of: Self.directory, in: session)?.sorting == DirectoryChoice())
        await server.release(Self.first)
        await opening.value
        #expect(ids(pages, session) == ["3", "2", "1"])

        await server.hold(Self.after(3))
        defer { Task { await server.release(Self.after(3)) } }
        let reading = Task { await pages.readOn(Self.directory, in: session) }
        await server.arrival(of: Self.after(3))
        await pages.choose(new, for: Self.directory, in: session)
        let chosen = try #require(pages.said(of: Self.directory, in: session))
        #expect(chosen.people.map(\.accountID) == ["7", "8"] && chosen.foot == .more && chosen.sorting == new)
        await server.release(Self.after(3))
        await reading.value
        #expect(ids(pages, session) == ["7", "8"], "the stretch of the order before, come late, is nobody's")
        #expect(pages.said(of: Self.directory, in: session)?.foot == .more)

        // While a choice is being asked for, the control says the choice and takes no press; who stood stays drawn.
        await server.hold(Self.first)
        let back = Task { await pages.choose(DirectoryChoice(), for: Self.directory, in: session) }
        await server.arrival(of: Self.first, times: 2)
        let between = try #require(pages.said(of: Self.directory, in: session))
        #expect(between.sorting == DirectoryChoice() && between.asking && !between.choosesSorting)
        #expect(between.people.map(\.accountID) == ["7", "8"])
        await server.release(Self.first)
        await back.value
        #expect(ids(pages, session) == ["3", "2", "1"])
    }

    // MARK: - Where the host has none

    @Test("A directory is absent where the host says its address is not there: the page says so in one sentence, the run remembers it, the source's page stops offering the line, and opening it again asks nobody — until the person asks again, which asks the host afresh. An empty answer is a directory nobody is in, and a record that is not there or a failure is a failure: neither is ever absent")
    func absentByItsOwnAddress() async throws {
        let (session, server, _) = await session([Self.first: Self.switchedOff])
        let all = ShellPersonPages()
        let pages = all.lists
        #expect(all.more.said(at: Self.host, in: session)?.directory == true, "offered until the host says otherwise")
        await pages.opened(Self.directory, in: session)
        let absent = try #require(pages.said(of: Self.directory, in: session))
        #expect(absent.reading == .absent && absent.people.isEmpty && absent.foot == nil && !absent.asking)
        #expect(absent.stateLine(language: .english) == "m.example does not offer a directory of people.")
        #expect(absent.offersAgain && !absent.choosesSorting && absent.nothing() == nil)
        #expect(all.more.hosts.has(.directory, at: Self.host) == .absent)
        #expect(all.more.said(at: Self.host, in: session)?.directory == false)
        await pages.opened(Self.directory, in: session)
        await pages.choose(DirectoryChoice(order: .new), for: Self.directory, in: session)
        await pages.readOn(Self.directory, in: session)
        #expect(await server.asked == [Self.first], "absent: opened or chosen again, nobody is asked")

        // The person asks again and it fails another way: the page says that, and not that there is none.
        await server.answer(Self.first, PageServer.Answer(body: "", status: 500))
        await server.hold(Self.first)
        defer { Task { await server.release(Self.first) } }
        let retry = Task { await pages.again(Self.directory, in: session) }
        await server.arrival(of: Self.first, times: 2)
        #expect(pages.said(of: Self.directory, in: session)?.reading == .asking, "while the ask is out, nothing is said of what was heard before")
        await server.release(Self.first)
        await retry.value
        #expect(pages.said(of: Self.directory, in: session)?.reading == .failed && all.more.hosts.has(.directory, at: Self.host) == .unsaid)
        #expect(await server.asked == [Self.first, Self.first])
        await server.answer(Self.first, Self.switchedOff)
        await pages.again(Self.directory, in: session)
        #expect(pages.said(of: Self.directory, in: session)?.reading == .absent)

        // The person asks again: the host is asked afresh, and has one now.
        await server.answer(Self.first, Self.stretch([3, 2, 1]))
        await pages.again(Self.directory, in: session)
        #expect(await server.asked.count == 4 && ids(pages, session) == ["3", "2", "1"])
        #expect(all.more.hosts.has(.directory, at: Self.host) == .unsaid && all.more.said(at: Self.host, in: session)?.directory == true)
        // Switched off between two stretches: nobody it gave before is drawn as its directory.
        await server.answer(Self.after(3), Self.switchedOff)
        await pages.readOn(Self.directory, in: session)
        let gone = try #require(pages.said(of: Self.directory, in: session))
        #expect(gone.reading == .absent && gone.people.isEmpty && all.more.hosts.has(.directory, at: Self.host) == .absent)
        // Asked afresh from the source's own page, the directory is asked for when next opened.
        await server.answer(Self.first, Self.stretch([]))
        all.more.hosts.askAfresh(Self.host)
        let heard = try #require(pages.said(of: Self.directory, in: session))
        #expect(heard.reading == .absent && !heard.asking, "what this page last heard stands: nothing is left asking with nothing on the wire")
        await pages.opened(Self.directory, in: session)
        let empty = try #require(pages.said(of: Self.directory, in: session))
        #expect(empty.reading == .said && empty.foot == nil && !empty.offersAgain)
        #expect(empty.nothing(language: .english) == "m.example gave nobody from its directory.")
        #expect(all.more.hosts.has(.directory, at: Self.host) == .unsaid, "nobody listed is never a directory switched off")

        for refusal in [PageServer.Answer(body: #"{"error":"Record not found"}"#, status: 404), PageServer.Answer(body: "", status: 500), nil] {
            let (other, failing, _) = await self.session(refusal.map { [Self.first: $0] } ?? [:])
            let fresh = ShellPersonPages()
            await fresh.lists.opened(Self.directory, in: other)
            let failed = try #require(fresh.lists.said(of: Self.directory, in: other))
            #expect(failed.reading == .failed && failed.offersAgain && fresh.more.hosts.has(.directory, at: Self.host) == .unsaid)
            #expect(failed.stateLine(language: .english) == "Could not ask m.example for its directory.")
            #expect(fresh.more.said(at: Self.host, in: other)?.directory == true)
            #expect(await failing.asked == [Self.first])
        }
    }

    /// Hands out the wires of a test one at a time, in order: the first ask's, then the next's.
    @MainActor
    private final class Wires {
        var servers: [PageServer]
        init(_ servers: [PageServer]) { self.servers = servers }
        func next() -> PageServer { servers.count > 1 ? servers.removeFirst() : servers[0] }
    }

    @Test("A not-found that comes late makes nothing absent: asked for by a page since let go — its reader changed — it is written down nowhere, and the directory asked for since stands")
    func aLateNotFoundMakesNothingAbsent() async throws {
        let (session, _, _) = await session([:])
        let off = PageServer([Self.first: Self.switchedOff]), on = PageServer([Self.first: Self.stretch([3, 2])])
        let all = ShellPersonPages()
        let pages = all.lists
        let wires = Wires([off, on])
        pages.reachingDirectory = { MastodonDirectory(http: wires.next(), host: $0.host) }
        await off.hold(Self.first)
        defer { Task { await off.release(Self.first) } }
        let before = Task { await pages.opened(Self.directory, in: session) }
        await off.arrival(of: Self.first)

        try signIn(session)
        await pages.opened(Self.directory, in: session)
        #expect(ids(pages, session) == ["3", "2"])
        await off.release(Self.first)
        await before.value
        let late = await off.asked, since = await on.asked
        #expect(late == [Self.first] && since == [Self.first])
        #expect(all.more.hosts.has(.directory, at: Self.host) == .unsaid, "the late answer was nobody's")
        let said = try #require(pages.said(of: Self.directory, in: session))
        #expect(said.reading == .said && said.people.count == 2 && all.more.said(at: Self.host, in: session)?.directory == true)
    }

    @Test("An ask that was stopped before it answered leaves a directory that is asked again when it is opened, and never one that says Asking for the rest of the run")
    func aStoppedAskIsAskedAgain() async throws {
        let (session, server, _) = await session([Self.first: PageServer.Answer(body: "", cancelled: true)])
        let pages = ShellPersonPages().lists
        await pages.opened(Self.directory, in: session)
        let left = try #require(pages.said(of: Self.directory, in: session))
        #expect(left.reading == .asking && !left.asking && left.choosesSorting && left.sorting == DirectoryChoice())
        await server.answer(Self.first, Self.stretch([3]))
        await pages.opened(Self.directory, in: session)
        #expect(ids(pages, session) == ["3"])
        #expect(await server.asked == [Self.first, Self.first])
    }

    // MARK: - Under a ceiling, of its own host

    @Test("A directory is read under the small body's ceiling, put on the client that sends before it is listed and bounded, and kept to the host it is asked at: a stretch past the ceiling is refused, and the live client that would send is the capped one that follows nothing off its origin")
    func readSmallAndOfItsHost() async throws {
        let big = #"[{"id":"1","acct":"a","note":"\#(String(repeating: "w", count: SourceReach.smallBody))"}]"#
        let http = FixtureHTTP(["/api/v1/directory": .text(big)])
        let work = SourceWork()
        let reader = SourceReach(http: http, work: work).unsignedDirectory(Self.host, for: .people, within: .seconds(5))
        await #expect(throws: URLError.self) { _ = try await reader.stretch(source: Self.source) }
        #expect(work.record.map(\.purpose) == [.people], "refused, and listed all the same")

        let sent = try #require(SourceReach.smallAtItsHost(URLSessionClient()) as? URLSessionClient)
        #expect(sent.byteLimit == SourceReach.smallBody && sent.sameOriginOnly)
        let reach = try String(contentsOf: Self.shell.appending(path: "SourceReach.swift"), encoding: .utf8)
        #expect(reach.contains("MastodonDirectory(http: wire(Self.smallAtItsHost(http), for: purpose, within: limit), host: host)"))
    }

    // MARK: - Where it is opened from, and a forum

    @Test("The line that opens a directory is drawn on a source's page only where somebody answers its press and the host has not said it has none; its press takes the sheet down and hands over that source's directory, a step of the walk like any list of people")
    func theLineOnTheSourcesPage() async throws {
        let (session, server, _) = await session([:])
        func height(_ said: SourceMoreSaid, opens: Bool) -> CGFloat {
            let block = VStack(spacing: 0) { SourceMoreSection(said: said, onDirectory: opens ? {} : nil) }.frame(width: 460)
            let hosted = NSHostingView(rootView: block)
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize.height
        }
        let offered = SourceMoreSaid(source: Self.host, account: .waiting, servers: nil, weeks: .waiting)
        var absent = offered
        absent.directory = false
        #expect(height(offered, opens: true) > height(offered, opens: false))
        #expect(height(absent, opens: true) == height(offered, opens: false), "absent: no line, not a dim one")
        // Offered none of the three, the directory alone is a thing the page offers.
        let none = SourceMoreSaid(source: Self.host, account: nil, servers: nil, weeks: nil)
        #expect(!none.isAbsent(opensDirectory: true) && none.isAbsent(opensDirectory: false))
        var bare = none
        bare.directory = false
        #expect(bare.isAbsent(opensDirectory: true))
        #expect(SourceMoreSaid.directoryLabel(language: .english) == "Its directory of people")
        #expect(SourceMoreSaid.directoryHint(language: .english) == "Closes this page and opens the directory.")

        var opened: [PeopleList] = []
        let sheet = JoinSheet(session: session, onDirectory: { opened.append($0) })
        #expect(JoinSheet(session: session).directoryPress(at: Self.host) == nil, "nobody to answer: no line")
        let press = try #require(sheet.directoryPress(at: Self.host))
        press()
        #expect(opened == [Self.directory] && session.stage == nil)
        var walk = ShellWalk()
        let stepped = walk.walk(to: .people(Self.directory), from: "row")
        #expect(stepped && walk.openedPeople == Self.directory)
        let errand = PlaceErrand.setOut(to: .people(Self.directory), from: .account, on: &walk, lamp: nil)
        #expect(errand == nil, "already there: no second step")
        #expect(await server.asked.isEmpty, "nothing is asked by drawing the line or pressing it: the page asks as it opens")
    }

    @Test("A forum has no directory: its page is handed no block and no line, nothing is asked of it by opening, asking again, choosing or reading on — and the page, the row and the block name no kind of source")
    func aForumHasNone() async throws {
        let (session, server, work) = await session([:])
        let all = ShellPersonPages()
        let list = PeopleList(directoryAt: Self.forum.host)
        #expect(all.lists.said(of: list, in: session) == nil && all.more.said(at: Self.forum.host, in: session) == nil)
        await all.lists.opened(list, in: session)
        await all.lists.again(list, in: session)
        await all.lists.choose(DirectoryChoice(order: .new), for: list, in: session)
        await all.lists.readOn(list, in: session)
        #expect(all.lists.walked(list, in: session).isEmpty && !all.lists.canAskAgain(list, in: session))
        #expect(await server.asked.isEmpty && work.record.isEmpty)
        func height<Block: View>(_ block: Block) -> CGFloat {
            let hosted = NSHostingView(rootView: VStack(spacing: 0) { block }.frame(width: 460))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize.height
        }
        #expect(height(SourceMoreBlock(host: Self.forum.host, more: all.more, session: session, onDirectory: {})) == 0)

        for file in ["PeoplePane.swift", "PersonRow.swift", "SourceMore.swift"] {
            let text = try String(contentsOf: Self.shell.appending(path: file), encoding: .utf8)
            for word in ["ProtocolKind", ".kind ", ".kind)", ".kind.", "isForum", ".mastodon", ".discuz", ".discourse", "offers."] {
                #expect(!text.contains(word), "\(file) names \(word)")
            }
        }
        let sheet = try String(contentsOf: Self.shell.appending(path: "JoinSheet.swift"), encoding: .utf8)
        let press = try #require(sheet.range(of: "func directoryPress"))
        let body = sheet[press.lowerBound...].prefix(400)
        #expect(!body.contains(".kind") && !body.contains("offers."), "the press decides nothing by the kind of source")
    }

    // MARK: - What the page says

    @Test("The head of a directory says whose it is and, in one sentence, how it is being read; the control names the two orders a source takes and the people who live there; where it gave nobody the page says so of the source, and of the people who live there where only they were asked for")
    func theWords() {
        #expect(PeopleSaid.title(Self.directory, language: .english) == "The directory of m.example")
        #expect(DirectoryOrder.allCases.map { PeopleSaid.orderName($0, language: .english) } == ["Recently active", "Newest"])
        #expect(PeopleSaid.localName("m.example", language: .english) == "Only people who live on m.example")
        #expect(PeopleSaid.sortingLine(DirectoryChoice(), source: "m.example", language: .english) == "People m.example lists, whoever posted most recently first.")
        #expect(PeopleSaid.sortingLine(DirectoryChoice(order: .new), source: "m.example", language: .english) == "People m.example lists, whoever is newest there first.")
        #expect(PeopleSaid.sortingLine(DirectoryChoice(localOnly: true), source: "m.example", language: .english) == "Only people who live on m.example, whoever posted most recently first.")
        #expect(PeopleSaid.sortingLine(DirectoryChoice(order: .new, localOnly: true), source: "m.example", language: .taiwanese) == "只列住在 m.example 的人，最新到那裡的排在前面。")
        var said = PeopleSaid(list: Self.directory, reading: .said, sorting: DirectoryChoice(localOnly: true))
        #expect(said.nothing(language: .english) == "m.example gave nobody who lives there from its directory.")
        said.reading = .failed
        #expect(said.stateLine(language: .english) == "Could not ask m.example for its directory." && said.nothing() == nil)
        // Read as far as a directory is read: said as that, and never as the source having no more.
        let far = PeopleSaid(list: Self.directory, reading: .said, people: [], foot: .farthest, sorting: DirectoryChoice())
        #expect(far.footWords(.farthest, language: .english) == "Fediqo reads the first 0 people of a directory. m.example may list more.")
        #expect(!PeopleSaid.Foot.farthest.presses)
        said.reading = .absent
        #expect(said.stateLine(language: .taiwanese) == "m.example 沒有提供人的名錄。")
        // A list of somebody's says what it said before.
        let followers = PeopleList(.followers, of: Person(source: Self.source, accountID: "42", handle: "@ada@m.example", name: "Ada"))
        #expect(PeopleSaid(list: followers).stateLine(language: .english) == "Asking m.example for this list…")
        #expect(PeopleSaid.title(followers, language: .english) == "Who follows @ada@m.example")
    }

    @Test("Every sentence of a directory is written in each language the app speaks, with the places it fills, and the two Chinese tables alike")
    func writtenInEveryLanguage() throws {
        let resources = Self.shell.deletingLastPathComponent().appending(path: "Resources")
        let english = try String(contentsOf: resources.appending(path: "en.lproj/Localizable.strings"), encoding: .utf8)
        let keys = english.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\"people.directory.") || line.hasPrefix("\"people.title.directory\"") || line.hasPrefix("\"source.more.directory") else { return nil }
            return line.dropFirst().split(separator: "\"").first.map(String.init)
        }
        #expect(keys.count == 17 && keys.contains("people.directory.none.local") && keys.contains("source.more.directory.hint"))
        func places(_ text: String) -> [String] {
            text.matches(of: /%(\d\$)?[@d]/).map { String($0.output.0) }.sorted()
        }
        for key in keys {
            let written = L10n.t(key, language: .english)
            #expect(written != key && !written.contains("%d") && !written.contains("$d"), "\(key)")
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

    @Test("The page of a directory is laid out to the width it is given and never past it, in light and in dark, in each state it has: asking, people, nobody, a failure and absent — and its head, which holds the control, is as wide as the page at the narrowest")
    func thePageLaidOut() {
        func size<Page: View>(_ page: Page, _ width: CGFloat, _ scheme: ColorScheme) -> CGSize {
            let hosted = NSHostingView(rootView: page.frame(width: width).environment(\.colorScheme, scheme))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize
        }
        let people = (1...3).map { Person(source: Self.source, accountID: "\($0)", handle: "@p\($0)@m.example", name: "Person \($0)") }
        var states = [PeopleSaid(list: Self.directory, sorting: DirectoryChoice())]
        states.append(PeopleSaid(list: Self.directory, reading: .said, people: people, foot: .more, sorting: DirectoryChoice(order: .new, localOnly: true)))
        states.append(PeopleSaid(list: Self.directory, reading: .said, sorting: DirectoryChoice(localOnly: true)))
        states.append(PeopleSaid(list: Self.directory, reading: .failed, sorting: DirectoryChoice()))
        states.append(PeopleSaid(list: Self.directory, reading: .absent, sorting: DirectoryChoice()))
        states.append(PeopleSaid(list: Self.directory, reading: .said, againFailed: true, people: people, asking: true, foot: .end, sorting: DirectoryChoice()))
        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (390, .dark), (320, .light), (320, .dark)] {
            for said in states {
                let pane = PeoplePane(said: said, selectedID: .constant(nil), onOpen: { _ in }, onBack: {})
                #expect(size(pane, width, scheme).width == width, "\(said.reading) at \(width)")
                let head = PeopleHead(list: said.list, sorting: said.sorting, chooses: said.choosesSorting)
                let drawn = size(head, width, scheme)
                #expect(drawn.width == width && drawn.height > 0)
            }
            let long = PeopleList(directoryAt: "a-rather-long-name-of-a-server.a-rather-long-instance-name.example")
            #expect(size(PeopleHead(list: long, sorting: DirectoryChoice(order: .new, localOnly: true)), width, scheme).width == width)
        }
    }
}
