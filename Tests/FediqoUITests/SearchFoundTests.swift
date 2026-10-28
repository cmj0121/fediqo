import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #319: what a search finds beside posts — the people and the hashtags each source's one
/// answer carries, as bands over the posts — and somebody looked up through a source by their
/// address, at a press and never without one. And that a forum is searched as it always was.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), tied to the work that
/// made the ask where a check can name it: a held ask is let go by the check, and by a guard
/// when the run has gone still; every deadline is on a clock nobody turns.
@MainActor
@Suite("What a search finds beside posts, and somebody looked up through a source", .serialized, .watched)
struct SearchFoundTests {
    private static let one = "m.example", two = "n.example"
    private static let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 34, name: "Dev")])
    private static let shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/FediqoUI/Shell")

    init() {
        L10n.language = .english
    }

    /// An ask of a source's search, as the one signed-in door spells it.
    private static func ask(_ words: [(String, String)]) -> String {
        let url = Host.httpsURL(host: one, path: "/api/v2/search", query: words.map { URLQueryItem(name: $0.0, value: $0.1) })
        return "/api/v2/search?" + (url?.query(percentEncoded: true) ?? "")
    }

    /// The one ask a Return makes of a source.
    private static func returned(_ words: String) -> String {
        ask([("q", words), ("resolve", "false"), ("limit", "40")])
    }

    private static func lookedUp(_ address: String) -> String {
        ask([("q", address), ("resolve", "true"), ("type", "accounts"), ("limit", "5")])
    }

    private static func people(_ words: String, after passed: Int = 0) -> String {
        ask([("q", words), ("resolve", "false"), ("type", "accounts"), ("limit", "40")] + (passed > 0 ? [("offset", String(passed))] : []))
    }

    private static func account(_ id: Int, _ acct: String? = nil) -> String {
        #"{"id":"\#(id)","acct":"\#(acct ?? "p\(id)")","display_name":"Person \#(id)","note":"<p>Words of \#(id)</p>"}"#
    }

    private static func status(_ id: Int, on host: String) -> String {
        #"{"id":"\#(id)","uri":"https://\#(host)/users/ada/statuses/\#(id)","created_at":"2024-02-0\#(id)T00:00:00.000Z","content":"<p>cats \#(id)</p>","account":{"id":"9","username":"ada","acct":"ada","display_name":"Ada"}}"#
    }

    private static func answer(people: Int = 0, tags: [String] = [], posts: [Int] = [], on host: String = one) -> PageServer.Answer {
        let accounts = (0..<people).map { account($0 + 1) }.joined(separator: ",")
        let hashtags = tags.map { #"{"name":"\#($0)","history":[{"day":"1700086400","accounts":"3","uses":"4"}]}"# }.joined(separator: ",")
        let statuses = posts.map { status($0, on: host) }.joined(separator: ",")
        return PageServer.Answer(body: #"{"accounts":[\#(accounts)],"statuses":[\#(statuses)],"hashtags":[\#(hashtags)]}"#)
    }

    private static let far = PageServer.Answer(body: #"{"accounts":[\#(account(77, "far@elsewhere.example"))],"statuses":[],"hashtags":[]}"#)
    private static let nothing = PageServer.Answer(body: #"{"accounts":[],"statuses":[],"hashtags":[]}"#)
    private static let refused = PageServer.Answer(body: #"{"error":"This action is outside the authorized scopes"}"#, status: 403)
    private static let address = PersonAddress(typed: "@far@elsewhere.example")!

    /// Two sources that say who people are and a forum, each with a server of its own.
    private func shell(
        _ first: [String: PageServer.Answer] = [:], _ second: [String: PageServer.Answer] = [:], sources: [Source]? = nil,
        signedIn: [String] = [one, two]
    ) async throws -> (ShellSession, [String: PageServer], SourceWork) {
        let servers = [Self.one: PageServer(first), Self.two: PageServer(second), Self.forum.host: PageServer([:])]
        let router = ServersByHost(servers: servers)
        let session = ShellSession(
            http: router, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: router)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        let joined = sources ?? [Source(host: Self.one, kind: .mastodon), Source(host: Self.two, kind: .mastodon), Self.forum]
        for source in joined { await session.store.add(source) }
        session.sources = await session.store.sources()
        for host in signedIn { try signIn(session, at: host, as: "tok") }
        return (session, servers, work)
    }

    /// Signs whoever is signed in at `host` out and `access` in — with the words `scopes`,
    /// where the sign-in wrote them down.
    private func signIn(_ session: ShellSession, at host: String = one, as access: String, scopes: String? = nil) throws {
        try signOut(session, at: host)
        try session.mastodon.tokens.save(MastodonToken(host: host, accessToken: access, clientID: "c", clientSecret: "s", scopes: scopes))
        session.mastodon.refresh()
    }

    private func signOut(_ session: ShellSession, at host: String = one) throws {
        if let held = try session.mastodon.tokens.token(host: host) {
            _ = try session.mastodon.tokens.forget(held)
            session.mastodon.refresh()
        }
    }

    private func handles(_ bands: SearchBands) -> [String] { bands.people.map(\.handle) }

    // MARK: - What a Return brings

    @Test("Return asks each source that can be searched once — one ask, unresolved, as whoever is signed in, listed in the run's record as a search of that source and nothing more — and what each found beside posts stands as that source's own bands in the order the sources stand, never merged: three rows a kind and a press for all where there are more, each row its own. The posts land as they always did, and a forum is asked nothing")
    func aReturnBringsBands() async throws {
        let (session, servers, work) = try await shell(
            [Self.returned("cats"): Self.answer(people: 5, tags: ["Cats", "cats", "catsofmastodon", "Catus", "caturday", "catnip"], posts: [7])],
            [Self.returned("cats"): Self.answer(people: 2, tags: ["cats"], on: Self.two)]
        )
        let found = ShellPersonPages().found
        #expect(found.said(for: "cats", in: session).isEmpty, "before anything was asked")

        await session.reload.search("cats", timeline: .all, found: found, in: session)
        for host in [Self.one, Self.two] {
            #expect(await servers[host]?.asked == [Self.returned("cats")])
            #expect(await servers[host]?.bearers == ["Bearer tok"])
        }
        #expect(await servers[Self.forum.host]?.asked.isEmpty == true)
        let reached = work.record.map(\.reached).sorted(), purposes = Set(work.record.map(\.purpose))
        #expect(reached == [Self.one, Self.two] && purposes == [.search] && work.record.allSatisfy { $0.source == $0.reached })

        let bands = found.said(for: "cats", in: session)
        #expect(bands.map(\.source) == [Self.one, Self.two] && bands.allSatisfy { $0.words == "cats" })
        let firstFive: [String] = (1...5).map { "@p\($0)@\(Self.one)" }
        let secondTwo: [String] = ["@p1@\(Self.two)", "@p2@\(Self.two)"]
        #expect(handles(bands[0]) == firstFive && handles(bands[1]) == secondTwo)
        #expect(bands[0].tags.map(\.tag.text) == ["#Cats", "#catsofmastodon", "#Catus", "#caturday", "#catnip"], "a hashtag given twice, however written, is listed once")
        #expect(bands[0].tags[0].use == RisingUse(posts: 4, people: 3, days: 1))
        let all = PeopleList(foundAt: Self.one, words: "cats"), page = FoundTags(source: Self.one, words: "cats")
        let firstPeople: [SearchFoundRow] = bands[0].people.prefix(3).map(SearchFoundRow.person) + [.allPeople(all, given: 5)]
        let firstTags: [SearchFoundRow] = bands[0].tags.prefix(3).map { .tag($0, source: Self.one) } + [.allTags(page, given: 5)]
        #expect(bands[0].peopleRows == firstPeople && bands[0].tagRows == firstTags)
        #expect(bands[1].rows.count == 3, "two people and a hashtag, and no press for all: there are no more")
        let ids = found.walked(for: "cats", in: session)
        #expect(ids.count == 11 && Set(ids).count == 11, "the same name on two sources is two rows")
        #expect(found.row(ids[3], for: "cats", in: session) == .allPeople(all, given: 5) && found.row("nothing", for: "cats", in: session) == nil)
        #expect(ids[0] == bands[0].people[0].id && ids[3] == all.id, "a person's row is that person, and a list's press that list")

        // The posts are held as items, as they were; the people and the hashtags are held nowhere.
        #expect(session.notes.map(\.id) == ["https://\(Self.one)/users/ada/statuses/7"])
        #expect(session.reload.line == nil && !session.reload.running)
        // Drawn only while the field says the words that were asked.
        #expect(found.said(for: "cat", in: session).isEmpty && found.said(for: "", in: session).isEmpty)
        #expect(found.said(for: "cats*", in: session).count == 2, "a wildcard is not a word the source was sent")

        #expect(SearchBands.peopleHead(Self.one) == "People · m.example" && SearchBands.tagsHead(Self.one) == "Hashtags · m.example")
        #expect(SearchBands.postsHead("All") == "Posts · All")
        #expect(SearchBands.all(5) == "All 5" && SearchBands.all(40) == "The first 40" && SearchBands.all(1_204) == "The first 1,204")
        #expect(SearchBands.spoken(.allPeople(all, given: 5)) == "All 5: the people m.example found.")
        #expect(SearchBands.spoken(.allTags(page, given: 40)) == "The first 40: the hashtags m.example found.")
        #expect(SearchBands.spoken(firstPeople[0]) == nil)
    }

    @Test("A forum's search is as it was: with only a forum added Return asks nobody, nothing is found beside posts, no band stands and no press is offered for an address typed; beside a source that says who people are the forum is still asked nothing and has no band")
    func aForumIsAsItWas() async throws {
        let (alone, servers, work) = try await shell(sources: [Self.forum], signedIn: [])
        let found = ShellPersonPages().found
        found.opened(in: alone)
        await alone.reload.search("cats", timeline: .all, found: found, in: alone)
        #expect(alone.reload.reach == ShellReload.SearchReach(asked: [], unasked: [Self.forum.host]))
        #expect(alone.reload.reach?.sentence == nil)
        let unasked = alone.reload.reach?.unaskedLines(language: .english)
        #expect(unasked?.map(\.host) == [Self.forum.host])
        #expect(unasked?.first?.needsReader == true && unasked?.first?.press == nil)
        #expect(unasked?.first?.words == "Not asked, as it cannot be searched from here: forum.example.")
        #expect(found.said(for: "cats", in: alone).isEmpty && found.walked(for: "cats", in: alone).isEmpty)
        #expect(found.line(typed: "@far@elsewhere.example", in: alone) == nil, "no press, and no sentence about one")
        await found.lookUp(Self.address, through: Self.forum.host, in: alone)
        for server in servers.values { #expect(await server.asked.isEmpty) }
        #expect(work.record.isEmpty && found.looked(Self.address) == nil)
        #expect(!ShellPersonPages.saysPeople(Self.forum) && !ProtocolKind.discuz.offers.people && !ProtocolKind.discourse.offers.people)

        let (mixed, both, _) = try await shell([Self.returned("cats"): Self.answer(people: 1)], signedIn: [Self.one])
        await mixed.reload.search("cats", timeline: .all, found: found, in: mixed)
        #expect(mixed.reload.reach?.asked == [Self.one] && mixed.reload.reach?.unasked == [Self.two, Self.forum.host])
        #expect(found.said(for: "cats", in: mixed).map(\.source) == [Self.one])
        #expect(await both[Self.forum.host]?.asked.isEmpty == true)
        #expect(await both[Self.two]?.asked.isEmpty == true)
        // A band handed in for a forum is not kept: the object asks the one fact, and nothing else.
        let sent = found.sending("cats", to: [Self.forum.host, Self.one], in: mixed)
        #expect(sent.askedAs.keys.sorted() == [Self.one])
        found.landed(SearchFinds(people: [Person(source: Self.forum, accountID: "1", handle: "@a@forum.example", name: "a")]), at: Self.forum.host, of: sent, in: mixed)
        #expect(found.said(for: "cats", in: mixed).isEmpty)
        // The page files look at no kind of source.
        for file in ["SearchFound.swift", "SearchBar.swift"] {
            let text = try String(contentsOf: Self.shell.appending(path: file), encoding: .utf8)
            #expect(!text.contains(".kind") && !text.contains("ProtocolKind") && !text.contains("== .mastodon") && !text.contains("case .mastodon"), "\(file)")
        }
        let offers = try String(contentsOf: Self.shell.deletingLastPathComponent().deletingLastPathComponent().appending(path: "FediqoCore/SourceOffers.swift"), encoding: .utf8)
        #expect(!offers.lowercased().contains("search"))
    }

    // MARK: - Late answers

    @Test("An answer that comes after another Return is not kept: the first Return's ask is held, a second is made and answered, and when the first is let go what it brings stands nowhere — and an answer handed in under an older Return's number is refused by the keeper itself")
    func aLateAnswerAfterAnotherReturn() async throws {
        let (session, servers, _) = try await shell([
            Self.returned("cats"): Self.answer(people: 4, tags: ["cats"]), Self.returned("dogs"): Self.answer(people: 1, tags: ["dogs"]),
        ], signedIn: [Self.one])
        let server = try #require(servers[Self.one]), found = ShellPersonPages().found
        await server.hold(Self.returned("cats"))
        defer { Task { await server.release(Self.returned("cats")) } }
        let returnedCatsGuard = watching("the ask of \(Self.returned("cats")), held at its server") { await server.release(Self.returned("cats")) }
        defer { returnedCatsGuard.cancel() }
        let first = Task { await session.reload.search("cats", timeline: .all, found: found, in: session) }
        await server.arrival(of: Self.returned("cats"), by: first)
        #expect(session.reload.asking.contains(.search) && found.said(for: "cats", in: session).isEmpty)

        await session.reload.search("dogs", timeline: .all, found: found, in: session)
        #expect(found.said(for: "dogs", in: session).map(\.people.count) == [1])
        await server.release(Self.returned("cats"))
        await first.value
        #expect(found.said(for: "cats", in: session).isEmpty && found.said(for: "dogs", in: session).map(\.people.count) == [1])
        #expect(!session.reload.asking.contains(.search), "nothing is left asking with nothing on the wire")

        // The keeper's own rule, with no reload in front of it.
        let old = found.sending("cats", to: [Self.one], in: session)
        let new = found.sending("dogs", to: [Self.one], in: session)
        let late = SearchFinds(people: [Person(source: Source(host: Self.one, kind: .mastodon), accountID: "1", handle: "@a@m.example", name: "a")])
        found.landed(late, at: Self.one, of: old, in: session)
        #expect(found.said(for: "cats", in: session).isEmpty && found.said(for: "dogs", in: session).isEmpty)
        found.refused(at: Self.one, of: old, in: session)
        #expect(found.line(typed: "@far@elsewhere.example", in: session)?.press == .lookUp(Self.address, through: Self.one), "a late refusal is not believed either")
        found.landed(late, at: Self.one, of: new, in: session)
        #expect(found.said(for: "dogs", in: session).map(\.people.count) == [1])
        // And once the search's ask has ended, no Return's answer is awaited at all.
        found.ended()
        found.landed(late, at: Self.one, of: new, in: session)
        #expect(found.said(for: "dogs", in: session).isEmpty)
    }

    @Test("The timeline under an open search switched: what was sent is sent again to the new one's sources, and what they find beside posts stands for it — the last timeline's bands went with its ask; typed over since Return, the switch ends the ask and the bands with it")
    func switchedUnderTheSearch() async throws {
        let (session, servers, _) = try await shell([Self.returned("cats"): Self.answer(people: 2)], signedIn: [Self.one])
        let server = try #require(servers[Self.one]), found = ShellPersonPages().found
        var draft = TimelineDraft(new: session.written.count + 1)
        draft.name = "Wire"
        draft.rules = [try #require(Rule.keyword("wire", in: .every))]
        session.commit(draft)
        session.timelineID = .all
        await session.reload.search("cats", timeline: .all, found: found, in: session)
        #expect(found.said(for: "cats", in: session).count == 1)
        await server.answer(Self.returned("cats"), Self.answer(people: 4))
        session.timelineID = .written(draft.id)
        await session.reload.searchSwitched(to: .written(draft.id), pattern: "cats", in: session)
        #expect(await server.asked.count == 2)
        #expect(found.said(for: "cats", in: session).map(\.people.count) == [4], "the new timeline's ask, handed to the same keeper")
        session.timelineID = .all
        await session.reload.searchSwitched(to: .all, pattern: "dogs", in: session)
        #expect(await server.asked.count == 2)
        #expect(found.said(for: "cats", in: session).isEmpty && session.reload.reach == nil)
    }

    @Test("The search closed, or its field emptied, while its ask is out: the ask ends, what it brings late stands nowhere, and what stood goes. The same Return made again while it is on the wire asks nothing")
    func closedWhileOut() async throws {
        let (session, servers, _) = try await shell([Self.returned("cats"): Self.answer(people: 4)], signedIn: [Self.one])
        let server = try #require(servers[Self.one]), found = ShellPersonPages().found
        await server.hold(Self.returned("cats"))
        defer { Task { await server.release(Self.returned("cats")) } }
        let returnedCatsGuard = watching("the ask of \(Self.returned("cats")), held at its server") { await server.release(Self.returned("cats")) }
        defer { returnedCatsGuard.cancel() }
        let first = Task { await session.reload.search("cats", timeline: .all, found: found, in: session) }
        await server.arrival(of: Self.returned("cats"), by: first)
        // A Return that waited for the index, made again: the ask on the wire is let run.
        await session.reload.search("cats", timeline: .all, found: found, in: session)
        #expect(await server.asked.count == 1)

        session.reload.endSearch()
        found.closed()
        #expect(!session.reload.asking.contains(.search))
        await server.release(Self.returned("cats"))
        await first.value
        #expect(found.said(for: "cats", in: session).isEmpty)

        // Answered, and then closed: what stood goes.
        await session.reload.search("cats", timeline: .all, found: found, in: session)
        #expect(found.said(for: "cats", in: session).count == 1)
        session.reload.endSearch()
        #expect(found.said(for: "cats", in: session).isEmpty, "ending the search's ask ends what it brought")
    }

    @Test("What one sign-in was given is not shown to the next: a sign-in replaced by another while the ask is out is not handed the answer; bands that stand are let go when the sign-in is seen to have changed, and are not drawn for nobody once it has ended")
    func notShownToTheNextSignIn() async throws {
        let (session, servers, _) = try await shell([Self.returned("cats"): Self.answer(people: 4)], signedIn: [Self.one])
        let server = try #require(servers[Self.one]), pages = ShellPersonPages(), found = pages.found
        await server.hold(Self.returned("cats"))
        defer { Task { await server.release(Self.returned("cats")) } }
        let returnedCatsGuard = watching("the ask of \(Self.returned("cats")), held at its server") { await server.release(Self.returned("cats")) }
        defer { returnedCatsGuard.cancel() }
        let first = Task { await session.reload.search("cats", timeline: .all, found: found, in: session) }
        await server.arrival(of: Self.returned("cats"), by: first)
        // Another account at the same source, which the source has named no more than the first.
        try signIn(session, as: "other")
        await server.release(Self.returned("cats"))
        await first.value
        #expect(found.said(for: "cats", in: session).isEmpty, "the first reader's answer is not the second's")

        session.reload.endSearch()
        await session.reload.search("cats", timeline: .all, found: found, in: session)
        #expect(found.said(for: "cats", in: session).count == 1)
        #expect(await server.bearers.last == "Bearer other")
        // Seen to have changed at the next press anywhere among the pages: let go.
        try signIn(session, as: "third")
        await pages.rising.opened(.tags, in: session)
        session.mastodon.refresh()
        #expect(found.said(for: "cats", in: session).isEmpty)

        session.reload.endSearch()
        await session.reload.search("cats", timeline: .all, found: found, in: session)
        #expect(found.said(for: "cats", in: session).count == 1)
        try signOut(session)
        #expect(found.said(for: "cats", in: session).isEmpty, "drawn for whoever would ask now, and nobody would")
        #expect(found.said(of: FoundTags(source: Self.one, words: "cats"), in: session) == nil)
    }

    @Test("A source that refuses for want of search, and one that fails, say so in the search's own line as they always did, and nothing is found there beside posts while the others land; the refusal is remembered, and the look-up says why it is not offered through that source")
    func refusedAndFailed() async throws {
        let (session, _, _) = try await shell(
            [Self.returned("cats"): Self.refused], [Self.returned("cats"): Self.answer(people: 1)]
        )
        let found = ShellPersonPages().found
        #expect(found.line(typed: "@far@elsewhere.example", in: session)?.press == .lookUp(Self.address, through: Self.one))
        await session.reload.search("cats", timeline: .all, found: found, in: session)
        #expect(session.reload.searchRefused == [Self.one])
        #expect(session.reload.line == "Could not search m.example: sign in to it again to let Fediqo search there.")
        #expect(found.said(for: "cats", in: session).map(\.source) == [Self.two])
        #expect(found.line(typed: "@far@elsewhere.example", in: session)?.press == .lookUp(Self.address, through: Self.two), "through the one that may search")

        let (alone, servers, _) = try await shell([Self.returned("cats"): Self.refused], signedIn: [Self.one])
        await alone.reload.search("cats", timeline: .all, found: found, in: alone)
        let line = try #require(found.line(typed: "@far@elsewhere.example", in: alone))
        #expect(line.press == nil && line.words == "m.example cannot be asked to look anybody up, or for the people and hashtags it finds: this sign-in was made without search. Sign in to it again to let Fediqo search there.")
        await found.lookUp(Self.address, through: Self.one, in: alone)
        #expect(await servers[Self.one]?.asked == [Self.returned("cats")], "and pressed all the same, nothing is asked")

        let (failing, _, _) = try await shell([Self.returned("cats"): PageServer.Answer(body: "", status: 500)], signedIn: [Self.one])
        await failing.reload.search("cats", timeline: .all, found: found, in: failing)
        #expect(failing.reload.line == "Could not search m.example." && found.said(for: "cats", in: failing).isEmpty)
    }

    // MARK: - Looking somebody up

    @Test("An address typed is offered one press that names the source it goes through, and nothing is asked by drawing it or by Return: a Return with an address typed asks unresolved, as any search. The press asks that one source to resolve it, signed in, of people alone — listed in the run's record as a look-up through that source — and nobody else is asked anything; who it found is said by the handle it gave, with the press that opens their page")
    func thePressLooksUp() async throws {
        let (session, servers, work) = try await shell([
            Self.lookedUp("@far@elsewhere.example"): Self.far, Self.returned("@far@elsewhere.example"): Self.nothing,
        ], [Self.returned("@far@elsewhere.example"): Self.nothing])
        let found = ShellPersonPages().found
        found.opened(in: session)
        let offer = try #require(found.line(typed: " @far@Elsewhere.example ", in: session))
        #expect(offer.words == nil && offer.press == .lookUp(Self.address, through: Self.one))
        #expect(offer.pressWords == "Look @far@elsewhere.example up through m.example")
        for typed in ["far", "@far", "cats and dogs", "#cats", "https://elsewhere.example/@far/1", "https://elsewhere.example/tags/x", ""] {
            #expect(found.line(typed: typed, in: session) == nil, "\(typed)")
        }
        #expect(found.line(typed: "https://elsewhere.example/@far", in: session)?.pressWords == "Look https://elsewhere.example/@far up through m.example")
        // Through the source the address itself names, where that is one of them.
        #expect(found.line(typed: "@ada@n.example", in: session)?.press == .lookUp(PersonAddress(typed: "@ada@n.example")!, through: Self.two))

        await session.reload.search("@far@elsewhere.example", timeline: .all, found: found, in: session)
        for host in [Self.one, Self.two] { #expect(await servers[host]?.asked == [Self.returned("@far@elsewhere.example")]) }
        #expect(found.said(for: "@far@elsewhere.example", in: session).isEmpty, "a source that found nobody and no hashtag has no band")
        #expect(work.record.allSatisfy { $0.purpose == .search }, "Return resolves nothing")

        await found.lookUp(Self.address, through: Self.one, in: session)
        #expect(await servers[Self.one]?.asked.last == Self.lookedUp("@far@elsewhere.example"))
        #expect(await servers[Self.one]?.bearers.last == "Bearer tok")
        #expect(await servers[Self.two]?.asked.count == 1)
        #expect(await servers[Self.forum.host]?.asked.isEmpty == true)
        let looked = work.record.filter { $0.purpose == .lookUp }
        #expect(looked.count == 1 && looked.allSatisfy { $0.reached == Self.one && $0.source == Self.one })
        #expect(Set(work.record.map(\.reached)) == [Self.one, Self.two], "nothing went to the server the address names")

        guard case .found(let person) = found.looked(Self.address) else {
            Issue.record("nobody was found")
            return
        }
        #expect(person.handle == "@far@elsewhere.example" && person.source.host == Self.one && !person.livesHere)
        let line = try #require(found.line(typed: "@far@elsewhere.example", in: session))
        #expect(line.words == "m.example found @far@elsewhere.example." && line.press == .open(person) && line.pressWords == "Open their page")
        #expect(ShellSearchFound.isThePage(DummyPerson(handle: "@FAR@elsewhere.example", host: Self.one)!, of: person))
        #expect(!ShellSearchFound.isThePage(DummyPerson(handle: "@near@elsewhere.example", host: Self.one)!, of: person))
        #expect(session.notes.isEmpty, "nothing is held by looking somebody up")
    }

    @Test("A press while the look-up is out asks nothing more; another address pressed calls the one out off, and what that brings late — an answer or a failure — does not replace what the newer one found; the search closed with a look-up out leaves nothing asking, and what comes late stands nowhere")
    func lookUpsOnTheWire() async throws {
        let near = PersonAddress(typed: "@near@elsewhere.example")!
        let nearFound = PageServer.Answer(body: #"{"accounts":[\#(Self.account(78, "near@elsewhere.example"))]}"#)
        let (session, servers, _) = try await shell([
            Self.lookedUp("@far@elsewhere.example"): Self.far, Self.lookedUp("@near@elsewhere.example"): nearFound,
        ], signedIn: [Self.one])
        let server = try #require(servers[Self.one]), found = ShellPersonPages().found
        let held = Self.lookedUp("@far@elsewhere.example")
        await server.hold(held)
        defer { Task { await server.release(held) } }
        let heldGuard = watching("the ask of \(held), held at its server") { await server.release(held) }
        defer { heldGuard.cancel() }
        let first = Task { await found.lookUp(Self.address, through: Self.one, in: session) }
        await server.arrival(of: held, by: first)
        let asking = try #require(found.line(typed: "@far@elsewhere.example", in: session))
        #expect(found.looked(Self.address) == .asking && asking.press == nil && asking.words == "Asking m.example to look @far@elsewhere.example up…")
        // Pressed again while it is out: the second press waits on the first, and asks nothing.
        // A press runs, with no wait, up to where it finds the look-up out.
        var pressedAgain = false
        let second = Task {
            pressedAgain = true
            await found.lookUp(Self.address, through: Self.one, in: session)
        }
        await met("the second press is made, the first look-up still out", by: second) { pressedAgain }
        await server.release(held)
        await first.value
        await second.value
        #expect(await server.asked == [held], "the press made while it was out asked nothing")
        guard case .found = found.looked(Self.address) else {
            Issue.record("the first address was not found")
            return
        }

        // Another address pressed while one is out, and answered at once: the first is called off.
        found.closed()
        await server.hold(held)
        let slow = Task { await found.lookUp(Self.address, through: Self.one, in: session) }
        await server.arrival(of: held, times: 2, by: slow)
        await found.lookUp(near, through: Self.one, in: session)
        guard case .found(let other) = found.looked(near) else {
            Issue.record("the second address was not found")
            return
        }
        await server.release(held)
        await slow.value
        #expect(found.looked(near) == .found(other) && found.looked(Self.address) == nil, "the first, come late, replaces nothing")

        // And over a wire that goes on answering an ask that was called off: its answer, come
        // whole and late, replaces nothing either.
        let tokens = session.mastodon.tokens
        found.reaching = { token in MastodonSearch(door: MastodonAuthorized(token: token, sender: server, store: tokens)) }
        found.closed()
        await server.hold(held)
        let deaf = Task { await found.lookUp(Self.address, through: Self.one, in: session) }
        await server.arrival(of: held, times: 3, by: deaf)
        await found.lookUp(near, through: Self.one, in: session)
        await server.release(held)
        await deaf.value
        #expect(found.looked(near) == .found(other) && found.looked(Self.address) == nil)
        found.reaching = nil

        // The same with a failure come late.
        await server.answer(held, PageServer.Answer(body: "", status: 500))
        await server.hold(held)
        let failing = Task { await found.lookUp(Self.address, through: Self.one, in: session) }
        await server.arrival(of: held, times: 4, by: failing)
        await found.lookUp(near, through: Self.one, in: session)
        await server.release(held)
        await failing.value
        #expect(found.looked(near) == .found(other))

        // Closed while one is out.
        await server.answer(held, Self.far)
        await server.hold(held)
        let closing = Task { await found.lookUp(Self.address, through: Self.one, in: session) }
        await server.arrival(of: held, times: 5, by: closing)
        found.closed()
        #expect(found.looked(Self.address) == nil && found.line(typed: "@far@elsewhere.example", in: session)?.press == .lookUp(Self.address, through: Self.one))
        await server.release(held)
        await closing.value
        #expect(found.looked(Self.address) == nil, "nothing is left asking, and nothing lands")
    }

    @Test("Who a look-up found is not kept for another sign-in: replaced while the look-up is out, the answer is nobody's; found, and the sign-in then seen to have changed or ended, the line offers the press afresh or says there is no sign-in")
    func aLookUpIsItsReaders() async throws {
        let (session, servers, _) = try await shell([Self.lookedUp("@far@elsewhere.example"): Self.far], signedIn: [Self.one])
        let server = try #require(servers[Self.one]), found = ShellPersonPages().found
        let held = Self.lookedUp("@far@elsewhere.example")
        await server.hold(held)
        defer { Task { await server.release(held) } }
        let heldGuard = watching("the ask of \(held), held at its server") { await server.release(held) }
        defer { heldGuard.cancel() }
        let first = Task { await found.lookUp(Self.address, through: Self.one, in: session) }
        await server.arrival(of: held, by: first)
        try signIn(session, as: "other")
        await server.release(held)
        await first.value
        #expect(found.looked(Self.address) == nil)

        await found.lookUp(Self.address, through: Self.one, in: session)
        #expect(found.looked(Self.address) != nil)
        #expect(await server.bearers.last == "Bearer other")
        try signOut(session)
        let line = try #require(found.line(typed: "@far@elsewhere.example", in: session))
        #expect(line.press == nil && line.words == "Nobody is signed in to a source here, so no source can be asked to look @far@elsewhere.example up.")
        await found.lookUp(Self.address, through: Self.one, in: session)
        #expect(await server.asked.count == 2, "with no sign-in nothing is asked")
        #expect(found.looked(Self.address) == nil, "and seen to have ended, what was found is let go")
    }

    @Test("A source that found nobody says so and does not say whether it reached their server; one that fails says so in full ink with the press that asks again; one that refuses for want of search is remembered and said in place of the press; an ask walked away from leaves nothing asking. A sign-in whose own words say it was made without search is offered no press, and the place says why")
    func whatALookUpComesTo() async throws {
        let wire = Self.lookedUp("@far@elsewhere.example")
        func come(_ answer: PageServer.Answer?) async throws -> (ShellSearchFound, SearchLookUpLine?, PageServer) {
            let (session, servers, _) = try await shell(answer.map { [wire: $0] } ?? [:], signedIn: [Self.one])
            let found = ShellPersonPages().found
            await found.lookUp(Self.address, through: Self.one, in: session)
            return (found, found.line(typed: "@far@elsewhere.example", in: session), try #require(servers[Self.one]))
        }
        let (nobody, unheard, _) = try await come(Self.nothing)
        #expect(nobody.looked(Self.address) == .unheardOf && unheard?.failed == false)
        #expect(unheard?.words == "m.example found nobody at @far@elsewhere.example. It does not say whether it reached their server.")
        #expect(unheard?.press == .lookUp(Self.address, through: Self.one) && unheard?.pressWords == "Try again")
        // Somebody else in the answer is not who was asked for.
        let (stranger, _, _) = try await come(PageServer.Answer(body: #"{"accounts":[\#(Self.account(5, "near@elsewhere.example"))]}"#))
        #expect(stranger.looked(Self.address) == .unheardOf)

        for failure in [PageServer.Answer(body: "", status: 500), PageServer.Answer(body: "[]"), nil] {
            let (failed, line, _) = try await come(failure)
            #expect(failed.looked(Self.address) == .failed && line?.failed == true && line?.pressWords == "Try again")
            #expect(line?.words == "Could not ask m.example to look @far@elsewhere.example up.")
        }
        let (refused, scope, _) = try await come(Self.refused)
        #expect(refused.looked(Self.address) == nil && scope?.press == nil && scope?.words?.hasPrefix("m.example cannot be asked to look anybody up") == true)
        let (walked, again, _) = try await come(PageServer.Answer(body: "", cancelled: true))
        #expect(walked.looked(Self.address) == nil && again?.press == .lookUp(Self.address, through: Self.one))

        let (narrow, servers, work) = try await shell(signedIn: [])
        try signIn(narrow, as: "tok", scopes: MastodonOAuth.readingWithoutSearch)
        let found = ShellPersonPages().found
        found.opened(in: narrow)
        let line = try #require(found.line(typed: "@far@elsewhere.example", in: narrow))
        #expect(line.press == nil && line.words?.contains("this sign-in was made without search") == true)
        await found.lookUp(Self.address, through: Self.one, in: narrow)
        #expect(await servers[Self.one]?.asked.isEmpty == true)
        #expect(work.record.isEmpty)
        // Signed in again with search: offered.
        try signIn(narrow, as: "wide", scopes: MastodonOAuth.reading)
        found.opened(in: narrow)
        #expect(found.line(typed: "@far@elsewhere.example", in: narrow)?.press == .lookUp(Self.address, through: Self.one))
    }

    @Test("A refusal or a failure that comes after the sign-in was replaced says nothing of the one there now: a Return's refusal for want of search come late does not take the press from the new sign-in, and a look-up's refusal, its failure and its nobody come late stand nowhere. And a 403 that is no refusal for want of search is a failure like any other, of a Return and of a look-up, and nothing is remembered of it")
    func lateRefusalsAndOtherRefusals() async throws {
        let wire = Self.lookedUp("@far@elsewhere.example"), typed = "@far@elsewhere.example"
        let (session, servers, _) = try await shell([Self.returned("cats"): Self.refused, wire: Self.refused], signedIn: [Self.one])
        let server = try #require(servers[Self.one]), found = ShellPersonPages().found
        let offer = SearchLookUpLine.Press.lookUp(Self.address, through: Self.one)
        await server.hold(Self.returned("cats"))
        defer { Task { await server.release(Self.returned("cats")) } }
        let returnedCatsGuard = watching("the ask of \(Self.returned("cats")), held at its server") { await server.release(Self.returned("cats")) }
        defer { returnedCatsGuard.cancel() }
        defer { Task { await server.release(wire) } }

        let returned = Task { await session.reload.search("cats", timeline: .all, found: found, in: session) }
        await server.arrival(of: Self.returned("cats"), by: returned)
        try signIn(session, as: "second")
        await server.release(Self.returned("cats"))
        await returned.value
        #expect(found.line(typed: typed, in: session)?.press == offer, "the first sign-in's refusal is not the second's")
        session.reload.endSearch()
        // The keeper's own rule, with no reload in front of it.
        let sent = found.sending("cats", to: [Self.one], in: session)
        try signIn(session, as: "third")
        found.refused(at: Self.one, of: sent, in: session)
        #expect(found.line(typed: typed, in: session)?.press == offer)
        found.ended()

        let late: [PageServer.Answer] = [Self.refused, PageServer.Answer(body: "", status: 500), Self.nothing]
        for (round, answer) in late.enumerated() {
            await server.answer(wire, answer)
            await server.hold(wire)
            let wireGuard = watching("the ask of \(wire), held at its server") { await server.release(wire) }
            defer { wireGuard.cancel() }
            let asked = Task { await found.lookUp(Self.address, through: Self.one, in: session) }
            await server.arrival(of: wire, times: round + 1, by: asked)
            try signIn(session, as: "later\(round)")
            await server.release(wire)
            await asked.value
            let line = found.line(typed: typed, in: session)
            #expect(found.looked(Self.address) == nil, "round \(round)")
            #expect(line?.press == offer && line?.failed == false && line?.words == nil, "round \(round)")
        }

        // Asked and refused as the sign-in still there: remembered, as it was.
        await server.answer(wire, Self.refused)
        await found.lookUp(Self.address, through: Self.one, in: session)
        #expect(found.line(typed: typed, in: session)?.press == nil)

        // A 403 that says something else — a login the server disabled.
        let disabled = PageServer.Answer(body: #"{"error":"Your login is currently disabled"}"#, status: 403)
        let (other, _, _) = try await shell([Self.returned("cats"): disabled, wire: disabled], signedIn: [Self.one])
        let keeper = ShellPersonPages().found
        await other.reload.search("cats", timeline: .all, found: keeper, in: other)
        #expect(other.reload.searchRefused.isEmpty && other.reload.line == "Could not search m.example.")
        #expect(keeper.line(typed: typed, in: other)?.press == offer)
        await keeper.lookUp(Self.address, through: Self.one, in: other)
        let failed = try #require(keeper.line(typed: typed, in: other))
        #expect(keeper.looked(Self.address) == .failed && failed.failed && failed.press == offer)
        #expect(failed.words == "Could not ask m.example to look @far@elsewhere.example up.")
    }

    @Test("Whoever a look-up found is said by the handle the source gave, whole: found at another server than the one typed, the line names that server in full however long its name, and the press opens their own page — the page of the address typed is asked again only where the very handle it names was found. Of two of the same name the one at the server typed is who was found")
    func foundAtAnotherServer() async throws {
        let wire = Self.lookedUp("@far@elsewhere.example"), typed = "@far@elsewhere.example"
        let longHost = String(repeating: "elsewhere.", count: 15) + "example"
        let moved = PageServer.Answer(body: #"{"accounts":[\#(Self.account(77, "far@\(longHost)"))]}"#)
        let (session, servers, _) = try await shell([wire: moved], signedIn: [Self.one])
        let server = try #require(servers[Self.one]), found = ShellPersonPages().found
        await found.lookUp(Self.address, through: Self.one, in: session)
        guard case .found(let person) = found.looked(Self.address) else {
            Issue.record("nobody was found")
            return
        }
        let given: String = "@far@\(longHost)"
        #expect(person.handle == given && person.lineHandle != given, "a row cuts a handle this long")
        #expect(ShellSearchFound.foundHandle(person) == given)
        let line = try #require(found.line(typed: typed, in: session))
        #expect(line.words == "m.example found \(given) — not the address you typed." && line.press == .open(person))
        // The page that was not heard of names another server: theirs is a page of its own.
        let standing = try #require(DummyPerson(handle: typed, host: Self.one))
        #expect(!ShellSearchFound.isThePage(standing, of: person))
        #expect(ShellSearchFound.isThePage(DummyPerson(person), of: person))
        let sameHandle = try #require(DummyPerson(handle: "@FAR@\(longHost.uppercased())", host: Self.one))
        #expect(ShellSearchFound.isThePage(sameHandle, of: person))
        let elsewhere = try #require(DummyPerson(handle: given, host: Self.two))
        #expect(!ShellSearchFound.isThePage(elsewhere, of: person), "the same handle at another source is another page")

        // What a stranger sent is still made fit for a line, and is no longer than a handle is.
        let source = Source(host: Self.one, kind: .mastodon)
        let odd = Person(source: source, accountID: "1", handle: "@far\u{202E}@x.example\n" + String(repeating: "a", count: 2_000), name: "far")
        let said = ShellSearchFound.foundHandle(odd)
        let most: Int = MastodonPerson.handleLength + 2
        #expect(said.hasPrefix("@far@x.example ") && said.count <= most)

        let two = #"{"accounts":[\#(Self.account(5, "far@evil.example")),\#(Self.account(6, "far@elsewhere.example"))]}"#
        await server.answer(wire, PageServer.Answer(body: two))
        found.closed()
        await found.lookUp(Self.address, through: Self.one, in: session)
        #expect(found.line(typed: typed, in: session)?.words == "m.example found @far@elsewhere.example.", "at the handle typed: the sentence it always was")

        // The address of a page: whoever's server gives that address is at it, whatever their
        // handle; somebody of the name alone is said not to be.
        let page = "https://elsewhere.example/@far", asked = Self.lookedUp(page)
        let address = try #require(PersonAddress(typed: page))
        let theirs = #"{"id":"8","acct":"far@other.example","url":"https://elsewhere.example/@far"}"#
        await server.answer(asked, PageServer.Answer(body: #"{"accounts":[\#(theirs)]}"#))
        await found.lookUp(address, through: Self.one, in: session)
        #expect(found.line(typed: page, in: session)?.words == "m.example found @far@other.example.")
        await server.answer(asked, PageServer.Answer(body: #"{"accounts":[\#(Self.account(9, "far@other.example"))]}"#))
        found.closed()
        await found.lookUp(address, through: Self.one, in: session)
        #expect(found.line(typed: page, in: session)?.words == "m.example found @far@other.example — not the address you typed.")
        #expect(found.line(typed: page, in: session, language: .taiwanese)?.words == "m.example 找到的是 @far@other.example——不是你輸入的地址。")
    }

    @Test("The page of somebody their source has not heard of offers the press through that source alone, where they live elsewhere and the reader is signed in to it; with no sign-in there it says so, and for somebody who would live at that very source, or a page in any other state, nothing is offered")
    func onThePageOfSomebodyNotHeardOf() async throws {
        let (session, _, _) = try await shell(signedIn: [Self.two])
        let found = ShellPersonPages().found
        let far = try #require(DummyPerson(handle: "@far@elsewhere.example", host: Self.two))
        let unheard = PersonSaid(source: Self.two, reading: .unheardOf)
        #expect(found.line(of: far, said: unheard, in: session)?.press == .lookUp(Self.address, through: Self.two))
        #expect(found.line(of: far, said: unheard, in: session)?.pressWords == "Look @far@elsewhere.example up through n.example")
        #expect(found.line(of: far, said: PersonSaid(source: Self.two, reading: .asking), in: session) == nil)
        #expect(found.line(of: far, said: PersonSaid(source: Self.two, reading: .failed), in: session) == nil)
        #expect(found.line(of: far, said: nil, in: session) == nil)
        let local = try #require(DummyPerson(handle: "@gone@n.example", host: Self.two))
        #expect(found.line(of: local, said: unheard, in: session) == nil, "a source knows its own people")
        // At a source nobody is signed in to: only that source is spoken of, and it cannot be asked.
        let there = try #require(DummyPerson(handle: "@far@elsewhere.example", host: Self.one))
        let line = try #require(found.line(of: there, said: PersonSaid(source: Self.one, reading: .unheardOf), in: session))
        #expect(line.press == nil && line.words == "m.example can be asked to look @far@elsewhere.example up only by somebody signed in to it.")
    }

    // MARK: - The pages of all of one kind

    @Test("All the people a source found is a list like any other, asked when it opens as whoever is signed in — forty at a time, on by how many were passed over at the foot's press — and with no sign-in it is not asked for at all; all the hashtags is a page of what the answer already held, which asks nobody and goes with the answer")
    func thePagesOfAll() async throws {
        let forty = "{\"accounts\":[" + (1...40).map { Self.account($0) }.joined(separator: ",") + "]}"
        let (session, servers, work) = try await shell([
            Self.people("cats"): PageServer.Answer(body: forty), Self.people("cats", after: 40): Self.answer(people: 2),
            Self.returned("cats"): Self.answer(people: 5, tags: (1...40).map { "cat\($0)" }),
        ], signedIn: [Self.one])
        let server = try #require(servers[Self.one]), pages = ShellPersonPages()
        let list = PeopleList(foundAt: Self.one, words: "cats")
        #expect(list.id != PeopleList(foundAt: Self.one, words: "dogs").id && list.id != PeopleList(directoryAt: Self.one).id)
        #expect(PeopleSaid.counts(list, language: .english) == nil)
        #expect(TimelineToast.waiting(PeopleSaid.words(list.which) + ".asking", hosts: [Self.one], language: .english) == "Asking m.example for the people it found…", "the toast's words for the wait")
        await pages.lists.opened(list, in: session)
        #expect(await server.asked == [Self.people("cats")])
        #expect(await server.bearers == ["Bearer tok"])
        var said = try #require(pages.lists.said(of: list, in: session))
        #expect(said.people.count == 40 && said.foot == .more && said.sorting == nil)
        await pages.lists.readOn(list, in: session)
        #expect(await server.asked.last == Self.people("cats", after: 40))
        said = try #require(pages.lists.said(of: list, in: session))
        #expect(said.people.count == 40, "the two after forty are people already listed, and are listed once")
        #expect(work.record.allSatisfy { $0.purpose == .search && $0.reached == Self.one })

        let none = PeopleList(foundAt: Self.one, words: "nobody")
        await server.answer(Self.people("nobody"), Self.nothing)
        await pages.lists.opened(none, in: session)
        #expect(pages.lists.said(of: none, in: session)?.nothing(language: .english) == "m.example found nobody for these words.")
        var far = PeopleSaid(list: list, reading: .said, people: said.people, foot: .farthest)
        #expect(far.footWords(.farthest, language: .english) == "Fediqo reads the first 40 people a search finds. m.example may have found more.")
        far.reading = .failed
        #expect(far.stateLine() == nil, "a miss is the toast's to say")

        // The hashtags: what the Return's answer held.
        let found = pages.found, page = FoundTags(source: Self.one, words: "cats")
        #expect(found.said(of: page, in: session) == nil)
        await session.reload.search("cats", timeline: .all, found: found, in: session)
        let before = await server.asked.count
        let tags = try #require(found.said(of: page, in: session))
        #expect(tags.tags.count == 40 && found.walked(page, in: session).count == 40 && found.row(tags.rows[39].id, of: page, in: session) == tags.rows[39])
        let at = FoundAt(source: Self.one, words: "cats", gave: FoundWhich.allCases)
        #expect(FoundAt.title(Self.one, language: .english) == "What m.example found" && at.headLine(language: .english) == "Its answer to “cats”.")
        #expect(tags.foot(language: .english).hasPrefix("These are the first 40 hashtags m.example found, the most one answer holds."))
        #expect(FoundTagsSaid(page: page, tags: Array(tags.tags.prefix(5))).foot(language: .english) == "These are all 5 hashtags m.example found.")
        #expect(found.said(of: FoundTags(source: Self.one, words: "dogs"), in: session) == nil)
        #expect(await server.asked.count == before, "the page asks nobody")
        session.reload.endSearch()
        #expect(found.said(of: page, in: session) == nil && found.walked(page, in: session).isEmpty)

        // Read on to the furthest a search is read, and no further: ten stretches, and then
        // the foot says so and its press asks nothing.
        let many = PeopleList(foundAt: Self.one, words: "many")
        for stretch in 0..<10 {
            let from: Int = stretch * 40
            let accounts = (1...40).map { Self.account(from + $0) }.joined(separator: ",")
            await server.answer(Self.people("many", after: from), PageServer.Answer(body: "{\"accounts\":[" + accounts + "]}"))
        }
        await pages.lists.opened(many, in: session)
        for _ in 1..<10 { await pages.lists.readOn(many, in: session) }
        let whole = try #require(pages.lists.said(of: many, in: session))
        let stretches = await server.asked.filter { $0.contains("q=many") }
        #expect(whole.people.count == MastodonSearch.furthest && whole.foot == .farthest)
        #expect(stretches.count == 10 && stretches.last == Self.people("many", after: 360))
        await pages.lists.readOn(many, in: session)
        let after = await server.asked.filter { $0.contains("q=many") }
        #expect(after.count == 10, "nothing is asked past the furthest")

        // With no sign-in the list of people found is not asked for.
        try signOut(session)
        let asked = await server.asked.count
        await pages.lists.opened(PeopleList(foundAt: Self.one, words: "birds"), in: session)
        #expect(await server.asked.count == asked)
        #expect(pages.lists.said(of: PeopleList(foundAt: Self.one, words: "birds"), in: session)?.reading == .failed)
    }

    // MARK: - The keys, the words, the look

    @Test("The lamp still starts on the first post and climbs from it into the bands; with no post found the first press of a key that moves the lamp lights the first post that has come since or else the first row of the bands, once Return has handed the keys over and only then; a key that acts on a post does nothing with the lamp on a row of the bands; and what a stranger wrote is made fit for a line of the app's")
    func theKeysAndTheWords() throws {
        let bands = ["person", "all", "tag"], posts = ["post1", "post2"]
        let rows: [String]? = bands + posts
        #expect(FediqoRootView.moved(in: rows, from: nil, by: 1, open: [.search], entry: "post1") == nil, "Return lights the first post, not a key")
        #expect(FediqoRootView.moved(in: rows, from: "post1", by: -1, open: [.search, .selection], entry: "post1") == "tag")
        #expect(FediqoRootView.moved(in: rows, from: "tag", by: 1, open: [.search, .selection], entry: "post1") == "post1")
        #expect(FediqoRootView.moved(in: rows, from: "person", by: -1, open: [.search, .selection], entry: "post1") == "person", "the top is the top")
        #expect(ShellSearchFound.firstLit(bands, firstPost: nil, selected: nil, fieldFocused: false, open: [.search]) == "person")
        #expect(ShellSearchFound.firstLit(bands, firstPost: "post1", selected: nil, fieldFocused: false, open: [.search]) == "post1", "a post that came after Return is where the lamp starts")
        #expect(ShellSearchFound.firstLit(bands, firstPost: nil, selected: nil, fieldFocused: true, open: [.search]) == nil, "the field has the keys")
        #expect(ShellSearchFound.firstLit(bands, firstPost: nil, selected: "all", fieldFocused: false, open: [.search, .selection]) == nil)
        #expect(ShellSearchFound.firstLit(bands, firstPost: nil, selected: nil, fieldFocused: false, open: [.search, .shortcuts]) == nil)
        #expect(ShellSearchFound.firstLit(bands, firstPost: nil, selected: nil, fieldFocused: false, open: []) == nil)
        #expect(ShellSearchFound.firstLit([], firstPost: "post1", selected: nil, fieldFocused: false, open: [.search]) == nil, "with no band a search is lit as it always was")
        #expect(FediqoRootView.focused(in: [], selected: "person", open: [.search, .selection]) == .nothing)

        var walk = ShellWalk()
        let page = FoundTags(source: Self.one, words: "a\u{202E}b\nc")
        let at = FoundAt(source: page.source, words: page.words, gave: [.tags])
        #expect(walk.walk(to: .found(at, .tags), from: page.id) && walk.openedFoundTags == page)
        let named: String = "found:\(at.id)\u{1e}tags"
        #expect(TimelinePane.page(walk.standing) == .tabbed && TimelinePane.openedID(walk.standing) == named)
        var jump = 0
        var lit: String?
        #expect(FediqoRootView.jumpedToTop(in: ["t1", "t2"], standing: walk.standing, place: .timeline, selected: &lit, jump: &jump) && lit == "t1")
        #expect(walk.back()?.lamp == page.id)
        #expect(!page.lineWords.unicodeScalars.contains("\u{202E}") && !page.lineWords.contains("\n"))
        let long = PeopleList(foundAt: Self.one, words: String(repeating: "word ", count: 200))
        let most: Int = SearchBands.wordsShown + 1
        #expect(long.lineWords.count <= most)
        let page300: String = "https://elsewhere.example/@" + String(repeating: "a", count: 300)
        let typed = try #require(PersonAddress(typed: page300))
        #expect(typed.shown.count <= 201)
    }

    @Test("Every sentence of the bands, the two pages and the look-up is written in each language the app speaks, with the places it fills, no figure through a bare number's place, and the two Chinese tables alike; a source the person added is a 來源, and only the server an address names is a 站台")
    func writtenInEveryLanguage() throws {
        let resources = Self.shell.deletingLastPathComponent().appending(path: "Resources")
        let english = try String(contentsOf: resources.appending(path: "en.lproj/Localizable.strings"), encoding: .utf8)
        let ours = ["\"search.band.", "\"search.tags.", "\"search.found.", "\"search.lookup.", "\"people.found.", "\"work.purpose.lookUp\""]
        let keys = english.split(separator: "\n").compactMap { line -> String? in
            guard ours.contains(where: line.hasPrefix) else { return nil }
            return line.dropFirst().split(separator: "\"").first.map(String.init)
        }
        #expect(keys.count == 27 && keys.contains("search.lookup.found.other") && keys.contains("search.lookup.offer") && keys.contains("people.found.none"))
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
            let chinese = L10n.t(key, language: .taiwanese)
            #expect(chinese.contains("站台") == (key == "search.lookup.unheardOf"), "\(key)")
        }
        let taiwan = try Data(contentsOf: resources.appending(path: "zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appending(path: "zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
        #expect(SourceWork.Purpose.lookUp.isOfTheSource && !SourceWork.Purpose.lookUp.gathers && !SourceWork.Purpose.lookUp.symbol.isEmpty)
        #expect(L10n.t("shortcut.search", language: .english) == "Search the posts this device holds", "the guide's plate is as tall as it was")
    }

    @Test("The bands, the press for all, the page of hashtags, the line about a look-up in each state and the search's foot with that line under its field are laid out to the width they are given and never past it, in light and in dark")
    func laidOut() throws {
        func size<Content: View>(_ content: Content, _ width: CGFloat, scheme: ColorScheme = .light) -> CGSize {
            let hosted = NSHostingView(rootView: VStack(spacing: 0) { content }.frame(width: width).environment(\.colorScheme, scheme))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize
        }
        let source = Source(host: Self.one, kind: .mastodon)
        let long = String(repeating: "long", count: 30)
        let people = (1...5).map { Person(source: source, accountID: "\($0)", handle: "@\(long)\($0)@\(long).example", name: long, words: long) }
        let tags = (1...5).map { RisingTag(tag: PostTag("#\(long)\($0)")!, use: RisingUse(posts: 1_204_000, people: 310_000, days: 2)) }
        let band = SearchBands(source: Self.one, words: "cats", people: people, tags: tags)
        let address = try #require(PersonAddress(typed: "@\(long)@\(long).example"))
        let lines = [
            SearchLookUpLine(press: .lookUp(address, through: Self.one), pressWords: "Look \(address.shown) up through \(long).example"),
            SearchLookUpLine(words: "Asking m.example to look \(address.shown) up…"),
            SearchLookUpLine(words: "m.example found \(address.shown).", press: .open(people[0]), pressWords: "Open their page"),
            SearchLookUpLine(words: "Could not ask.", press: .lookUp(address, through: Self.one), pressWords: "Try again", failed: true),
            SearchLookUpLine(words: "Short.", press: .open(people[0]), pressWords: "Open"),
        ]
        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (390, .dark), (320, .light)] {
            for selected in [nil, band.rows[0].id, band.rows[3].id, band.rows[4].id] {
                let laid = size(SearchBandsView(bands: [band, SearchBands(source: Self.two, words: "cats", tags: [tags[0]])], timeline: "All", selectedID: .constant(selected), onOpen: { _ in }), width, scheme: scheme)
                #expect(laid.width == width && laid.height > 0, "at \(width)")
            }
            for row in band.rows {
                #expect(size(SearchFoundRowView(row: row, selected: true, onPress: {}, onOpen: {}), width, scheme: scheme).width == width)
            }
            for line in lines {
                let laid = size(SearchLookUpView(line: line, onPress: { _ in }).padding(.horizontal, 16), width, scheme: scheme)
                #expect(laid.width == width && laid.height > 0, "at \(width)")
                let bar = SearchBar(search: ShellSearch(), timeline: "All", found: 3, reach: "Also asked m.example.", lookUp: line, onLookUp: { _ in }, onSubmit: {}, onCleared: {}, onClose: {})
                #expect(size(bar, width, scheme: scheme).width == width)
            }
        }
        for (layout, width) in [(ShellLayout.wide, CGFloat(720)), (.narrow, 320)] {
            for count in [5, 40] {
                let said = FoundTagsSaid(page: FoundTags(source: Self.one, words: long), tags: (1...count).map { RisingTag(tag: PostTag("#t\($0)")!) })
                let at = FoundAt(source: Self.one, words: long, gave: [.tags])
                let pane = FoundPage(said: FoundSaid(at: at, tabs: [.tags], which: .tags, tags: said), selectedID: .constant(said.rows.first?.id))
                    .environment(\.shellLayout, layout)
                let hosted = NSHostingView(rootView: pane.frame(width: width, height: 700))
                hosted.layoutSubtreeIfNeeded()
                #expect(hosted.fittingSize == CGSize(width: width, height: 700))
            }
        }
    }
}
