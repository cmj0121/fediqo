import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// Two sources behind one client, each its own `PageServer`: an ask goes to the server of the
/// host it names, and to nobody where no source is of that host.
struct ServersByHost: HTTPClient, HTTPSender {
    let servers: [String: PageServer]

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(URLRequest(url: url))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let server = servers[request.url?.host() ?? ""] else { throw URLError(.cannotFindHost) }
        return try await server.send(request)
    }
}

/// #320, the two pages: what is asked of each source for the hashtags and the links rising on
/// it, when, what the pages are handed and say in each state — one band a source, never merged
/// — and that a source which is not asked who people are has no band, and is asked nothing.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), tied to the work that
/// made the ask where a check can name it: a held ask is let go by the check, and by a guard
/// when the run has gone still; every deadline is on a clock nobody turns.
@MainActor
@Suite("The hashtags and links rising on the sources", .serialized, .watched)
struct RisingTests {
    private static let one = "m.example", two = "n.example"
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let tags = "/api/v1/trends/tags?limit=20"
    private static let links = "/api/v1/trends/links?limit=20"

    private static func tagsAnswer(_ names: [String], uses: Int = 12) -> PageServer.Answer {
        PageServer.Answer(body: "[" + names.map {
            #"{"name":"\#($0)","history":[{"day":"1700086400","accounts":"\#(uses)","uses":"\#(uses * 2)"},{"day":"1700000000","accounts":"3","uses":"4"}]}"#
        }.joined(separator: ",") + "]")
    }

