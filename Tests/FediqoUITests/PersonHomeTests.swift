import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #310, the one press on somebody's page that asks the server they live on: what is asked of
/// whom and when, what lets it leave, what the page says of each outcome, and that the added
/// source's view stands through all of it — and that a forum's page has no such press.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), and each ends by
/// itself: a held ask is let go in a `defer`, and by the server after its patience.
@MainActor
@Suite("The server somebody lives on, asked at a press", .serialized, .timeLimit(.minutes(1)))
struct PersonHomeTests {
    private static let one = "m.example", home = "elsewhere.example", other = "other.example"
    private static let source = Source(host: one, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/FediqoUI/Shell")

    init() {
        L10n.language = .english
    }

    /// The ask for somebody by name, as either door spells it.
    private static func lookup(_ acct: String) -> String {
        let url = Host.httpsURL(host: one, path: "/api/v1/accounts/lookup", query: [URLQueryItem(name: "acct", value: acct)])
        return "/api/v1/accounts/lookup?" + (url?.query(percentEncoded: true) ?? "")
    }

    /// Somebody of another server as the added source says them: the part that reached it.
    private static func partial(_ id: Int, _ acct: String) -> PageServer.Answer {
        PageServer.Answer(body: #"{"id":"\#(id)","acct":"\#(acct)","display_name":"Partly","note":"<p>partial</p>","followers_count":2,"following_count":1,"statuses_count":3}"#)
    }

    /// Somebody as their own server says them — with a face, a head picture and a picture in
    /// their words, each an address of that server's choosing.
    private static func whole(_ acct: String, on host: String = home) -> PageServer.Answer {
        PageServer.Answer(body: #"{"id":"5","acct":"\#(acct)","display_name":"Whole :m:","locked":true,"note":"<p>whole https://\#(host)/more</p>","avatar":"https://\#(host)/a.png","header":"https://\#(host)/h.png","followers_count":2811,"following_count":310,"statuses_count":1204,"emojis":[{"shortcode":"m","url":"https://\#(host)/e.png","static_url":"https://\#(host)/e.png"}]}"#)
    }

    private static let posts = PageServer.Answer(body: "[]")
    private static let far = DummyPerson(handle: "@far@elsewhere.example", host: one)!
    private static let near = DummyPerson(handle: "@near@other.example", host: one)!

    private static let served: [String: PageServer.Answer] = [
        lookup("far@elsewhere.example"): partial(77, "far@elsewhere.example"), "/api/v1/accounts/77/statuses": posts,
        lookup("near@other.example"): partial(78, "near@other.example"), "/api/v1/accounts/78/statuses": posts,
        lookup("ada"): PageServer.Answer(body: #"{"id":"42","acct":"ada"}"#), "/api/v1/accounts/42/statuses": posts,
    ]

    @MainActor
    private struct Shell {
        let session: ShellSession
        let servers: [String: PageServer]
        let work: SourceWork
        let pages = ShellPersonPages()

        func server(_ host: String) throws -> PageServer { try #require(servers[host]) }

        /// The asks of somebody's own server this run's record lists.
        var homeActs: [SourceAct] { work.record.filter { $0.purpose == .personHome } }
    }

    /// A source that says who people are, signed in to, and a forum — **governed**, so nothing
    /// leaves that the gate does not let through — and two servers nobody added.
    private func shell(
        at source: [String: PageServer.Answer] = served, home: [String: PageServer.Answer]? = nil, signedIn: Bool = true
    ) async throws -> Shell {
        let servers = [
            Self.one: PageServer(source), Self.home: PageServer(home ?? [Self.lookup("far"): Self.whole("far")]),
            Self.other: PageServer([Self.lookup("near"): Self.whole("near", on: Self.other)]), Self.forum.host: PageServer([:]),
        ]
        let router = ServersByHost(servers: servers)
        let tokens = MemoryMastodonTokens()
        let session = ShellSession(http: router, store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: router))
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for joined in [Self.source, Self.forum] { await session.store.add(joined) }
        session.sources = await session.store.sources()
        work.govern(sources: session.sources.map(\.host))
        if signedIn {
            try tokens.save(MastodonToken(host: Self.one, accessToken: "tok", clientID: "c", clientSecret: "s"))
            // And a token for the very server asked, which no ask of it may carry.
            try tokens.save(MastodonToken(host: Self.home, accessToken: "theirs", clientID: "c", clientSecret: "s"))
            session.mastodon.refresh()
        }
        return Shell(session: session, servers: servers, work: work)
    }

    private static let offer = PersonHomeLine(press: .ask, pressWords: "Ask elsewhere.example")
    private static let noAccount = "elsewhere.example gave no account of them: it is not a Mastodon, or it refused. What m.example says stands."
    private static let nobody = "elsewhere.example knows nobody of that name. What m.example says stands."
    private static let unread = "elsewhere.example could not be read. What m.example says stands."

    // MARK: - Asked at the press, once, and by nothing else

    @Test("Opening the page of somebody who lives elsewhere, asking it again and reading on ask their own server nothing: the page offers one press that names that server, and the run's record lists no ask of it")
    func nothingUnasked() async throws {
        let shell = try await shell()
        let pages = shell.pages, session = shell.session
        await pages.opened(Self.far, in: session)
        await pages.again(Self.far, in: session)
        await pages.readOn(Self.far, in: session)
        #expect(pages.said(of: Self.far, in: session)?.person?.livesHere == false)
        #expect(pages.homeLine(of: Self.far, in: session) == Self.offer && pages.homeSaid(of: Self.far, in: session) == nil)
        let asked = await (try shell.server(Self.home)).asked
        #expect(asked.isEmpty && shell.homeActs.isEmpty)
        let reached = Set(shell.work.record.map(\.reached))
        #expect(reached == [Self.one])
    }

    @Test("The press asks that server once — for them by name, with no sign-in though the reader is signed in to the source and a token for that very server is held — listed in the run's record under the server asked, by the entry that let it through; the page then draws what it said, in letters alone, says whose word it is and when, and offers the way back; the added source's view stands under it and is drawn again at the way back; a further ask is a further press")
    func thePress() async throws {
        let shell = try await shell()
        let pages = shell.pages, session = shell.session, home = try shell.server(Self.home), source = try shell.server(Self.one)
        await pages.opened(Self.far, in: session)
        let before = try #require(pages.said(of: Self.far, in: session))
        let asksOfTheSource = await source.asked

        await pages.homePressed(.ask, on: Self.far, in: session)
        #expect(await home.asked == [Self.lookup("far")])
        #expect(await home.bearers == [""], "no token rode to a server nobody signed in to")
        let asksAfter = await source.asked, bearers = await source.bearers
        #expect(asksAfter == asksOfTheSource && bearers.allSatisfy { $0 == "Bearer tok" })
        let acts = shell.homeActs
        try #require(acts.count == 1)
        #expect(acts[0].reached == Self.home)
        #expect(acts[0].source == Self.home)
        #expect(acts[0].allowedBy == .personHome)
        #expect(acts[0].purposeText(language: .english) == "Asking the server someone lives on about them")
        #expect(Allowance.ID.personHome.name(language: .english) == "A person's own server")
        #expect(shell.work.admission(reached: Self.home, source: nil, for: .personHome) == nil, "the press was spent by its one request")

        let said = try #require(pages.homeSaid(of: Self.far, in: session))
        #expect(said.home == Self.home && said.person.handle == "@far@elsewhere.example" && said.person.name == "Whole :m:")
        #expect(said.person.tally == Person.Tally(posts: 1_204, following: 310, followers: 2_811))
        #expect(said.person.avatarURL == nil && said.person.headerURL == nil && said.person.emojis.isEmpty)
        let line = PersonHomeLine(words: "The posts below are what m.example gave.", press: .back, pressWords: "Back to what m.example says")
        #expect(pages.homeLine(of: Self.far, in: session) == line)
        let view = PersonPane.viewLine(of: Self.far, said: before, home: said, language: .english)
        #expect(view.hasPrefix("As elsewhere.example says, asked at ") && view != PersonPane.viewLine(of: Self.far, said: before))
        let named = PersonPane.named(Self.far, said: before, home: said)
        #expect(named.name == "Whole :m:" && named.handle == "@far@elsewhere.example" && named.emojis.isEmpty)
        #expect(PersonPane.face(of: Self.far, said: before) == nil, "the face stays the source's, which has none")
        #expect(pages.lists(of: Self.far, in: session).isEmpty, "the source's figures are not on the page meanwhile")
        #expect(pages.said(of: Self.far, in: session) == before, "what the added source says stands")
        #expect(session.notes.isEmpty, "nothing was held")
        pages.home.letGo(of: Self.near)
        #expect(pages.homeSaid(of: Self.far, in: session) == said, "another page leaving lets nothing of this one go")

        await pages.homePressed(.back, on: Self.far, in: session)
        #expect(pages.homeSaid(of: Self.far, in: session) == nil && pages.homeLine(of: Self.far, in: session) == Self.offer)
        #expect(pages.lists(of: Self.far, in: session).count == 2 && pages.said(of: Self.far, in: session) == before)
        #expect(await home.asked.count == 1, "going back asked nothing")

        await pages.homePressed(.ask, on: Self.far, in: session)
        let pressedAgain = await home.asked
        #expect(pressedAgain.count == 2 && shell.homeActs.count == 2)
    }

    @Test("With no sign-in anywhere, the page of somebody the added source has not heard of offers the same one press, and it is the way to them: their own server's word is drawn, and going back is to what the source said — that it has not heard of them")
    func theOnlyWayWithNoSignIn() async throws {
        let unheard = [Self.lookup("far@elsewhere.example"): PageServer.Answer(body: #"{"error":"Record not found"}"#, status: 404)]
        let shell = try await shell(at: unheard, signedIn: false)
        let pages = shell.pages, session = shell.session, home = try shell.server(Self.home)
        await pages.opened(Self.far, in: session)
        #expect(pages.said(of: Self.far, in: session)?.reading == .unheardOf)
        #expect(pages.homeLine(of: Self.far, in: session) == Self.offer)
        #expect(await home.asked.isEmpty)

        await pages.homePressed(.ask, on: Self.far, in: session)
        let asked = await home.asked, bearers = await home.bearers
        #expect(asked == [Self.lookup("far")] && bearers == [""])
        #expect(pages.homeSaid(of: Self.far, in: session)?.person.name == "Whole :m:")
        let back = PersonHomeLine(press: .back, pressWords: "Back to what m.example says")
        #expect(pages.homeLine(of: Self.far, in: session) == back, "no posts of the source's stand under it, so none are spoken of")
        await pages.homePressed(.back, on: Self.far, in: session)
        #expect(pages.said(of: Self.far, in: session)?.reading == .unheardOf && pages.homeSaid(of: Self.far, in: session) == nil)
    }

    // MARK: - The three outcomes

    @Test("A Mastodon that knows nobody of the name, a server that answers without them — one that answers only its members, a forum's or a web server's page for a 404, a page that is no account, somebody else's account — and one that could not be read each say so in a sentence of their own, in full ink, with the press beside it; nothing is asked again unpressed, and the added source's view is as it was")
    func theFailuresSaySo() async throws {
        let answers: [(PageServer.Answer?, ShellPersonHome.Standing, String)] = [
            (PageServer.Answer(body: #"{"error":"Record not found"}"#, status: 404), .nobody, Self.nobody),
            (PageServer.Answer(body: "<!DOCTYPE html><html><title>404 Not Found</title></html>", status: 404), .noAccount, Self.noAccount),
            (PageServer.Answer(body: #"{"error":"This method requires an authenticated user"}"#, status: 401), .noAccount, Self.noAccount),
            (PageServer.Answer(body: "<!DOCTYPE html><html><title>Page Not Found</title></html>"), .noAccount, Self.noAccount),
            (Self.whole("somebody"), .noAccount, Self.noAccount),
            (Self.whole("far@third.example"), .noAccount, Self.noAccount),
            (nil, .unread, Self.unread),
        ]
        for (answer, standing, words) in answers {
            let shell = try await shell(home: answer.map { [Self.lookup("far"): $0] } ?? [:])
            let pages = shell.pages, session = shell.session, home = try shell.server(Self.home)
            await pages.opened(Self.far, in: session)
            let before = try #require(pages.said(of: Self.far, in: session))
            await pages.homePressed(.ask, on: Self.far, in: session)
            #expect(pages.home.stands(for: Self.far) == standing)
            let line = PersonHomeLine(words: words, press: .ask, pressWords: "Ask elsewhere.example", failed: true)
            #expect(pages.homeLine(of: Self.far, in: session) == line)
            #expect(pages.homeSaid(of: Self.far, in: session) == nil && pages.said(of: Self.far, in: session) == before)
            #expect(pages.lists(of: Self.far, in: session).count == 2)
            let asked = await home.asked
            #expect(asked.count == 1 && shell.homeActs.count == 1, "one ask, and no second try")
        }
        // An ask walked away from is no failure: the press is offered as it was.
        let shell = try await shell(home: [Self.lookup("far"): PageServer.Answer(body: "", cancelled: true)])
        await shell.pages.opened(Self.far, in: shell.session)
        await shell.pages.homePressed(.ask, on: Self.far, in: shell.session)
        #expect(shell.pages.home.stands(for: Self.far) == nil && shell.pages.homeLine(of: Self.far, in: shell.session) == Self.offer)
    }

    // MARK: - Where no press is offered

    @Test("No press is offered, and none asks anything, on a forum author's page, for somebody who lives at the source, while the source is being asked or has failed, for a home that is no name a press may reach, or once the person has switched the entry off")
    func whereThereIsNoPress() async throws {
        let shell = try await shell()
        let pages = shell.pages, session = shell.session
        let author = DummyPerson(handle: "@bob@elsewhere.example", host: Self.forum.host)!
        #expect(pages.said(of: author, in: session) == nil && pages.homeLine(of: author, in: session) == nil)
        await pages.homePressed(.ask, on: author, in: session)

        let ada = DummyPerson(handle: "@ada@m.example", host: Self.one)!
        await pages.opened(ada, in: session)
        #expect(pages.said(of: ada, in: session)?.person?.livesHere == true && pages.homeLine(of: ada, in: session) == nil)
        await pages.homePressed(.ask, on: ada, in: session)

        for reading in [PersonSaid.Reading.asking, .failed] {
            let said = PersonSaid(source: Self.one, reading: reading)
            #expect(ShellPersonHome.target(of: Self.far, said: said) == nil)
            await pages.home.ask(Self.far, beside: said, in: session)
        }
        for name in ["localhost", "router", "printer.local", "nas.internal", "127.0.0.1", "0x7f.0x1", "2130706433"] {
            let person = Person(source: Self.source, accountID: "9", handle: "@x@\(name)", name: "x")
            let said = PersonSaid(source: Self.one, reading: .said(person))
            #expect(ShellPersonHome.target(of: Self.far, said: said) == nil, "\(name)")
            #expect(pages.home.line(of: Self.far, beside: said, in: session) == nil, "\(name)")
            await pages.home.ask(Self.far, beside: said, in: session)
        }

        await pages.opened(Self.far, in: session)
        #expect(pages.homeLine(of: Self.far, in: session) == Self.offer)
        shell.work.allow(Allowance.standing.filter { $0.id != .personHome })
        #expect(pages.homeLine(of: Self.far, in: session) == nil)
        await pages.homePressed(.ask, on: Self.far, in: session)
        #expect(pages.home.stands(for: Self.far) == nil, "switched off, the press is not there to make")

        for host in [Self.home, Self.other, Self.forum.host] {
            let asked = await (try shell.server(host)).asked
            #expect(asked.isEmpty, "\(host)")
        }
        #expect(shell.homeActs.isEmpty)
    }

    @Test("A home is a name a press may reach only where it could be registered: lower-case letters, digits and inner hyphens in two labels or more, the last of letters or the ASCII spelling of another script — and never an address in any form, a name kept for a device or its network, a port, credentials, a scheme, a path, or letters not yet folded")
    func theNameAPressMayReach() {
        for name in ["example.org", "social.example.co.uk", "a-b.example", "xn--bcher-kva.example", "example.xn--p1ai"] {
            #expect(Allowance.homeServer(name) == name, "\(name)")
        }
        #expect(Allowance.homeServer("Example.ORG") == "example.org")
        let refused = [
            "localhost", "example", "printer.local", "nas.internal", "x.localhost", "host.home.arpa", "box.lan", "box.home",
            "pc.corp", "a.test", "a.invalid", "abc.onion", "a.alt", "box.localdomain", "wiki.intranet", "nas.private",
            "127.0.0.1", "1.2.3.4", "2130706433", "0x7f.0x1", "0x7f000001", "017700000001", "example.123", "example.0x1",
            "[::1]", "::1", "[fe80::1]", "example.org:8443", "example.org:443", "user@example.org", "user:pw@example.org",
            "https://example.org", "http://example.org", "example.org/", "example.org/path", "example.org?x", "example.org#x",
            "bücher.example", "例え.jp", "", " ", "a..example", "-a.example", "a-.example", "example.org.", "*.example.org",
            "exa mple.org", "a_b.example", "a%2eb.example", "example.org\\@evil.example",
        ]
        for name in refused {
            #expect(Allowance.homeServer(name) == nil, "\(name)")
        }
    }

    // MARK: - The gate

    @Test("The gate lets a request to a server nobody added through only for this purpose, only while a press stands that named that very server, and only once for each press — by the one entry of its own, which the person may switch off; unpressed, spent, ended, of another server or for another purpose, nothing leaves and nothing is listed")
    func theGate() async throws {
        let work = SourceWork()
        work.govern(sources: [Self.one])
        func admitted(_ host: String = Self.home, for purpose: SourceWork.Purpose = .personHome) -> SourceWork.Admission? {
            work.admission(reached: host, source: nil, for: purpose)
        }
        #expect(admitted() == nil, "unpressed")
        let press = work.press(for: Self.home)
        #expect(admitted() == .allowed(.personHome))
        #expect(admitted(Self.other) == nil && admitted(for: .person) == nil && admitted(for: .picture) == nil)
        work.end(press)
        #expect(admitted() == nil, "ended")

        let entry = try #require(Allowance.standing.first { $0.id == .personHome })
        #expect(entry.when == .pressed)
        #expect(entry.reach == .request(.personHome))
        #expect(entry.hosts.isEmpty)
        #expect(!entry.allows(URL(string: "https://\(Self.home)/")!), "the entry lists no host of its own")
        #expect(!Allowance.applying(.forumPage).map(\.id).contains(.personHome))
        #expect(!Allowance.applying(.signingIn).map(\.id).contains(.personHome))

        // Through the door the app builds: one press is one request.
        let server = PageServer([Self.lookup("far"): Self.whole("far")])
        let reach = SourceReach(http: ServersByHost(servers: [Self.home: server]), work: work)
        let address = try #require(PersonAddress(typed: "@far@elsewhere.example"))
        await #expect(throws: PersonHomeError.unread) { try await reach.personHome(Self.home, within: .seconds(5)).person(address) }
        let unpressed = await server.asked
        #expect(unpressed.isEmpty && work.record.isEmpty, "unpressed, nothing left")

        let once = work.press(for: Self.home)
        let door = reach.personHome(Self.home, within: .seconds(5))
        #expect(try await door.person(address).handle == "@far@elsewhere.example")
        await #expect(throws: PersonHomeError.unread) { try await door.person(address) }
        let pressedOnce = await server.asked
        #expect(pressedOnce.count == 1 && work.record.count == 1, "the second request of one press never left")
        work.end(once)

        // Switched off, a press lets nothing through.
        work.allow(Allowance.standing.filter { $0.id != .personHome })
        let off = work.press(for: Self.home)
        #expect(admitted() == nil)
        await #expect(throws: PersonHomeError.unread) { try await door.person(address) }
        #expect(await server.asked.count == 1)
        work.end(off)
    }

    @Test("The ask stays at the server it was made of and under a small ceiling: an unsigned ask through the plain client would follow a redirect to another host, so this one goes through a client that refuses every redirect off its origin — another host, another port, plain http — takes no body past what a small ask may bring, keeps and sends no cookie of that server's, and leaves its name out of the log; and the file that makes the ask reaches for no sign-in")
    func whereItMayLead() throws {
        let ask = URLRequest(url: URL(string: "https://elsewhere.example/api/v1/accounts/lookup?acct=far")!)
        let away = URL(string: "https://evil.example/api/v1/accounts/lookup?acct=far")!
        #expect(CappedBody.mayFollow(from: ask, to: away), "what a plain unsigned ask would do")
        #expect(!CappedBody.mayFollow(from: ask, to: away, sameOriginOnly: true))
        #expect(!CappedBody.mayFollow(from: ask, to: URL(string: "https://elsewhere.example:8443/x")!, sameOriginOnly: true))
        #expect(!CappedBody.mayFollow(from: ask, to: URL(string: "http://elsewhere.example/x")!, sameOriginOnly: true))
        #expect(CappedBody.mayFollow(from: ask, to: URL(string: "https://elsewhere.example/x")!, sameOriginOnly: true))
        let live = try #require(SourceReach.ofAStranger(URLSessionClient()) as? URLSessionClient)
        #expect(live.sameOriginOnly)
        #expect(live.byteLimit == SourceReach.smallBody)
        #expect(live.watchedOnly)
        #expect(!live.namesHost)
        let configuration = live.session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)

        let reach = try String(contentsOf: Self.shell.appending(path: "SourceReach.swift"), encoding: .utf8)
        #expect(reach.contains("MastodonPersonHome(http: wire(Self.ofAStranger(http), for: .personHome, within: limit), host: host)"))
        let asks = try String(contentsOf: Self.shell.appending(path: "ShellPersonHome.swift"), encoding: .utf8)
        for word in ["authorized(", "token(", ".mastodon", "MastodonToken", "readers", "store.", "ingest"] {
            #expect(!asks.contains(word), "\(word)")
        }
        #expect(asks.components(separatedBy: "personHome(").count == 2, "one place makes the ask")
        // The page lets what that server said go when it leaves, and asks at the line's press alone.
        let pane = try String(contentsOf: Self.shell.appending(path: "TimelinePane.swift"), encoding: .utf8)
        #expect(pane.contains(".onDisappear { people?.home.letGo(of: person) }"))
        #expect(pane.contains("onHome: { press in Task { await people?.homePressed(press, on: person, in: session) } }"))
        #expect(pane.components(separatedBy: "homePressed(").count == 2)
        // What that server said is drawn with nothing in it to press, open or fetch.
        let page = try String(contentsOf: Self.shell.appending(path: "PersonPane.swift"), encoding: .utf8)
        #expect(page.contains("PersonSaidBlock(person: homeSaid.person, source: homeSaid.home, linked: false)"))
        #expect(page.components(separatedBy: "homeSaid.person").count == 2, "its block alone: nowhere a face or a list")
        let block = try String(contentsOf: Self.shell.appending(path: "PersonSaid.swift"), encoding: .utf8)
        #expect(block.contains("EmojiText.words(person.words, emojis: person.emojis, host: source, covered: !linked)"))
    }

    // MARK: - Answers that come late

    @Test("A press while the ask is out asks nothing more and the line says it is asking; the way back pressed while it is out, the page leaving, another person's press and the source being removed each leave what comes late — an answer or a failure — standing nowhere, over a wire that goes on answering an ask that was called off as over one that does not")
    func answersThatComeLate() async throws {
        let shell = try await shell()
        let pages = shell.pages, session = shell.session, home = try shell.server(Self.home), asked = Self.lookup("far")
        await pages.opened(Self.far, in: session)
        await pages.opened(Self.near, in: session)
        await home.hold(asked)
        defer { Task { await home.release(asked) } }

        let first = Task { await pages.homePressed(.ask, on: Self.far, in: session) }
        await home.arrival(of: asked)
        #expect(pages.homeLine(of: Self.far, in: session) == PersonHomeLine(words: "Asking elsewhere.example…"))
        let second = Task { await pages.homePressed(.ask, on: Self.far, in: session) }
        await Task.yield()
        await home.release(asked)
        await first.value
        await second.value
        #expect(await home.asked == [asked], "the press made while it was out asked nothing")
        #expect(pages.homeSaid(of: Self.far, in: session) != nil)

        // The way back pressed while a further ask is out.
        await home.hold(asked)
        await pages.homePressed(.back, on: Self.far, in: session)
        let backed = Task { await pages.homePressed(.ask, on: Self.far, in: session) }
        await home.arrival(of: asked, times: 2)
        await pages.homePressed(.back, on: Self.far, in: session)
        #expect(pages.home.stands(for: Self.far) == nil && pages.homeLine(of: Self.far, in: session) == Self.offer)
        await home.release(asked)
        await backed.value
        #expect(pages.home.stands(for: Self.far) == nil, "nothing is left asking, and nothing lands")
        #expect(shell.work.admission(reached: Self.home, source: nil, for: .personHome) == nil, "its press ended with it")

        // From here over a wire that answers whole and late whatever became of the ask.
        pages.home.reaching = { host in MastodonPersonHome(http: home, host: host) }
        await home.hold(asked)
        let left = Task { await pages.homePressed(.ask, on: Self.far, in: session) }
        await home.arrival(of: asked, times: 3)
        pages.home.letGo(of: Self.far)
        await home.release(asked)
        await left.value
        #expect(pages.home.stands(for: Self.far) == nil && pages.homeSaid(of: Self.far, in: session) == nil, "the page left")
        #expect(shell.work.admission(reached: Self.home, source: nil, for: .personHome) == nil, "a press whose request never passed the gate is ended all the same")

        // Another person's press while this one is out.
        let theirs = try shell.server(Self.other)
        await home.hold(asked)
        let slow = Task { await pages.homePressed(.ask, on: Self.far, in: session) }
        await home.arrival(of: asked, times: 4)
        pages.home.reaching = { host in MastodonPersonHome(http: host == Self.home ? home : theirs, host: host) }
        await pages.homePressed(.ask, on: Self.near, in: session)
        let nearSaid = try #require(pages.homeSaid(of: Self.near, in: session))
        await home.release(asked)
        await slow.value
        #expect(pages.homeSaid(of: Self.near, in: session) == nearSaid && pages.home.stands(for: Self.far) == nil)
        #expect(pages.homeSaid(of: Self.far, in: session) == nil, "what one person's server said is drawn on no other page")

        // The same with a failure come late.
        await home.answer(asked, PageServer.Answer(body: "", status: 500))
        await home.hold(asked)
        let failing = Task { await pages.homePressed(.ask, on: Self.far, in: session) }
        await home.arrival(of: asked, times: 5)
        await pages.homePressed(.ask, on: Self.near, in: session)
        await home.release(asked)
        await failing.value
        #expect(pages.homeSaid(of: Self.near, in: session) != nil && pages.home.stands(for: Self.far) == nil)

        // And with the wire saying, late, that the ask was walked away from.
        await home.answer(asked, PageServer.Answer(body: "", cancelled: true))
        await home.hold(asked)
        let walked = Task { await pages.homePressed(.ask, on: Self.far, in: session) }
        await home.arrival(of: asked, times: 6)
        await pages.homePressed(.ask, on: Self.near, in: session)
        await home.release(asked)
        await walked.value
        #expect(pages.homeSaid(of: Self.near, in: session) != nil, "a late walking-away takes nothing of the newer ask")

        // The source the page is of removed while the ask is out.
        await home.answer(asked, Self.whole("far"))
        await home.hold(asked)
        let removed = Task { await pages.homePressed(.ask, on: Self.far, in: session) }
        await home.arrival(of: asked, times: 7)
        #expect(pages.home.stands(for: Self.far) == .asking)
        session.sources.removeAll { $0.host == Self.one }
        await home.release(asked)
        await removed.value
        #expect(pages.home.stands(for: Self.far) == nil, "no page is left to say it on")
        #expect(pages.homeLine(of: Self.far, in: session) == nil && pages.homeSaid(of: Self.far, in: session) == nil)
    }

    @Test("The entry switched off while their own server's word is drawn takes that word off the page with no press, and the added source's view is drawn as the way back leaves it; switched off while an ask is out, the answer that then arrives lands nowhere, and is not there when the entry is switched on again")
    func switchedOffMeanwhile() async throws {
        let shell = try await shell()
        let pages = shell.pages, session = shell.session, home = try shell.server(Self.home), asked = Self.lookup("far")
        let without = Allowance.standing.filter { $0.id != .personHome }
        await pages.opened(Self.far, in: session)
        let before = try #require(pages.said(of: Self.far, in: session))
        await pages.homePressed(.ask, on: Self.far, in: session)
        #expect(pages.homeSaid(of: Self.far, in: session) != nil)
        #expect(pages.lists(of: Self.far, in: session).isEmpty)

        shell.work.allow(without)
        #expect(pages.homeSaid(of: Self.far, in: session) == nil)
        #expect(pages.homeLine(of: Self.far, in: session) == nil)
        #expect(pages.said(of: Self.far, in: session) == before)
        #expect(pages.lists(of: Self.far, in: session).count == 2, "the source's figures are on the page again")

        // Switched off while an ask is out.
        shell.work.allow(Allowance.standing)
        await pages.homePressed(.back, on: Self.far, in: session)
        await home.hold(asked)
        defer { Task { await home.release(asked) } }
        let out = Task { await pages.homePressed(.ask, on: Self.far, in: session) }
        await home.arrival(of: asked, times: 2)
        #expect(pages.home.stands(for: Self.far) == .asking)
        shell.work.allow(without)
        await home.release(asked)
        await out.value
        #expect(pages.home.stands(for: Self.far) == nil, "the answer landed nowhere")
        shell.work.allow(Allowance.standing)
        #expect(pages.homeSaid(of: Self.far, in: session) == nil)
        #expect(pages.homeLine(of: Self.far, in: session) == Self.offer)
        #expect(pages.said(of: Self.far, in: session) == before)
    }

    // MARK: - Said and drawn

    @Test("Every sentence of the press, its outcomes, its purpose and its entry is written in each language the app speaks, with the places it fills, and the two Chinese tables alike")
    func writtenInEveryLanguage() throws {
        let resources = Self.shell.deletingLastPathComponent().appending(path: "Resources")
        let english = try String(contentsOf: resources.appending(path: "en.lproj/Localizable.strings"), encoding: .utf8)
        let ours = ["\"person.home.", "\"allow.personHome.", "\"allow.when.pressed\"", "\"allow.hosts.pressed\"", "\"work.purpose.personHome\""]
        let keys = english.split(separator: "\n").compactMap { line -> String? in
            guard ours.contains(where: line.hasPrefix) else { return nil }
            return line.dropFirst().split(separator: "\"").first.map(String.init)
        }
        #expect(keys.count == 14)
        for key in ["person.home.noAccount", "person.home.nobody", "person.home.unread", "person.home.back"] {
            #expect(keys.contains(key), "\(key)")
        }
        func places(_ text: String) -> [String] {
            text.matches(of: /%(\d\$)?[@d]/).map { String($0.output.0) }.sorted()
        }
        for key in keys {
            let written = L10n.t(key, language: .english)
            #expect(written != key && !written.contains("%d"), "\(key)")
            for language in DummyLanguage.allCases {
                let other = L10n.t(key, language: language)
                #expect(other != key && places(other) == places(written), "\(key) in \(language)")
            }
        }
        let taiwan = try Data(contentsOf: resources.appending(path: "zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appending(path: "zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
        // The entry says what that server learns by being asked.
        #expect(L10n.t("allow.personHome.why", language: .english).contains("it learns this device's address and whom you asked about"))
        #expect(L10n.t("allow.personHome.why", language: .taiwanese).contains("那個站台會知道這台裝置的位址以及你問的是誰"))
        let entry = try #require(Allowance.standing.first { $0.id == .personHome })
        #expect(entry.whenText(language: .english) == "Only at your press on a person's page, once for each press")
        #expect(entry.hostsText(language: .english) == "The server named on the press")
        #expect(!SourceWork.Purpose.personHome.isOfTheSource && !SourceWork.Purpose.personHome.gathers && !SourceWork.Purpose.personHome.symbol.isEmpty)
    }

    @Test("The line in each of its states, and the page drawing what somebody's own server said, are laid out to the width they are given and never past it, in light and in dark")
    func laidOut() throws {
        let long = String(repeating: "long", count: 30)
        let lines = [
            PersonHomeLine(press: .ask, pressWords: "Ask \(long).example"),
            PersonHomeLine(words: "Asking \(long).example…"),
            PersonHomeLine(words: "The posts below are what \(long).example gave.", press: .back, pressWords: "Back to what \(long).example says"),
            PersonHomeLine(words: Self.noAccount, press: .ask, pressWords: "Ask elsewhere.example", failed: true),
            PersonHomeLine(words: Self.nobody, press: .ask, pressWords: "Ask elsewhere.example", failed: true),
        ]
        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (390, .dark), (320, .light)] {
            for line in lines {
                let hosted = NSHostingView(
                    rootView: VStack(spacing: 0) { PersonHomeLineView(line: line, onPress: { _ in }) }.frame(width: width)
                        .environment(\.colorScheme, scheme)
                )
                hosted.layoutSubtreeIfNeeded()
                #expect(hosted.fittingSize.width == width && hosted.fittingSize.height > 0, "at \(width)")
            }
        }
        let theirs = Person(
            source: Source(host: Self.home, kind: .mastodon), accountID: "5", handle: "@far@elsewhere.example", name: long,
            words: "\(long) https://elsewhere.example/more #tag", fields: [Person.Field(name: "Site", value: long)],
            tally: Person.Tally(posts: 1_204, following: 310, followers: 2_811), locked: true, suspended: true
        )
        let partly = Person(source: Self.source, accountID: "77", handle: "@far@elsewhere.example", name: "Partly")
        let home = PersonHomeSaid(home: Self.home, person: theirs, at: Date(timeIntervalSince1970: 1_700_000_000))
        let pages: [(PersonSaid, PersonHomeLine, PersonHomeSaid?)] = [
            (PersonSaid(source: Self.one, reading: .said(partly), posts: []), lines[2], home),
            (PersonSaid(source: Self.one, reading: .said(partly), posts: []), lines[0], nil),
            (PersonSaid(source: Self.one, reading: .unheardOf), lines[3], nil),
        ]
        for (said, line, drawn) in pages {
            let pane = PersonPane(
                person: Self.far, items: [], catalogues: EmojiCatalogueStore(), posts: ForumPosts(), selectedID: .constant(nil),
                decks: .constant(ShellDecks()), playback: ShellPlayback(), onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in },
                onOpenThread: { _ in }, jumpToTop: 0, onBack: {}, said: said, home: line, homeSaid: drawn
            )
            let hosted = NSHostingView(rootView: pane.frame(width: 320, height: 700))
            hosted.layoutSubtreeIfNeeded()
            #expect(hosted.fittingSize == CGSize(width: 320, height: 700))
        }
    }
}
