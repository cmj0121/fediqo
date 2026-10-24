import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #378, on somebody's page: which languages of their posts reach the reader's Home — read back
/// with how the reader stands, chosen on About, sent as the follow it is only to somebody a read
/// says the reader still follows, one at a time, and taken as the source answers.
@MainActor
@Suite("The languages of somebody followed that reach Home, on their page", .serialized)
struct PersonLanguagesTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let scopes = "read:statuses read:lists read:accounts read:search read:follows write:follows"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let stands = "/api/v1/accounts/relationships?id%5B%5D=42"
    private static let follow = "/api/v1/accounts/42/follow"
    private static let known = "/api/v1/instance/languages"
    private static let ada = DummyPerson(handle: "@ada@m.example", host: host)!

    private static func standing(following: Bool = true, languages: [String]?) -> String {
        let said = languages.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
        return #"{"id":"42","following":\#(following),"showing_reblogs":\#(following),"notifying":false,"languages":\#(said),"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#
    }

    private static func read(following: Bool = true, languages: [String]?) -> PageServer.Answer {
        PageServer.Answer(body: "[" + standing(following: following, languages: languages) + "]")
    }

    private static func page() throws -> PersonSaid {
        let person = try MastodonPeople.person(
            from: Data(#"{"id":"42","acct":"ada","display_name":"Ada","statuses_count":3}"#.utf8), source: source
        )
        return PersonSaid(source: host, reading: .said(person), posts: [])
    }

    private func session(_ routes: [String: PageServer.Answer], scopes: String = PersonLanguagesTests.scopes) async throws -> (ShellSession, PageServer) {
        let me = PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#)
        let server = PageServer(routes.merging([Self.who: me]) { one, _ in one })
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        await session.store.add(Self.source)
        session.sources = await session.store.sources()
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        return (session, server)
    }

    /// The bodies of the follows sent, as written.
    private func followsSent(_ server: PageServer) async -> [String] {
        await server.sent.filter { $0.ask == Self.follow }.map { $0.body.removingPercentEncoding ?? $0.body }
    }

    @Test("What is chosen is read back with how the reader stands, under what else is taken from them — every language where nothing is; and of somebody not followed there is no row")
    func readBack() async throws {
        let (session, server) = try await session([Self.stands: Self.read(languages: ["en", "ja"])])
        let pages = ShellPersonPages(), page = try Self.page()
        await pages.acts.opened(Self.ada, said: page, in: session)
        let acting = try #require(pages.acts.acting(of: Self.ada, said: page, in: session))
        let row = try #require(acting.languages)
        #expect(row.codes == ["en", "ja"])
        #expect(row.words(language: .english) == "Their languages: English, Japanese")
        let about = PersonAboutSaid(source: Self.host, view: "", person: page.person, standing: acting)
        let blocks = about.blocks
        #expect(blocks.firstIndex(of: .languages) == blocks.firstIndex(of: .notices).map { $0 + 1 })

        await server.answer(Self.stands, Self.read(languages: nil))
        await pages.acts.again(Self.ada, said: page, in: session)
        let all = try #require(pages.acts.acting(of: Self.ada, said: page, in: session)?.languages)
        #expect(all.codes.isEmpty && all.state(language: .english) == "Every language")

        await server.answer(Self.stands, Self.read(following: false, languages: nil))
        await pages.acts.again(Self.ada, said: page, in: session)
        let unfollowed = try #require(pages.acts.acting(of: Self.ada, said: page, in: session))
        #expect(unfollowed.languages == nil)
        #expect(!PersonAboutSaid(source: Self.host, view: "", person: page.person, standing: unfollowed).blocks.contains(.languages))
    }

    @Test("A choice is drawn at once and sent as a follow with the codes, once a read says the reader still follows them; the source's answer is then drawn. None chosen is every language, sent as the word with nothing in it")
    func chosenAndSent() async throws {
        let (session, server) = try await session([
            Self.stands: Self.read(languages: nil),
            Self.follow: PageServer.Answer(body: Self.standing(languages: ["de", "fr"])),
        ])
        let pages = ShellPersonPages(), page = try Self.page()
        await pages.acts.opened(Self.ada, said: page, in: session)
        await server.hold(Self.follow)
        let choosing = Task { await pages.acts.press(.chooseLanguages, on: Self.ada, said: page, choice: StandingChoice(languages: ["de", "fr"]), in: session) }
        await server.arrival(of: Self.follow, by: choosing)
        let drawn = try #require(pages.acts.acting(of: Self.ada, said: page, in: session))
        #expect(drawn.doing == .chooseLanguages && drawn.languages?.codes == ["de", "fr"], "drawn at once")
        #expect(await server.arrivals(of: Self.stands) == 2, "read once more before it is sent")
        await server.release(Self.follow)
        await choosing.value
        let kept = try #require(pages.acts.acting(of: Self.ada, said: page, in: session))
        #expect(kept.doing == nil && kept.missed == nil && kept.languages?.codes == ["de", "fr"])
        #expect(await followsSent(server) == ["languages[]=de&languages[]=fr"])

        await server.answer(Self.follow, PageServer.Answer(body: Self.standing(languages: [])))
        await pages.acts.press(.chooseLanguages, on: Self.ada, said: page, choice: StandingChoice(languages: []), in: session)
        #expect(await followsSent(server).last == "languages=")
        let all = try #require(pages.acts.acting(of: Self.ada, said: page, in: session))
        #expect(all.missed == nil && all.languages?.codes == [])
    }

    @Test("Over a page that says they are followed, where the reader unfollowed them elsewhere since, nothing is sent — a follow would follow them again — and the page says how the reader stands now, with nothing failed")
    func notFollowedAnyMore() async throws {
        let (session, server) = try await session([
            Self.stands: Self.read(languages: nil),
            Self.follow: PageServer.Answer(body: Self.standing(languages: ["de"])),
        ])
        let pages = ShellPersonPages(), page = try Self.page()
        await pages.acts.opened(Self.ada, said: page, in: session)
        #expect(pages.acts.acting(of: Self.ada, said: page, in: session)?.languages != nil)
        await server.answer(Self.stands, Self.read(following: false, languages: nil))
        await pages.acts.press(.chooseLanguages, on: Self.ada, said: page, choice: StandingChoice(languages: ["de"]), in: session)
        #expect(await server.arrivals(of: Self.follow) == 0, "nobody is followed again")
        let acting = try #require(pages.acts.acting(of: Self.ada, said: page, in: session))
        #expect(acting.shown?.following == false && acting.languages == nil && acting.missed == nil)
    }

    @Test("One choice at a time a page: pressed again while one is out, nothing more is sent, and the row takes no press")
    func oneAtATime() async throws {
        let (session, server) = try await session([
            Self.stands: Self.read(languages: nil),
            Self.follow: PageServer.Answer(body: Self.standing(languages: ["de"])),
        ])
        let pages = ShellPersonPages(), page = try Self.page()
        await pages.acts.opened(Self.ada, said: page, in: session)
        await server.hold(Self.follow)
        let first = Task { await pages.acts.press(.chooseLanguages, on: Self.ada, said: page, choice: StandingChoice(languages: ["de"]), in: session) }
        await server.arrival(of: Self.follow, by: first)
        #expect(pages.acts.acting(of: Self.ada, said: page, in: session)?.narrowsTakePress == false)
        await pages.acts.press(.chooseLanguages, on: Self.ada, said: page, choice: StandingChoice(languages: ["ja"]), in: session)
        await server.release(Self.follow)
        await first.value
        #expect(await server.arrivals(of: Self.follow) == 1)
        #expect(pages.acts.acting(of: Self.ada, said: page, in: session)?.languages?.codes == ["de"])
    }

    @Test("A language the source will not take is said in its own words under the heading, and the choice is as the source keeps it")
    func refused() async throws {
        let (session, _) = try await session([
            Self.stands: Self.read(languages: ["en"]),
            Self.follow: PageServer.Answer(body: #"{"error":"Validation failed: Languages is invalid"}"#, status: 422),
        ])
        let pages = ShellPersonPages(), page = try Self.page()
        await pages.acts.opened(Self.ada, said: page, in: session)
        await pages.acts.press(.chooseLanguages, on: Self.ada, said: page, choice: StandingChoice(languages: ["zz"]), in: session)
        let acting = try #require(pages.acts.acting(of: Self.ada, said: page, in: session))
        #expect(acting.missed == .chooseLanguages && acting.languages?.codes == ["en"])
        let said = try #require(acting.refusedWords(language: .english))
        #expect(said.contains("Languages is invalid"))
        #expect(acting.missedWords(language: .english) == "Could not change which languages of @ada@m.example reach Home at m.example.")
    }

    @Test("A sign-in that sees and may not change who the reader follows is read the choice, and offered no press and nothing to ask the source")
    func onlySees() async throws {
        let (session, server) = try await session(
            [Self.stands: Self.read(languages: ["en"])], scopes: "read:statuses read:lists read:accounts read:search read:follows"
        )
        let pages = ShellPersonPages(), page = try Self.page()
        await pages.acts.opened(Self.ada, said: page, in: session)
        let acting = try #require(pages.acts.acting(of: Self.ada, said: page, in: session))
        #expect(acting.languages?.codes == ["en"] && !acting.narrowsTakePress)
        #expect(pages.acts.languagesOpening(Self.ada, said: page, in: session) == nil)
        await pages.acts.press(.chooseLanguages, on: Self.ada, said: page, choice: StandingChoice(languages: ["de"]), in: session)
        #expect(await server.arrivals(of: Self.follow) == 0)
    }

    @Test("The languages chosen among are the source's own, asked once a run where somebody followed there is open; until then, and where it does not answer, the ones this device knows by two letters")
    func whatIsChosenAmong() async throws {
        let (session, server) = try await session([
            Self.stands: Self.read(languages: nil),
            Self.known: PageServer.Answer(body: #"[{"code":"en","name":"English"},{"code":"tok","name":"Toki Pona"},{"code":"","name":"none"}]"#),
        ])
        let pages = ShellPersonPages(), page = try Self.page()
        await pages.acts.opened(Self.ada, said: page, in: session)
        let before = try #require(pages.acts.acting(of: Self.ada, said: page, in: session))
        #expect(before.languagesOffered == PersonLanguagesWords.known)
        #expect(PersonLanguagesWords.known.contains { $0.code == "ja" } && PersonLanguagesWords.known.allSatisfy { $0.code.count == 2 })
        #expect(pages.acts.languagesOpening(Self.ada, said: page, in: session) == Self.host)
        await pages.acts.languagesOpened(Self.ada, said: page, in: session)
        #expect(pages.acts.languagesOpening(Self.ada, said: page, in: session) == nil, "asked once a run")
        await pages.acts.languagesOpened(Self.ada, said: page, in: session)
        #expect(await server.arrivals(of: Self.known) == 1)
        let offered = try #require(pages.acts.acting(of: Self.ada, said: page, in: session)?.languagesOffered)
        #expect(offered.map(\.code) == ["en", "tok"])
        // Named in the reader's language where this device can, else as the source names it.
        #expect(PersonLanguagesWords.name("tok", offered: offered, language: .english) == "Toki Pona")
    }

    @Test("Choosing lists what is chosen first, whatever is typed, then the languages whose name or code holds what is typed, by their names")
    func choosing() {
        let offered = [
            FollowLanguage(code: "ja", name: "Japanese"), FollowLanguage(code: "en", name: "English"),
            FollowLanguage(code: "de", name: "German"),
        ]
        let all = PersonLanguagesWords.choices(offered, chosen: ["ja"], find: "", language: .english)
        #expect(all.map(\.code) == ["ja", "en", "de"])
        let found = PersonLanguagesWords.choices(offered, chosen: ["ja"], find: "GER", language: .english)
        #expect(found.map(\.code) == ["ja", "de"])
        #expect(PersonLanguagesWords.choices(offered, chosen: [], find: "en", language: .english).map(\.code) == ["en"])
        let kept = PersonLanguagesWords.choices(offered, chosen: ["xx"], find: "", language: .english)
        #expect(kept.first?.code == "xx", "a choice the source no longer offers can still be taken off")
    }

    @Test("Its words, in each language the app speaks")
    func theWords() {
        for language in [DummyLanguage.english, .taiwanese] {
            for key in [
                "person.act.languages", "person.act.languages.failed", "person.languages.all", "person.languages.find",
                "person.languages.keep", "person.languages.hint", "person.languages.chosen", "person.languages.unchosen",
            ] {
                #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
            }
        }
        #expect(PersonLanguagesWords.chosen(true, language: .english) == "Chosen")
        #expect(PersonLanguagesWords.hint("m.example", language: .english) == "Choose which languages of their posts reach Home at m.example")
    }
}
