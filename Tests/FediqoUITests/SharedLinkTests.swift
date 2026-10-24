import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #379, the page: a link rising on the sources opened as the posts that share it — offered only
/// where a source that named it says it lists them, asked of those sources alone, landing in the
/// store, read on at its foot as a timeline is, and drawn newest first; a source that lists none
/// of it says so, and a source that cannot keeps the link's page as the press.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`); every deadline is on a
/// clock nobody turns.
@MainActor
@Suite("The posts that share a rising link", .serialized, .watched)
struct SharedLinkTests {
    private static let one = "m.example", two = "n.example"
    private static let address = "https://far.example/story"
    private static let document = "/api/v2/instance"

    /// A host's document, naming the API version it speaks where it names one.
    private static func instance(_ host: String, api: Int?) -> PageServer.Answer {
        let versions = api.map { #","api_versions":{"mastodon":\#($0)}"# } ?? ""
        return PageServer.Answer(body: #"{"domain":"\#(host)","title":"M","version":"4.6.6"\#(versions)}"#)
    }

    /// What the page asks of a source, as the request spells it.
    private static func ask(after next: String? = nil) throws -> String {
        let query = [URLQueryItem(name: "url", value: address), URLQueryItem(name: "limit", value: "40")]
            + (next.map { [URLQueryItem(name: "max_id", value: $0)] } ?? [])
        let url = try #require(Host.httpsURL(host: one, path: MastodonLinkPosts.path, query: query))
        return url.path + "?" + (url.query ?? "")
    }

    /// One post that carries the link, as a source sends it: the same post has one name wherever it is read.
    private static func post(_ id: String, minute: Int) -> String {
        #"""
        {"id":"\#(id)","uri":"https://elsewhere.example/statuses/\#(id)","created_at":"2026-10-22T00:\#(String(format: "%02d", minute)):00.000Z",
         "content":"<p>shares \#(id)</p>","visibility":"public","account":{"id":"9","acct":"far@elsewhere.example","username":"far","display_name":"Far"}}
        """#
    }

    private static func posts(_ posts: [String], next: String? = nil, at host: String = one) -> PageServer.Answer {
        PageServer.Answer(
            body: "[" + posts.joined(separator: ",") + "]",
            link: next.map { #"<https://\#(host)/api/v1/timelines/link?max_id=\#($0)>; rel="next""# }
        )
    }

    private static let notListed = PageServer.Answer(body: #"{"error":"Record not found"}"#, status: 404)
    private static let noAddress = PageServer.Answer(body: "<!DOCTYPE html><html></html>", status: 404)

    private static func listed(sources: [String] = [one, two]) -> RisingListed {
        let link = RisingLink(link: PostLink(address)!, title: "A story", words: "What it says.")
        return RisingListed(row: .link(link, source: sources[0]), sources: sources)
    }

    private func session(
        _ first: [String: PageServer.Answer], _ second: [String: PageServer.Answer] = [:]
    ) async -> (ShellSession, [String: PageServer], ShellPersonPages) {
        let servers = [Self.one: PageServer(first), Self.two: PageServer(second)]
        let router = ServersByHost(servers: servers)
        let session = ShellSession(
            http: router, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: router)
        )
        session.deadlinesUnturned()
        session.work = SourceWork()
        for host in [Self.one, Self.two] { await session.store.add(Source(host: host, kind: .mastodon)) }
        session.sources = await session.store.sources()
        let pages = ShellPersonPages()
        session.personPages = pages
        return (session, servers, pages)
    }

    // MARK: - Whether a link opens its posts

    @Test("A link opens its posts only where a source that named it says, by its document's word for its API, that it lists them — and is asked of those sources alone; a source whose document names none, or one not yet heard, keeps the link's page as the press; a hashtag is never such a page")
    func offeredOnlyWhereSaid() async throws {
        let (session, servers, pages) = await session(
            [Self.document: Self.instance(Self.one, api: 11)], [Self.document: Self.instance(Self.two, api: nil)]
        )
        let shared = pages.shared
        #expect(shared.page(opening: Self.listed(), in: session) == nil, "nothing heard yet: the link's page, as it was")
        await shared.hear([Self.one, Self.two], in: session)
        let page = try #require(shared.page(opening: Self.listed(), in: session))
        #expect(page.sources == [Self.one] && page.link.link.url.absoluteString == Self.address && page.id == Self.address)
        #expect(shared.page(opening: Self.listed(sources: [Self.two]), in: session) == nil, "a document that names no version says nothing")
        let tag = RisingListed(row: .tag(RisingTag(tag: PostTag("#birds")!), source: Self.one), sources: [Self.one])
        #expect(shared.page(opening: tag, in: session) == nil)
        // Heard once a run.
        await shared.hear([Self.one, Self.two], in: session)
        for host in [Self.one, Self.two] { #expect(await servers[host]?.asked == [Self.document]) }
    }

    // MARK: - Asked, landed, read on

    @Test("Opening asks each source once for the link's posts, by the link as the source wrote it; what comes lands in the store as an item of no category, and the page draws it newest first, a post two sources listed one row; opened again, nobody is asked")
    func openingLandsNewestFirst() async throws {
        let (session, servers, pages) = await session(
            [try Self.ask(): Self.posts([Self.post("12", minute: 2), Self.post("11", minute: 1)])],
            [try Self.ask(): Self.posts([Self.post("13", minute: 3), Self.post("12", minute: 2)])]
        )
        let page = SharedLink(link: RisingLink(link: PostLink(Self.address)!, title: "A story"), sources: [Self.one, Self.two])
        await pages.shared.opened(page, in: session)
        for host in [Self.one, Self.two] { #expect(await servers[host]?.asked == [try Self.ask()]) }
        let said = pages.shared.said(of: page, in: session)
        #expect(said.items.map(\.body) == ["shares 13", "shares 12", "shares 11"], "newest first, and the shared post once")
        #expect(said.items[1].otherCopies.count == 1, "one row naming both sources")
        #expect(said.quiet.isEmpty && said.foot == .end)
        #expect(session.notes.count == 4 && session.notes.allSatisfy { $0.categories.isEmpty }, "held as items of no category")
        #expect(pages.shared.keys(of: page).count == 4)
        #expect(pages.shared.walked(page, in: session) == said.items.map(\.id))
        #expect(FediqoRootView.listItems(on: walked(page), pages: pages, stream: [], latest: nil, in: session).map(\.id) == said.items.map(\.id))

        await pages.shared.opened(page, in: session)
        for host in [Self.one, Self.two] { #expect(await servers[host]?.asked.count == 1) }
        await pages.shared.again(page, in: session)
        #expect(await servers[Self.one]?.asked.count == 2, "`r` asks every source from its top")
    }

    private func walked(_ page: SharedLink) -> ShellWalk {
        var walk = ShellWalk()
        _ = walk.walk(to: .shared(page), from: "row")
        return walk
    }

    @Test("Reaching the foot reads on by each source's own next until it names none: the foot reads on while one is named, and is the end after")
    func readsOnAtTheFoot() async throws {
        let (session, servers, pages) = await session([
            try Self.ask(): Self.posts([Self.post("12", minute: 2)], next: "12"),
            try Self.ask(after: "12"): Self.posts([Self.post("11", minute: 1)]),
        ])
        let server = try #require(servers[Self.one])
        let page = SharedLink(link: RisingLink(link: PostLink(Self.address)!), sources: [Self.one])
        await pages.shared.opened(page, in: session)
        #expect(pages.shared.said(of: page, in: session).foot == .more)

        await pages.shared.readOn(page, pressed: false, in: session)
        #expect(await server.asked == [try Self.ask(), try Self.ask(after: "12")])
        let said = pages.shared.said(of: page, in: session)
        #expect(said.items.map(\.body) == ["shares 12", "shares 11"] && said.foot == .end)
        #expect(said.footWords == String(format: L10n.t("person.foot.end"), Self.one))
        #expect(pages.shared.ask(of: page) == PageAsking())
        await pages.shared.readOn(page, pressed: true, in: session)
        #expect(await server.asked.count == 2, "nothing named, nothing read on")
    }

    @Test("After a stretch that did not come, reaching the foot asks nothing — however often it comes back into view — until it is pressed; the miss is the toast's, and the press asks again")
    func aFailureWaitsForAPress() async throws {
        let (session, servers, pages) = await session([
            try Self.ask(): Self.posts([Self.post("12", minute: 2)], next: "12"),
            try Self.ask(after: "12"): PageServer.Answer(body: "", status: 503),
        ])
        let server = try #require(servers[Self.one])
        let page = SharedLink(link: RisingLink(link: PostLink(Self.address)!), sources: [Self.one])
        await pages.shared.opened(page, in: session)
        await pages.shared.readOn(page, pressed: false, in: session)
        #expect(await server.asked.count == 2)
        #expect(pages.shared.said(of: page, in: session).foot == .more, "the foot is a press")
        #expect(pages.shared.ask(of: page) == PageAsking(failed: [Self.one]))

        for _ in 0..<3 { await pages.shared.readOn(page, pressed: false, in: session) }
        #expect(await server.asked.count == 2, "reached after a failure, nothing is asked")

        await server.answer(try Self.ask(after: "12"), Self.posts([Self.post("11", minute: 1)]))
        await pages.shared.readOn(page, pressed: true, in: session)
        #expect(await server.asked.count == 3)
        #expect(pages.shared.said(of: page, in: session).items.count == 2 && pages.shared.ask(of: page) == PageAsking())
    }

    @Test("Stop ends a reading-on on the wire as it ends an ask from the top: what it brings lands nowhere, the toast says it was stopped, and the foot then waits for a press")
    func stopEndsAReadingOn() async throws {
        let (session, servers, pages) = await session([
            try Self.ask(): Self.posts([Self.post("12", minute: 2)], next: "12"),
            try Self.ask(after: "12"): Self.posts([Self.post("11", minute: 1)]),
        ])
        let server = try #require(servers[Self.one])
        let page = SharedLink(link: RisingLink(link: PostLink(Self.address)!), sources: [Self.one])
        await pages.shared.opened(page, in: session)
        let onward = try Self.ask(after: "12")
        await server.hold(onward)
        defer { Task { await server.release(onward) } }
        let held = watching("the reading-on, held at its server") { await server.release(onward) }
        defer { held.cancel() }
        let reading = Task { await pages.shared.readOn(page, pressed: false, in: session) }
        await server.arrival(of: onward, by: reading)
        #expect(pages.shared.ask(of: page, language: .english) == PageAsking(asking: L10n.t("person.foot.reading", language: .english), stoppable: true))
        #expect(TimelinePane.stop(.shared(page), of: pages, in: session))
        await server.release(onward)
        await reading.value
        #expect(pages.shared.said(of: page, in: session).items.count == 1, "what it brought landed nowhere on the page")
        #expect(pages.shared.ask(of: page) == PageAsking(stopped: true))
        #expect(pages.shared.said(of: page, in: session).foot == .more)

        await pages.shared.readOn(page, pressed: false, in: session)
        #expect(await server.arrivals(of: onward) == 1, "a stopped foot reached asks nothing")
        await pages.shared.readOn(page, pressed: true, in: session)
        #expect(await server.arrivals(of: onward) == 2 && pages.shared.said(of: page, in: session).items.count == 2)
    }

    @Test("A source that refuses (422) is a stretch that did not come and says it refused — never that it lists none — and a press asks again")
    func aRefusalIsNotNone() async throws {
        let refused = PageServer.Answer(body: #"{"error":"This method requires an authenticated user"}"#, status: 422)
        let (session, servers, pages) = await session([try Self.ask(): refused])
        let page = SharedLink(link: RisingLink(link: PostLink(Self.address)!), sources: [Self.one])
        await pages.shared.opened(page, in: session)
        let said = pages.shared.said(of: page, in: session, language: .english)
        #expect(said.quiet == ["m.example refused to say which posts share this link."])
        #expect(pages.shared.ask(of: page) == PageAsking(failed: [Self.one]))
        // Asked again and failing another way, it no longer says it refused: the miss is the toast's.
        await servers[Self.one]?.answer(try Self.ask(), PageServer.Answer(body: "", status: 503))
        await pages.shared.again(page, in: session)
        #expect(pages.shared.said(of: page, in: session).quiet.isEmpty && pages.shared.ask(of: page) == PageAsking(failed: [Self.one]))
        await servers[Self.one]?.answer(try Self.ask(), Self.posts([Self.post("12", minute: 2)]))
        await pages.shared.again(page, in: session)
        #expect(pages.shared.said(of: page, in: session).quiet.isEmpty && pages.shared.ask(of: page) == PageAsking())
    }

    @Test("A source that lists none of the link says so at the foot and the other's posts stand; one whose address is not there says the same and is not offered again this run; one that gave none says it gave none")
    func whatIsNotListed() async throws {
        let (session, _, pages) = await session(
            [Self.document: Self.instance(Self.one, api: 11), try Self.ask(): Self.notListed],
            [Self.document: Self.instance(Self.two, api: 11), try Self.ask(): Self.noAddress]
        )
        await pages.shared.hear([Self.one, Self.two], in: session)
        let page = try #require(pages.shared.page(opening: Self.listed(), in: session))
        await pages.shared.opened(page, in: session)
        let said = pages.shared.said(of: page, in: session, language: .english)
        #expect(said.items.isEmpty && said.foot == nil)
        #expect(said.quiet == ["m.example lists no posts that share this link.", "n.example lists no posts that share this link."])
        #expect(pages.shared.hosts.has(.linkPosts, at: Self.two) == .absent && pages.shared.hosts.has(.linkPosts, at: Self.one) == .present)
        #expect(pages.shared.page(opening: Self.listed(), in: session)?.sources == [Self.one])
        #expect(pages.shared.ask(of: page).failed.isEmpty, "not listing is no failure")

        let (quiet, _, others) = await self.session([try Self.ask(): Self.posts([])])
        let alone = SharedLink(link: RisingLink(link: PostLink(Self.address)!), sources: [Self.one])
        await others.shared.opened(alone, in: quiet)
        #expect(others.shared.said(of: alone, in: quiet, language: .english).quiet == ["m.example gave no posts that share this link."])
    }

    // MARK: - While an ask is out

    @Test("Stop calls the page's ask off: what it brings lands nowhere, the toast says it was stopped, and asking again lands; a press while a source is asked asks it nothing")
    func stopLandsNothing() async throws {
        let (session, servers, pages) = await session([try Self.ask(): Self.posts([Self.post("12", minute: 2)])])
        let server = try #require(servers[Self.one])
        let page = SharedLink(link: RisingLink(link: PostLink(Self.address)!), sources: [Self.one])
        let ask = try Self.ask()
        await server.hold(ask)
        defer { Task { await server.release(ask) } }
        let held = watching("the ask of the link's posts, held at its server") { await server.release(ask) }
        defer { held.cancel() }
        let opening = Task { await pages.shared.opened(page, in: session) }
        await server.arrival(of: ask, by: opening)
        await pages.shared.again(page, in: session)
        #expect(await server.asked.count == 1, "a press while the source is asked asks nothing")
        #expect(pages.shared.ask(of: page, language: .english).asking == "Asking m.example for the posts that share a link to far.example…")
        #expect(pages.shared.ask(of: page).stoppable)
        #expect(TimelinePane.stop(.shared(page), of: pages, in: session))
        await server.release(ask)
        await opening.value
        #expect(session.notes.isEmpty && pages.shared.said(of: page, in: session).items.isEmpty)
        #expect(pages.shared.ask(of: page) == PageAsking(stopped: true))

        await pages.shared.again(page, in: session)
        #expect(pages.shared.said(of: page, in: session).items.count == 1 && pages.shared.ask(of: page) == PageAsking())
    }

    // MARK: - The page

    @Test("The page is one of its own: drawn on the layer of a page of post rows, its own toast and Stop, no timelines' head over it, its swipe its own, the stream drawn in its stead once its sources are gone — and a listener hears where the link leads before what a stranger called it")
    func thePage() async throws {
        let (session, _, pages) = await session([:])
        let page = SharedLink(link: RisingLink(link: PostLink(Self.address)!, title: "A story", words: "What it says."), sources: [Self.one, Self.two])
        let step = ShellStep.shared(page)
        #expect(step.layer == .tag && step.tabKey == .sole(.tag) && step.isKind(of: .shared(page)) && !step.isKind(of: .tag(PostTag("#x")!)))
        #expect(walked(page).openedShared == page && walked(page).openedTag == nil)
        #expect(TimelinePane.askInFront(step, rising: nil, of: pages, in: session) == .shared(page))
        #expect(!TimelinePane.headDrawn(over: step) && TimelinePane.page(step) == .tabbed)
        #expect(TimelinePane.openedID(step) == "shared:" + Self.address)
        #expect(TimelinePane.drawn(step, of: pages, in: session).drawn)
        session.sources = []
        #expect(!TimelinePane.drawn(step, of: pages, in: session).drawn && TimelinePane.headDrawn(over: step, drawn: false))

        let said = SharedLinkSaid(page: page)
        #expect(SharedLinkHead.spoken(said, language: .english) == [
            "leads to far.example", "A story", "What it says.", "Posts that share it", RisingSaid.spokenSources([Self.one, Self.two], language: .english),
        ].compactMap { $0 }.joined(separator: L10n.t("people.row.between", language: .english)))
        let mark = SharedLinkPane.openMark(said, language: .english) {}
        #expect(mark.name == "Open the page" && mark.hint == "leads to far.example")
        #expect(SharedLinkPane.reloadName(of: said, canReload: true, language: .english) == "Ask m.example, n.example again")
        #expect(SharedLinkPane.reloadName(of: said, canReload: false) == nil)
        #expect(SharedLinkPane.quiet(SharedLinkSaid(page: page, quiet: ["a", "b"])) == "a\nb" && SharedLinkPane.quiet(said) == nil)
    }

    @Test("Every word of the page is in each language the app speaks")
    func wordsInEveryLanguage() {
        for language in DummyLanguage.allCases {
            for key in ["shared.heading", "shared.asking", "shared.unlisted", "shared.none", "shared.refused", "shared.open"] {
                #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
            }
        }
    }
}
