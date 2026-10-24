import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #377, on somebody's page: the reader's own note on them — read with how the reader stands,
/// written at once and kept as the source answers, never put back by a read already on its way —
/// and the people the reader follows who follow them too, as faces.
@MainActor
@Suite("The reader's note on somebody, and who is known in common, on their page", .serialized)
struct PersonNoteTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let seeing = "read:statuses read:lists read:accounts read:search read:follows write:follows"
    /// With the account part, which writing a note needs.
    private static let writes = "\(seeing) write:accounts"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let stands = "/api/v1/accounts/relationships?id%5B%5D=42"
    private static let note = "/api/v1/accounts/42/note"
    private static let familiar = "/api/v1/accounts/familiar_followers?id%5B%5D=42"
    private static let ada = DummyPerson(handle: "@ada@m.example", host: host)!

    private static func standing(note: String) -> String {
        #"{"id":"42","following":true,"showing_reblogs":true,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":"\#(note)"}"#
    }

    private static func page() throws -> PersonSaid {
        let person = try MastodonPeople.person(
            from: Data(#"{"id":"42","acct":"ada","display_name":"Ada","statuses_count":3}"#.utf8), source: source
        )
        return PersonSaid(source: host, reading: .said(person), posts: [])
    }

    private func session(_ routes: [String: PageServer.Answer], scopes: String = PersonNoteTests.writes) async throws -> (ShellSession, PageServer) {
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

    @Test("The note is read with how the reader stands, in the same ask, and About draws it where the page reads how they stand")
    func theNoteIsRead() async throws {
        let (session, server) = try await session([Self.stands: PageServer.Answer(body: "[" + Self.standing(note: "Lent her a book") + "]")])
        let acts = ShellPersonPages().acts, page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        let acting = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(acting.notes && acting.note == "Lent her a book")
        #expect(await server.asked.filter { $0 != Self.who } == [Self.stands], "no ask more for the note")
        let about = PersonAboutSaid(source: Self.host, view: "", person: page.person, standing: acting)
        #expect(about.blocks.contains(.note) && !about.blocks.contains(.familiar), "nobody in common: no faces")
    }

    @Test("A note written shows at once, is sent as its comment, and once the source answers is the source's word; an empty one clears it")
    func aNoteIsWritten() async throws {
        let (session, server) = try await session([
            Self.stands: PageServer.Answer(body: "[" + Self.standing(note: "") + "]"),
            Self.note: PageServer.Answer(body: Self.standing(note: "Owes me lunch")),
        ])
        let acts = ShellPersonPages().acts, page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.note == nil)
        await server.hold(Self.note)
        let writing = Task { await acts.writeNote("Owes me lunch", of: Self.ada, said: page, in: session) }
        await server.arrival(of: Self.note, by: writing)
        let drawn = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(drawn.note == "Owes me lunch" && drawn.noteSending, "drawn at once")
        await server.release(Self.note)
        await writing.value
        let kept = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(kept.note == "Owes me lunch" && !kept.noteSending)
        let sent = await server.sent.last
        #expect(sent?.method == "POST" && sent?.body.hasPrefix("comment=Owes") == true)

        await server.answer(Self.note, PageServer.Answer(body: Self.standing(note: "")))
        await acts.writeNote("", of: Self.ada, said: page, in: session)
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.note == nil, "cleared")
    }

    @Test("Notes written close together go one at a time a page: the newer waits, drawn as written, and is sent once the earlier is answered — so the earlier answer, landing after the newer was written, never puts it back")
    func oneAtATime() async throws {
        let (session, server) = try await session([
            Self.stands: PageServer.Answer(body: "[" + Self.standing(note: "") + "]"),
            Self.note: PageServer.Answer(body: Self.standing(note: "First")),
        ])
        let acts = ShellPersonPages().acts, page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        await server.hold(Self.note)
        let writing = Task { await acts.writeNote("First", of: Self.ada, said: page, in: session) }
        await server.arrival(of: Self.note, by: writing)
        await acts.writeNote("Second", of: Self.ada, said: page, in: session)
        #expect(await server.arrivals(of: Self.note) == 1, "nothing more is sent while one is out")
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.note == "Second", "the newer drawn at once")
        // The earlier answer lands after the newer was written: it does not put "First" back.
        await server.releaseOne(Self.note)
        await server.arrival(of: Self.note, times: 2, by: writing)
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.note == "Second")
        await server.answer(Self.note, PageServer.Answer(body: Self.standing(note: "Second")))
        await server.release(Self.note)
        await writing.value
        let kept = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(kept.note == "Second" && !kept.noteSending)
        #expect(await server.arrivals(of: Self.note) == 2)
    }

    @Test("Keep with words that change nothing sends nothing; a note the source will not keep is said in its own words, and the note is as it was")
    func unchangedAndRefused() async throws {
        let (session, server) = try await session([
            Self.stands: PageServer.Answer(body: "[" + Self.standing(note: "Kept") + "]"),
            Self.note: PageServer.Answer(body: #"{"error":"Validation failed: Comment is too long"}"#, status: 422),
        ])
        let acts = ShellPersonPages().acts, page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        await acts.writeNote(" Kept ", of: Self.ada, said: page, in: session)
        #expect(await server.arrivals(of: Self.note) == 0, "the same words are not sent")
        await acts.writeNote(String(repeating: "x", count: 3_000), of: Self.ada, said: page, in: session)
        let acting = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(acting.note == "Kept" && !acting.noteMissed)
        let sentence = try #require(acting.noteRefused)
        #expect(sentence.contains("Comment is too long"))
        #expect(PersonNoteWords.refused(sentence, at: Self.host, language: .english).hasPrefix("m.example would not keep the note: "))
    }

    @Test("A read of how the reader stands already on its way when a note's answer lands does not put the old note back")
    func aReadOnItsWayDoesNotUndoIt() async throws {
        let (session, server) = try await session([
            Self.stands: PageServer.Answer(body: "[" + Self.standing(note: "Old") + "]"),
            Self.note: PageServer.Answer(body: Self.standing(note: "New")),
        ])
        let people = ShellPersonPages()
        let acts = people.acts, page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        await server.hold(Self.stands)
        let reading = Task { await acts.again(Self.ada, said: page, in: session) }
        await server.arrival(of: Self.stands, times: 2, by: reading)
        await acts.writeNote("New", of: Self.ada, said: page, in: session)
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.note == "New")
        await server.release(Self.stands)
        await reading.value
        #expect(acts.acting(of: Self.ada, said: page, in: session)?.note == "New", "the read sent before the answer changed nothing")
    }

    @Test("Without the account part a note is not written: the press asks for the part, and nothing is sent")
    func withoutTheAccountPart() async throws {
        let (session, server) = try await session(
            [Self.stands: PageServer.Answer(body: "[" + Self.standing(note: "") + "]")], scopes: Self.seeing
        )
        let acts = ShellPersonPages().acts, page = try Self.page()
        await acts.opened(Self.ada, said: page, in: session)
        let acting = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(acting.accountLock != nil, "the lock About draws in its place")
        await acts.writeNote("Anything", of: Self.ada, said: page, in: session)
        #expect(await server.asked.contains(Self.note) == false)
        #expect(session.partAsks.open?.ticked == [.account], "the press only asks")
    }

    @Test("Who is known in common is asked once a page, once the source said how the reader stands, and drawn as faces; nobody in common draws nothing")
    func whoIsKnownInCommon() async throws {
        let common = #"[{"id":"42","accounts":[{"id":"8","username":"bo","acct":"bo","display_name":"Bo"},{"id":"9","username":"cy","acct":"cy","display_name":"Cy"}]}]"#
        let (session, server) = try await session([
            Self.stands: PageServer.Answer(body: "[" + Self.standing(note: "") + "]"),
            Self.familiar: PageServer.Answer(body: common),
        ])
        let acts = ShellPersonPages().acts, page = try Self.page()
        #expect(acts.familiarOpening(Self.ada, said: page, in: session) == nil, "not before the source said how the reader stands")
        await acts.opened(Self.ada, said: page, in: session)
        #expect(acts.familiarOpening(Self.ada, said: page, in: session) != nil)
        await acts.familiarOpened(Self.ada, said: page, in: session)
        await acts.familiarOpened(Self.ada, said: page, in: session)
        #expect(await server.arrivals(of: Self.familiar) == 1, "asked once a read of how the reader stands")
        // Read again: who is in common is asked again with it.
        let before = acts.familiarOpening(Self.ada, said: page, in: session)
        await acts.again(Self.ada, said: page, in: session)
        #expect(acts.familiarOpening(Self.ada, said: page, in: session) != before, "the page's task asks again")
        await acts.familiarOpened(Self.ada, said: page, in: session)
        #expect(await server.arrivals(of: Self.familiar) == 2)
        let acting = try #require(acts.acting(of: Self.ada, said: page, in: session))
        #expect(acting.familiar.map(\.accountID) == ["8", "9"])
        let about = PersonAboutSaid(source: Self.host, view: "", person: page.person, standing: acting)
        #expect(about.blocks.contains(.familiar))
        #expect(PersonNoteWords.familiar(2, language: .english) == "Followed by 2 people you follow")
        #expect(PersonNoteWords.familiar(1, language: .english) == "Followed by 1 person you follow")
        #expect(PersonNoteWords.open(acting.familiar[0], language: .english) == "Open Bo")
        // The head counts them as an icon that opens About, where they are.
        let head = PersonHeadSaid.made(of: Self.ada, said: page, tabs: PersonTab.allCases, held: 0, standing: acting)
        let figure = try #require(head.figures.last)
        #expect(figure.glyph == PersonNoteWords.familiarSymbol && figure.tab == .about && figure.figure == "2")
        #expect(figure.drawn(front: .about).lit == false, "it is not the About tab's own figure")
    }

    @Test("What the note says is in every language, and a listener is read it", arguments: [DummyLanguage.english, .taiwanese])
    func theWords(_ language: DummyLanguage) {
        for key in ["person.note.title", "person.note.none", "person.note.write", "person.note.change", "person.note.keep"] {
            #expect(L10n.t(key, language: language) != key, "\(key)")
        }
        #expect(PersonNoteWords.spoken("Met in Taipei", language: language).contains("Met in Taipei"))
        #expect(PersonNoteWords.spoken(nil, language: language) == PersonNoteWords.none(language: language))
        #expect(PersonNoteWords.missed("m.example", language: language).contains("m.example"))
    }
}