    private static let story = PageServer.Answer(body: #"""
    [{"url":"https://far.example/story","title":"A story","description":"What it says.","image":"https://tracker.example/p.png",
      "history":[{"day":"1700086400","accounts":"20","uses":"21"}]}]
    """#)
    private static let none = PageServer.Answer(body: "[]")
    private static let off = PageServer.Answer(body: #"{"error":"Not Found"}"#, status: 404)

    private static func tag(_ name: String, at source: String, people: Int = 15, posts: Int = 28) -> RisingRow {
        .tag(RisingTag(tag: PostTag("#" + name)!, use: RisingUse(posts: posts, people: people, days: 2)), source: source)
    }

    /// A session of two sources that say who people are and a forum, each with a server of its own.
    private func session(
        _ first: [String: PageServer.Answer], _ second: [String: PageServer.Answer] = [:], sources: [Source]? = nil
    ) async -> (ShellSession, [String: PageServer], SourceWork) {
        let servers = [Self.one: PageServer(first), Self.two: PageServer(second), Self.forum.host: PageServer([:])]
        let router = ServersByHost(servers: servers)
        let session = ShellSession(
            http: router, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: router)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        let joined = sources ?? [Source(host: Self.one, kind: .mastodon), Source(host: Self.two, kind: .mastodon), Self.forum]
        for source in joined { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, servers, work)
    }

    private func signIn(_ session: ShellSession, at host: String = one) throws {
        try session.mastodon.tokens.save(MastodonToken(host: host, accessToken: "tok", clientID: "c", clientSecret: "s"))
        session.mastodon.refresh()
    }

    private func bands(_ rising: ShellRising, _ which: RisingWhich, _ session: ShellSession) -> [RisingSaid.Band] {
        rising.said(which, in: session)?.bands ?? []
    }

    // MARK: - What is asked, and when

    @Test("Opening the rising hashtags asks each source that has them for one stretch of twenty — one ask a source, with no sign-in, listed in the run's record under that source — and the page is handed one band a source, in the order the sources stand, each with its own rows in its own order: the same hashtag on two sources is two rows, never one. Opened again, nobody is asked; the links are a page of their own; and a forum has no band")
    func openingAsksEachSourceOnce() async throws {
        let (session, servers, work) = await session(
            [Self.tags: Self.tagsAnswer(["Swift", "birds"]), Self.links: Self.story], [Self.tags: Self.tagsAnswer(["swift"], uses: 2), Self.links: Self.none]
        )
        let rising = ShellPersonPages().rising
        #expect(bands(rising, .tags, session) == [RisingSaid.Band(source: Self.one), RisingSaid.Band(source: Self.two)], "before anything answered")
        #expect(bands(rising, .tags, session).allSatisfy { $0.stateLine(.tags) == nil }, "being asked is the tab's toast to say")

        await rising.opened(.tags, in: session)
        for host in [Self.one, Self.two] {
            #expect(await servers[host]?.asked == [Self.tags])
            #expect(await servers[host]?.bearers == [""])
        }
        #expect(await servers[Self.forum.host]?.asked.isEmpty == true)
        #expect(work.record.map(\.reached).sorted() == [Self.one, Self.two] && work.record.allSatisfy { $0.purpose == .rising && $0.source == $0.reached })

        let said = try #require(rising.said(.tags, in: session))
        #expect(said.bands.map(\.source) == [Self.one, Self.two] && said.bands.allSatisfy { $0.reading == .said && !$0.asking })
        #expect(said.bands[0].rows == [Self.tag("Swift", at: Self.one), Self.tag("birds", at: Self.one)])
        #expect(said.bands[1].rows == [Self.tag("swift", at: Self.two, people: 5, posts: 8)])
        #expect(Set(said.rows.map(\.id)).count == 3 && rising.walked(.tags, in: session) == said.rows.map(\.id))
        #expect(rising.row(said.rows[2].id, of: .tags, in: session) == said.rows[2] && rising.row("nothing", of: .tags, in: session) == nil)
        #expect(rising.row(said.rows[0].id, of: .links, in: session) == nil, "a row of one page is none of the other's")
        #expect(session.notes.isEmpty)

        await rising.opened(.tags, in: session)
        #expect(await servers[Self.one]?.asked.count == 1)
        // The links: asked where they are, when their own page opens.
        await rising.opened(.links, in: session)
        #expect(await servers[Self.one]?.asked == [Self.tags, Self.links])
        let links = try #require(rising.said(.links, in: session))
        guard case .link(let link, let source) = try #require(links.bands[0].rows.first) else {
            Issue.record("the link's row is no link")
            return
        }
        #expect(source == Self.one && link.link.host == "far.example" && link.title == "A story" && link.use == RisingUse(posts: 21, people: 20, days: 1))
        #expect(links.bands[1].rows.isEmpty && links.bands[1].stateLine(.links, language: .english) == "n.example gave no rising links.")
        // Listing a link fetches nothing of it: every ask of the run went to a source, and none to the page or its picture.
        #expect(Set(work.record.map(\.reached)) == [Self.one, Self.two])
    }

    @Test("A source that fails is named in the tab's toast while the others land; asking one source again asks it and no other, and asking again from the keys asks every source; a source that gave none says it gave none — never that it has none or that it is switched off")
    func oneFailsAndTheOthersLand() async throws {
        let (session, servers, _) = await session([Self.tags: PageServer.Answer(body: "", status: 503)], [Self.tags: Self.none])
        let rising = ShellPersonPages().rising
        await rising.opened(.tags, in: session)
        let said = bands(rising, .tags, session)
        #expect(said[0].reading == .failed && said[0].rows.isEmpty && said[0].stateLine(.tags) == nil)
        #expect(rising.ask(of: .tags, in: session) == PageAsking(failed: [Self.one]), "the miss is the toast's, and nobody else's")
        #expect(TimelineToast.asked(rising.ask(of: .tags, in: session), note: nil, language: .english) == TimelineToast(kind: .error, text: "Could not reload m.example."))
        #expect(said[1].reading == .said && said[1].stateLine(.tags, language: .english) == "n.example gave no rising hashtags.")
        for language in DummyLanguage.allCases {
            let line = try #require(said[1].stateLine(.tags, language: language)).lowercased()
            #expect(!line.contains("switched") && !line.contains("關閉") && !line.contains("停用"), "\(line)")
        }
        // Opened again, a failure stands: it is asked again by the person, not by the page.
        await rising.opened(.tags, in: session)
        #expect(await servers[Self.one]?.asked.count == 1)

        await servers[Self.one]?.answer(Self.tags, Self.tagsAnswer(["birds"]))
        await rising.again(.tags, at: Self.one, in: session)
        #expect(await servers[Self.one]?.asked.count == 2)
        #expect(await servers[Self.two]?.asked.count == 1, "one source asked again asks that source")
        #expect(rising.ask(of: .tags, in: session).failed.isEmpty)
        #expect(bands(rising, .tags, session)[0].rows == [Self.tag("birds", at: Self.one)])
        await rising.again(.tags, in: session)
        #expect(await servers[Self.one]?.asked.count == 3)
        #expect(await servers[Self.two]?.asked.count == 2)
    }

    @Test("A source is left out of a page only where its own address answered that it is not there: that is remembered for the run, for that page and not the other, and the source is not asked for it again; with every source left out there is no page")
    func absentOnlyByItsOwnAddress() async throws {
        let (session, servers, _) = await session([Self.tags: Self.none, Self.links: Self.none], [Self.tags: Self.none, Self.links: Self.off])
        let pages = ShellPersonPages()
        let rising = pages.rising
        await rising.opened(.links, in: session)
        #expect(bands(rising, .links, session).map(\.source) == [Self.one])
        #expect(pages.more.hosts.has(.risingLinks, at: Self.two) == .absent && pages.more.hosts.has(.risingTags, at: Self.two) == .unsaid)
        #expect(pages.more.hosts.has(.risingLinks, at: Self.one) == .unsaid, "an empty answer makes nothing absent")
        await rising.opened(.links, in: session)
        await rising.again(.links, at: Self.one, in: session)
        #expect(await servers[Self.two]?.asked == [Self.links], "what is absent is not asked for again by opening, or by another's Try again")
        // `r` is the person's reload: a source left out is asked afresh, and is there if it now gives.
        await servers[Self.two]?.answer(Self.links, Self.story)
        #expect(rising.canAskAgain(.links, in: session))
        await rising.again(.links, in: session)
        #expect(await servers[Self.two]?.asked == [Self.links, Self.links])
        #expect(bands(rising, .links, session).map(\.source) == [Self.one, Self.two] && bands(rising, .links, session)[1].rows.count == 1)
        #expect(bands(rising, .tags, session).map(\.source) == [Self.one, Self.two])

        let (bare, _, _) = await self.session([Self.links: Self.off], sources: [Source(host: Self.one, kind: .mastodon)])
        let alone = ShellPersonPages().rising
        await alone.opened(.links, in: bare)
        #expect(alone.said(.links, in: bare) == nil && alone.canAskAgain(.links, in: bare), "nothing to draw, and somebody to ask afresh")
    }

    // MARK: - While an ask is out

    @Test("An ask is the pages' and not the pane's: the pane leaving does not stop it and it lands for the next visit; opening again, or asking again, while a source is being asked asks it nothing more — and the source beside it is not kept waiting")
    func theAskOutlivesThePane() async throws {
        let (session, servers, _) = await session([Self.tags: Self.tagsAnswer(["birds"])], [Self.tags: Self.tagsAnswer(["maps"])])
        let first = try #require(servers[Self.one])
        let rising = ShellPersonPages().rising
        await first.hold(Self.tags)
        defer { Task { await first.release(Self.tags) } }
        let firstTagsGuard = watching("the ask of \(Self.tags), held at its server") { await first.release(Self.tags) }
        defer { firstTagsGuard.cancel() }
        let pane = Task { await rising.opened(.tags, in: session) }
        await first.arrival(of: Self.tags, by: pane)
        // No `by:`: the pane that asks the source beside it is held on the first, and ends after.
        let second = try #require(servers[Self.two])
        await met("the source beside the held one is asked") { await second.arrivals(of: Self.tags) >= 1 }
        pane.cancel()
        let again = Task { await rising.opened(.tags, in: session) }
        await rising.again(.tags, at: Self.one, in: session)
        #expect(await first.asked.count == 1, "a press while the source is being asked asks nothing")
        #expect(rising.canAskAgain(.tags, in: session) && rising.canAskAgain(.links, in: session), "the mark keeps its place while the page's asks are out")
        // And it is Stop meanwhile: `r`'s answer and the tab's own wait, as the head's mark reads them.
        let canReload = FediqoRootView.canReload(
            place: .trends, editing: false, hasSources: true, open: [], risingAsked: rising.canAskAgain(.tags, in: session)
        )
        #expect(ReloadMark.shown(canReload: canReload, stoppable: rising.ask(of: .tags, in: session).stoppable) == .stop)
        let midway = bands(rising, .tags, session)
        #expect(midway[0].asking && midway[0].reading == .asking && midway[0].stateLine(.tags) == nil)
        // The source beside is asked and answers on its own wire: waited on to land, so the toast
        // names the held one alone.
        await met("the source beside the held one has answered") { !bands(rising, .tags, session)[1].asking }
        #expect(rising.ask(of: .tags, in: session, language: .english).asking == "Asking m.example…", "the toast says who is on the wire")
        await first.release(Self.tags)
        await again.value
        await pane.value
        #expect(rising.canAskAgain(.tags, in: session))
        let landed = bands(rising, .tags, session)
        #expect(landed.map(\.rows.count) == [1, 1] && landed.allSatisfy { !$0.asking && $0.reading == .said })
        #expect(await first.asked.count == 1)
        #expect(await servers[Self.two]?.asked.count == 1)
    }

    @Test("An ask that was stopped before it answered leaves nothing saying Asking: its band says nothing, it is no failure, and it is asked again when the page next opens")
    func aStoppedAskIsAskedAgain() async throws {
        let (session, servers, _) = await session([Self.tags: PageServer.Answer(body: "", cancelled: true)], [Self.tags: Self.none])
        let rising = ShellPersonPages().rising
        await rising.opened(.tags, in: session)
        let stopped = bands(rising, .tags, session)[0]
        #expect(stopped.reading == .stopped && !stopped.asking && stopped.stateLine(.tags) == nil)
        #expect(rising.ask(of: .tags, in: session).failed.isEmpty)
        await servers[Self.one]?.answer(Self.tags, Self.tagsAnswer(["birds"]))
        await rising.opened(.tags, in: session)
        #expect(bands(rising, .tags, session)[0].rows.count == 1)
        #expect(await servers[Self.two]?.asked.count == 1, "the source that answered is not asked again")
    }

    @Test("Stop on a tab of what is rising calls off every source of it on the wire: the toast says each was asked and then that the reload stopped — never a failure — what comes late lands nowhere, the other tab and nothing else is touched, and asking again says nothing of the stop")
    func stopCallsTheTabOff() async throws {
        let (session, servers, _) = await session([Self.tags: Self.tagsAnswer(["Swift"])], [Self.tags: Self.tagsAnswer(["birds"])])
        let first = try #require(servers[Self.one]), second = try #require(servers[Self.two])
        let rising = ShellPersonPages().rising
        #expect(!rising.stop(.tags), "nothing on the wire: nothing stopped")
        for server in [first, second] { await server.hold(Self.tags) }
        defer { Task { for server in [first, second] { await server.release(Self.tags) } } }
        let heldGuard = watching("the asks of \(Self.tags), held at their servers") {
            for server in [first, second] { await server.release(Self.tags) }
        }
        defer { heldGuard.cancel() }
        let pane = Task { await rising.opened(.tags, in: session) }
        await first.arrival(of: Self.tags, by: pane)
        await second.arrival(of: Self.tags, by: pane)
        let asking = rising.ask(of: .tags, in: session, language: .english)
        #expect(asking == PageAsking(asking: "Asking m.example… +1", stoppable: true), "both on the wire, the first named")
        #expect(TimelineToast.asked(asking, note: nil)?.kind == .loading)

        #expect(rising.stop(.tags))
        let stopped = rising.ask(of: .tags, in: session)
        #expect(stopped == PageAsking(stopped: true), "nothing on the wire, no failure, and the stop said")
        #expect(TimelineToast.asked(stopped, note: nil, language: .english) == TimelineToast(kind: .warning, text: "Reload stopped."))
        #expect(rising.ask(of: .links, in: session) == PageAsking(), "the other tab is not this one's")
        #expect(rising.canAskAgain(.tags, in: session), "stopped, it may be asked again")
        for server in [first, second] { await server.release(Self.tags) }
        await pane.value
        #expect(bands(rising, .tags, session).allSatisfy { $0.rows.isEmpty && $0.reading == .stopped }, "what came late landed nowhere")

        await rising.again(.tags, in: session)
        #expect(rising.ask(of: .tags, in: session) == PageAsking(), "asked again, the stop is said no longer")
        #expect(bands(rising, .tags, session).map(\.rows.count) == [1, 1])
    }

    @Test("Whose ask is in front is one decision — the toast's, the mark's and Escape's: a page opened over the stream asks for itself, a hashtag's page too, a list whose source is gone draws the stream and is not, a conversation is the stream's, and on Trends with nothing over it a tab of what is rising is; Stop there stops that tab and nothing else")
    func whoseAskIsInFront() async throws {
        let (session, servers, _) = await session([Self.tags: Self.none], [Self.tags: Self.none])
        let pages = ShellPersonPages()
        let ada = try #require(DummyPerson(handle: "@ada@m.example", host: Self.one))
        let list = PeopleList(directoryAt: Self.one)
        func front(_ step: ShellStep?, _ rising: RisingWhich? = nil) -> TimelinePane.AskInFront? {
            TimelinePane.askInFront(step, rising: rising, of: pages, in: session)
        }
        #expect(front(.person(ada), .tags) == .person(ada), "the page over Trends' tab, and not the tab")
        #expect(front(.people(list), .tags) == .people(list))
        #expect(front(.people(PeopleList(directoryAt: "gone.example")), .tags) == .rising(.tags), "undrawn, the stream's place is in front")
        #expect(front(.followedTags(FollowedTags(host: Self.one))) == nil, "nobody signed in: the stream is drawn in its stead")
        let birds = try #require(PostTag("#birds"))
        #expect(front(.thread("nowhere")) == nil && front(.tag(birds), .tags) == .tag(birds))
        #expect(front(nil) == nil, "the stream: its own reload")
        #expect(front(nil, .links) == .rising(.links))
        #expect(TimelinePane.askInFront(.person(ada), rising: nil, of: nil, in: session) == nil, "with no pages, nobody's")

        let first = try #require(servers[Self.one])
        await first.hold(Self.tags)
        defer { Task { await first.release(Self.tags) } }
        let heldGuard = watching("the ask of \(Self.tags), held at its server") { await first.release(Self.tags) }
        defer { heldGuard.cancel() }
        let tab = Task { await pages.rising.opened(.tags, in: session) }
        await first.arrival(of: Self.tags, by: tab)
        #expect(TimelinePane.ask(.rising(.tags), of: pages, in: session).stoppable)
        #expect(!TimelinePane.stop(.person(ada), of: pages, in: session), "another page's Stop stops nothing here")
        #expect(TimelinePane.stop(.rising(.tags), of: pages, in: session))
        #expect(TimelinePane.ask(.rising(.tags), of: pages, in: session).stopped && !session.reload.stopped, "the stream's reload is not told")
        #expect(TimelinePane.banner(TimelinePane.ask(.quiet, of: pages, in: session), note: nil, in: session) == nil, "a page that asks nothing says nothing")
        await first.release(Self.tags)
        await tab.value
    }

    @Test("What was asked as one sign-in is not shown to the next, and its answer, come late, lands nowhere — rows, or a word that the address is not there: the band is the reader's who asked since, whose own ask is still out; and a sign-in at one source lets nothing of another go")
    func asWhoeverAsked() async throws {
        for late in [Self.tagsAnswer(["old"]), Self.off] {
            let (session, servers, _) = await session([Self.tags: late], [Self.tags: Self.tagsAnswer(["maps"])])
            let first = try #require(servers[Self.one])
            let pages = ShellPersonPages()
            let rising = pages.rising
            // A wire that goes on answering an ask that was called off, as a transfer already ended does.
            rising.reaching = { host in MastodonRising(http: ServersByHost(servers: servers), host: host) }
            await first.hold(Self.tags)
            defer { Task { await first.release(Self.tags) } }
            let firstTagsGuard = watching("the ask of \(Self.tags), held at its server") { await first.release(Self.tags) }
            defer { firstTagsGuard.cancel() }
            let unsigned = Task { await rising.opened(.tags, in: session) }
            await first.arrival(of: Self.tags, by: unsigned)

            try signIn(session)
            #expect(bands(rising, .tags, session)[0] == RisingSaid.Band(source: Self.one), "nobody's band is not the reader's")
            let signed = Task { await rising.opened(.tags, in: session) }
            await first.arrival(of: Self.tags, times: 2, by: signed)
            await first.releaseOne(Self.tags)
            await unsigned.value
            let between = bands(rising, .tags, session)
            #expect(between.map(\.source) == [Self.one, Self.two], "a late not-found leaves no source out")
            #expect(between[0].rows.isEmpty && between[0].asking && between[0].reading == .asking)
            #expect(pages.more.hosts.has(.risingTags, at: Self.one) == .unsaid)
            #expect(between[1].rows.count == 1, "the other source's band is as it was")
            await first.answer(Self.tags, Self.tagsAnswer(["new"]))
            await first.release(Self.tags)
            await signed.value
            #expect(bands(rising, .tags, session)[0].rows == [Self.tag("new", at: Self.one)])
            #expect(await servers[Self.two]?.asked.count == 1, "a sign-in at one source asks nothing of another")
        }
    }

    @Test("The asks go out under the small body's ceiling, as every small unsigned ask does: an answer past it is refused and its source says it could not be asked, while the source beside it lands")
    func underTheSmallCeiling() async throws {
        let big = PageServer.Answer(body: "[" + String(repeating: #"{"name":"a"},"#, count: 120_000) + #"{"name":"b"}]"#)
        let (session, _, _) = await session([Self.tags: big], [Self.tags: Self.tagsAnswer(["maps"])])
        let rising = ShellPersonPages().rising
        await rising.opened(.tags, in: session)
        #expect(bands(rising, .tags, session).map(\.reading) == [.failed, .said] && big.body.utf8.count > SourceReach.smallBody)
    }

    // MARK: - A forum

    @Test("A source that is not asked who people are has no band and is asked nothing; where every source is such a one there are no tabs of what is rising on Trends — its posts are drawn as they were — and the files that draw and ask name no kind of source")
    func aForumReadsTheSame() async throws {
        let (session, servers, work) = await session([:], sources: [Self.forum, Source(host: "talk.example", kind: .discourse)])
        let rising = ShellPersonPages().rising
        for which in RisingWhich.allCases {
            #expect(rising.said(which, in: session) == nil && !rising.canAskAgain(which, in: session))
            await rising.opened(which, in: session)
            await rising.again(which, in: session)
            #expect(rising.walked(which, in: session).isEmpty && rising.opening(which, in: session).isEmpty)
        }
        #expect(rising.tabs(in: session).isEmpty, "a forum's Trends gains no tab of what is rising")
        for server in servers.values { #expect(await server.asked.isEmpty) }
        #expect(work.record.isEmpty)

        for file in ["RisingPane.swift", "ShellRising.swift"] {
            let text = try String(contentsOf: Self.shell.appending(path: file), encoding: .utf8)
            for word in ["ProtocolKind", ".kind", "isForum", ".mastodon", ".discuz", ".discourse", "offers."] {
                #expect(!text.contains(word), "\(file) names \(word)")
            }
        }
        let asked = try String(contentsOf: Self.shell.appending(path: "ShellRising.swift"), encoding: .utf8)
        #expect(asked.contains("ShellPersonPages.source(at:"), "the one fact is read where a person's page reads it")
        // The pane draws a tab of what is rising only where Trends has it in front, and the stream otherwise.
        let pane = try String(contentsOf: Self.shell.appending(path: "TimelinePane.swift"), encoding: .utf8)
        #expect(pane.contains("if let which = trends?.front.rising, let rising = people?.rising, let said = rising.said(which, in: session) {"))
        #expect(pane.contains("} else {\n            stream\n        }"))
        #expect(!pane.contains("offers.") && !pane.contains(".kind == "))
    }

    private static var shell: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI/Shell")
    }

    @Test("A link's row leads where a post's link leads, by the same door: its address is one this device would follow, the reader opens it listed under the source that named it and says the host of the address — and a row is drawn as words alone, with no picture and no press of its own inside it")
    func aLinkGoesThroughThePostsDoor() async throws {
        let (session, _, work) = await session([Self.links: Self.story])
        let rising = ShellPersonPages().rising
        await rising.opened(.links, in: session)
        guard case .link(let link, let source) = try #require(rising.said(.links, in: session)?.rows.first) else {
            Issue.record("no link was listed")
            return
        }
        #expect(PostLink(link.link.text) == link.link && PostLink.followable(link.link.url.absoluteString) != nil)
        let reader = ShellReader()
        reader.work = work
        #expect(reader.open(link.link.url, from: source))
        #expect(reader.reading?.source == Self.one && reader.reading?.host == "far.example")
        #expect(!work.record.contains { $0.reached == "far.example" || $0.reached == "tracker.example" }, "opening the row's page is the press, and listing reached neither")

        let drawn = try String(contentsOf: Self.shell.appending(path: "RisingPane.swift"), encoding: .utf8)
        for word in ["RemoteImage", "AsyncImage", "Link(", "openURL", "AttributedString", "LocalizedStringKey", "markdown"] {
            #expect(!drawn.contains(word), "RisingPane.swift draws with \(word)")
        }
    }

    // MARK: - What the pages say

    @Test("A row says what it is and whose figures these are: a hashtag as it was written, a link by what its source calls it or by its address where it calls it nothing, the host read out of the address, and the source's counts written whole — 'not said' where it gave one figure and not the other, and no line where it gave none")
    func theWords() throws {
        #expect(RisingSaid.used(RisingUse(posts: 1_204, people: 310, days: 2), language: .english) == "Posts 1,204, people 310, over two days.")
        #expect(RisingSaid.used(RisingUse(posts: 7, people: nil, days: 1), language: .english) == "Posts 7, people not said, today.")
        #expect(RisingSaid.used(.unsaid) == nil && RisingSaid.used(RisingUse(posts: nil, people: nil, days: 2)) == nil)

        let link = try #require(PostLink("https://far.example/a/rather/long/story"))
        let named = RisingLink(link: link, title: "A story", words: "What it says.", use: RisingUse(posts: 21, people: 20, days: 1))
        #expect(RisingSaid.called(named) == "A story" && RisingSaid.called(RisingLink(link: link)) == "https://far.example/a/rather/long/story")
        #expect(RisingSaid.spoken(.link(named, source: Self.one), language: .english)
            == "leads to far.example, A story, What it says., Posts 21, people 20, today.", "where it leads is heard before what a stranger called it")
        #expect(RisingSaid.spoken(.link(RisingLink(link: link), source: Self.one), language: .english)
            == "leads to far.example, https://far.example/a/rather/long/story")
        #expect(RisingSaid.spoken(Self.tag("birds", at: Self.one), language: .english) == "#birds, Posts 28, people 15, over two days.")
        #expect(RisingSaid.spoken(.tag(RisingTag(tag: PostTag("#birds")!), source: Self.one), language: .english) == "#birds")
        // A site's name is whatever its source was told: the host is the address's own.
        let spoofed = RisingLink(link: try #require(PostLink("https://evil.example/x")), title: "apple.com \u{202E}moc.elppa")
        #expect(!spoofed.title.unicodeScalars.contains("\u{202E}"))
        #expect(RisingSaid.spoken(.link(spoofed, source: Self.one), language: .english).hasPrefix("leads to evil.example, "))
        // A press that opens nothing moves nothing.
        #expect(ShellRising.lamp(after: false, of: .link(named, source: Self.one), before: "post") == "post")
        #expect(ShellRising.lamp(after: true, of: .link(named, source: Self.one), before: "post") == RisingRow.link(named, source: Self.one).id)
    }

    @Test("Every sentence of the two pages, the key's line and the sentence for Return are written in each language the app speaks, with the places they fill, no figure through a bare number's place, and the two Chinese tables alike — and Return's sentence says a row, whatever kind it is")
    func writtenInEveryLanguage() throws {
        let resources = Self.shell.deletingLastPathComponent().appending(path: "Resources")
        let english = try String(contentsOf: resources.appending(path: "en.lproj/Localizable.strings"), encoding: .utf8)
        let keys = english.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\"rising.") || line.hasPrefix("\"work.purpose.rising\"") || line.hasPrefix("\"shortcut.rising\"")
                || line.hasPrefix("\"shortcut.expand\"")
            else { return nil }
            return line.dropFirst().split(separator: "\"").first.map(String.init)
        }
        // The page's title and its two tabs; the two titles a way in had, the bar's mark and
        // the lines that said a miss went with the page.
        #expect(keys.count == 14 && keys.contains("rising.use.two") && keys.contains("work.purpose.rising") && keys.contains("shortcut.expand"))
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
        #expect(SourceWork.Purpose.rising.isOfTheSource && !SourceWork.Purpose.rising.gathers)
        let opens = L10n.t("shortcut.expand", language: .english)
        #expect(opens == "Open the row you are on; on Notices, what the notice you are on is about" && !opens.contains("thread"))
        let chinese = L10n.t("shortcut.expand", language: .taiwanese)
        #expect(chinese.contains("那一列") && chinese.contains("通知") && !chinese.contains("討論串"))
    }

    @Test("The tabs and a row are laid out to the width they are given and never past it, in light and in dark, in each state they have; a link's row is no taller for a title or words of any length than for four lines of them")
    func laidOut() throws {
        func size<Content: View>(_ content: Content, _ width: CGFloat, scheme: ColorScheme = .light) -> CGSize {
            let hosted = NSHostingView(rootView: VStack(spacing: 0) { content }.frame(width: width).environment(\.colorScheme, scheme))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize
        }
        let link = try #require(PostLink("https://a-rather-long-name-of-a-host.a-rather-long-instance-name.example/a/story"))
        let long = String(repeating: "words and more words ", count: 40)
        let wordy = RisingRow.link(RisingLink(link: link, title: long, words: long, use: RisingUse(posts: 1_204_000, people: 310_000, days: 2)), source: Self.one)
        let brief = RisingRow.link(RisingLink(link: link, title: "A", words: "B", use: RisingUse(posts: 1, people: 1, days: 1)), source: Self.one)
        let bare = RisingRow.link(RisingLink(link: link), source: Self.one)
        let tag = Self.tag(String(repeating: "long", count: 25), at: Self.one)
        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (390, .dark), (320, .light)] {
            for row in [wordy, brief, bare, tag, .tag(RisingTag(tag: PostTag("#a")!), source: Self.one)] {
                for selected in [false, true] {
                    let laid = size(RisingRowView(row: row, selected: selected), width, scheme: scheme)
                    #expect(laid.width == width && laid.height > 0, "at \(width)")
                }
            }
            let tall = size(RisingRowView(row: wordy), width).height, short = size(RisingRowView(row: brief), width).height
            #expect(tall >= short && tall < short * 3, "a link's words are held to their lines at \(width): \(tall) against \(short)")
            #expect(size(RisingRowView(row: bare), width).height < short)
            #expect(size(RisingHead(), width, scheme: scheme).width == width)
        }
        let states = [
            RisingSaid(which: .tags, bands: [RisingSaid.Band(source: Self.one), RisingSaid.Band(source: Self.two, reading: .failed)]),
            RisingSaid(which: .tags, bands: [
                RisingSaid.Band(source: Self.one, reading: .said, asking: true, rows: [tag, Self.tag("birds", at: Self.one)]),
                RisingSaid.Band(source: Self.two, reading: .said), RisingSaid.Band(source: "o.example", reading: .stopped),
            ]),
            RisingSaid(which: .links, bands: [RisingSaid.Band(source: Self.one, reading: .said, rows: [wordy, brief, bare])]),
        ]
        for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 320)] {
            for said in states {
                // The tab in front, as Trends draws it under its head.
                let pane = RisingPane(said: said, selectedID: .constant(said.rows.first?.id), onOpen: { _ in }) { RisingHead() }
                    .environment(\.shellLayout, layout)
                let hosted = NSHostingView(rootView: pane.frame(width: width, height: 700))
                hosted.layoutSubtreeIfNeeded()
                #expect(hosted.fittingSize == CGSize(width: width, height: 700))
            }
        }
    }
}
