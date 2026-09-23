import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

#if os(macOS)
import AppKit
import SwiftUI
#endif

/// A post its source deleted stays, marked, until a wait or a press lets it go (#179).
///
/// What a test can reach: which reads mark a post and which never do; that the mark is on the row
/// every place builds — the timeline, a thread, a search, a person's page; that nothing reaching
/// the source is offered or sent; the wait and the press; the choice kept across a relaunch; and
/// the words in every language. What it cannot: the mark drawn on a Mac and a phone, in light and
/// dark, and heard through VoiceOver — that lives in a view body.
@MainActor
@Suite("A post gone from its source")
struct GoneMarkTests {
    private static let host = "one.example"
    private static let other = "two.example"
    private static let posted = Date(timeIntervalSince1970: 1_700_000_000)

    private static func note(
        _ id: String = "9", audience: Audience? = .everyone, author: String = "Ada", handle: String = "@ada@one.example",
        body: String = "first words", host: String = host
    ) -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/\(id)", source: Source(host: host, kind: .mastodon),
            author: author, handle: handle, body: body, postedAt: posted, categories: [.public],
            audience: audience, statusID: id
        )
    }

    private static func status(_ id: String) -> String {
        """
        {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)",
         "created_at":"2024-01-01T00:00:00.000Z","content":"<p>new</p>","visibility":"public",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    /// A session holding `notes` on two Mastodon sources, read unsigned through `routes`.
    private func shell(
        _ notes: [Note] = [note()], routes: [String: FixtureHTTP.Outcome] = [:]
    ) async -> (ShellSession, FixtureHTTP) {
        let http = FixtureHTTP(routes)
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        await store.add(Source(host: Self.other, kind: .mastodon))
        await store.ingest(notes)
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:]))
        )
        await session.reloadFromStore()
        return (session, http)
    }

    private func row(_ session: ShellSession, _ id: String = "9") throws -> DummyItem {
        try #require(session.held(Self.note(id).key.rowID))
    }

    // MARK: - What marks a post, and what never does

    @Test("r on a post whose source says it is gone keeps the post, marked, and asks nothing more")
    func readAgainMarks() async throws {
        let (session, http) = await shell(routes: ["/api/v1/statuses/9": .text("", status: 404)])
        await session.reload.thread(try row(session), in: session)
        #expect(try row(session).goneSince != nil, "still here, and marked")
        #expect(session.notes.count == 1)
        #expect(await http.paths == ["/api/v1/statuses/9"], "no thread asked around a post that is not there")
        #expect(session.reload.line == nil, "nothing failed: the source answered")
        #expect(await session.store.snapshot().notes.first?.goneSince != nil, "written where a save reads it")
    }

    @Test("410 is gone whoever the post was written for")
    func goneIsGone() async throws {
        let (session, _) = await shell(
            [Self.note(audience: .followers)], routes: ["/api/v1/statuses/9": .text("", status: 410)]
        )
        await session.reload.thread(try row(session), in: session)
        #expect(try row(session).goneSince != nil)
    }

    @Test("A followers-only post answered 404 signed out is not marked: the server may only be hiding it")
    func hiddenIsNotGone() async throws {
        let (session, _) = await shell(
            [Self.note(audience: .followers)], routes: ["/api/v1/statuses/9": .text("", status: 404)]
        )
        await session.reload.thread(try row(session), in: session)
        #expect(try row(session).goneSince == nil)
    }

    @Test("A server that failed is not a server that said so")
    func failureIsNotGone() async throws {
        let (session, _) = await shell(routes: ["/api/v1/statuses/9": .text("", status: 500)])
        await session.reload.thread(try row(session), in: session)
        #expect(try row(session).goneSince == nil)
    }

    @Test("Opening the thread of a post whose source says it is gone marks it too")
    func threadOpenMarks() async throws {
        let (session, _) = await shell(routes: ["/api/v1/statuses/9/context": .text("", status: 404)])
        await session.conversations.open(try row(session), in: session)
        #expect(try row(session).goneSince != nil)
    }

    @Test("A post missing from a listing merely did not arrive: it is not marked, and no press lets it go")
    func notArrivedIsNotMarked() async throws {
        let (session, _) = await shell(routes: [
            "https://\(Self.host)/api/v1/timelines/public?limit=40": .text("[" + Self.status("10") + "]"),
            "https://\(Self.host)/api/v1/trends/statuses?limit=20": .text("[]"),
            "https://\(Self.other)/api/v1/timelines/public?limit=40": .text("[]"),
            "https://\(Self.other)/api/v1/trends/statuses?limit=20": .text("[]"),
            MastodonInstance.address(Self.host): MastodonInstance.mastodon(Self.host),
            MastodonInstance.address(Self.other): MastodonInstance.mastodon(Self.other),
        ])
        await session.reload.timeline(.all, in: session)
        #expect(session.notes.contains { $0.statusID == "10" }, "the premise: the listing landed without 9")
        #expect(session.notes.allSatisfy { $0.goneSince == nil })
        #expect(await session.letAllGoneGo() == 0)
        #expect(session.notes.count == 2)
    }

    @Test("A read that finds the post again takes the mark off")
    func foundAgain() async throws {
        let (session, _) = await shell(routes: [
            "/api/v1/statuses/9": .text(Self.status("9")),
            "/api/v1/statuses/9/context": .text(#"{"ancestors":[],"descendants":[]}"#),
        ])
        await session.markGone(Self.note().key, at: Self.posted)
        #expect(try row(session).goneSince != nil)
        await session.reload.thread(try row(session), in: session)
        #expect(try row(session).goneSince == nil)
    }

    // MARK: - Nothing that would reach the source

    @Test("Signed in with writing, a gone post offers no act, and a press sends nothing")
    func goneOffersNothing() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s",
            scopes: MastodonOAuth.scopes(writing: true)
        ))
        let server = ActServer(["/api/v1/statuses/9": .json("", status: 404)])
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        // Written for followers: signed in, a 404 still counts.
        await store.ingest([Self.note(audience: .followers), Self.note("8")])
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        #expect(session.acts(on: try row(session)).offers(.boost), "the premise: before, it offered them")

        await session.reload.thread(try row(session), in: session)
        let gone = try row(session)
        #expect(gone.goneSince != nil)
        #expect(session.acts(on: gone) == .none)
        #expect(session.acting(on: gone).acts == .none)
        #expect(!session.openAnswer(to: gone, in: gone))
        let asked = await server.paths.count
        await session.toggle(.boost, on: gone)
        await session.toggle(.favourite, on: gone)
        #expect(await server.paths.count == asked, "nothing was sent")
        #expect(session.acts(on: try row(session, "8")).offers(.answer), "and the post beside it still offers them")
    }

    // MARK: - The mark reads the same everywhere

    @Test("The timeline, the thread, a search and a person's page all carry the mark")
    func markedEverywhere() async throws {
        let (session, _) = await shell([Self.note(body: "swift gone"), Self.note("8", body: "swift here")])
        await session.markGone(Self.note().key, at: Self.posted)
        let id = Self.note().key.rowID

        let listed = session.timelineItems(latest: nil)
        #expect(listed.first { $0.id == id }?.goneSince != nil)
        #expect(listed.first { $0.id != id }?.goneSince == nil)

        let thread = try row(session)
        #expect(session.conversations.conversation(around: thread).post.goneSince != nil)

        let search = ShellSearch()
        search.open(from: nil, over: session.notes)
        await search.indexed()
        search.text = "swift"
        search.settle("swift")
        let found = try #require(session.searched(search, latest: nil))
        #expect(found.first { $0.id == id }?.goneSince != nil)
        #expect(found.count == 2)

        let person = try #require(DummyPerson(thread))
        let page = DummyPerson.held(of: person, in: session.notes)
        #expect(page.first { $0.id == id }?.goneSince != nil)
        #expect(page.first { $0.id != id }?.goneSince == nil)
    }

    @Test("The mark has words in every language, and says more to a pointer")
    func markWords() {
        for language in [DummyLanguage.english, .taiwanese] {
            let word = DummyItemRow.goneWord(language: language)
            #expect(word != "item.gone" && !word.isEmpty, "\(language)")
            #expect(L10n.t("item.gone.detail", language: language) != "item.gone.detail")
        }
        #expect(DummyItemRow.goneWord(language: .english) != DummyItemRow.goneWord(language: .taiwanese))
    }

    // MARK: - Letting go

    @Test("The press lets every marked post go, says how many, and nothing else moves")
    func pressLetsGo() async throws {
        let (session, _) = await shell([Self.note(), Self.note("8"), Self.note("7")])
        await session.markGone(Self.note().key, at: Self.posted)
        await session.markGone(Self.note("7").key, at: Self.posted)
        let kept = try row(session, "8")
        #expect(await session.letAllGoneGo() == 2)
        #expect(session.held(Self.note().key.rowID) == nil, "gone from the timeline and the thread")
        #expect(session.timelineItems(latest: nil).map(\.id) == [kept.id])
        #expect(try row(session, "8") == kept)
        #expect(await session.store.snapshot().notes.map(\.statusID) == ["8"], "and from what a save writes")
        #expect(await session.letAllGoneGo() == 0)
    }

    @Test("The wait lets go what has waited long enough, and never keeps them all")
    func waitLetsGo() async throws {
        let (session, _) = await shell([Self.note(), Self.note("8")])
        await session.markGone(Self.note().key, at: Self.posted)
        let day: TimeInterval = 86_400
        #expect(await session.letGoneGo(waitingDays: nil, keepingMonths: nil, from: Self.posted.addingTimeInterval(400 * day)) == 0)
        #expect(await session.letGoneGo(waitingDays: 7, keepingMonths: nil, from: Self.posted.addingTimeInterval(day)) == 0)
        #expect(await session.letGoneGo(waitingDays: 7, keepingMonths: nil, from: Self.posted.addingTimeInterval(8 * day)) == 1)
        #expect(session.notes.map(\.statusID) == ["8"], "a post never marked is not reached by the wait")
    }

    @Test("Where keep posts is the shorter, it lets them go first and the page says so")
    func keepWins() async throws {
        let (session, _) = await shell()
        await session.markGone(Self.note().key, at: Self.posted)
        let fortyDays = Self.posted.addingTimeInterval(40 * 86_400)
        #expect(await session.letGoneGo(waitingDays: 90, keepingMonths: 1, from: fortyDays) == 1)

        #expect(GoneSection.keepWinsLine(days: 90, keepingMonths: 1, language: .english) != nil)
        #expect(GoneSection.keepWinsLine(days: nil, keepingMonths: 3, language: .english) != nil, "never is longer")
        #expect(GoneSection.keepWinsLine(days: 7, keepingMonths: 3, language: .english) == nil)
        #expect(GoneSection.keepWinsLine(days: 7, keepingMonths: nil, language: .english) == nil)
    }

    @Test("The wait holds after a relaunch, and so does never")
    func waitSurvivesRelaunch() throws {
        let name = "fediqo.test.gone.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // Constructing prefs sets the shell's language from what is kept; English, as every
        // other suite here sets it, so a run in parallel is not moved.
        defaults.set("en", forKey: "fediqo.dummy.language")

        #expect(DummyPrefs(defaults: defaults).goneDays == nil, "never, by default")
        DummyPrefs(defaults: defaults).goneDays = 30
        #expect(DummyPrefs(defaults: defaults).goneDays == 30)
        DummyPrefs(defaults: defaults).goneDays = nil
        #expect(DummyPrefs(defaults: defaults).goneDays == nil)
    }

    @Test("Every line the section says has words in every language")
    func sectionWords() {
        let keys = [
            "prefs.gone", "prefs.gone.wait", "prefs.gone.never", "prefs.gone.now",
            "prefs.gone.went.none", "prefs.gone.footer",
        ]
        for language in [DummyLanguage.english, .taiwanese] {
            for key in keys {
                #expect(L10n.t(key, language: language) != key, "\(key) in \(language)")
            }
            #expect(GoneSection.wentLine(3, language: language).contains("3"))
            #expect(GoneSection.wentLine(0, language: language) == L10n.t("prefs.gone.went.none", language: language))
            #expect(L10n.count("prefs.gone.days", 7, language: language).contains("7"))
            #expect(GoneSection.keepWinsLine(days: nil, keepingMonths: 3, language: language)?.contains("3") == true)
        }
    }
}

#if os(macOS)
/// The mark stands on the row's meta line and does not make the row a second height (#179).
@MainActor
@Suite("The gone mark keeps the row's height", .serialized)
struct GoneMarkHostedTests {
    private static func height(_ item: DummyItem, width: CGFloat) -> CGFloat {
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(http: FixtureHTTP()),
                               marks: .constant(DummyMarks()), onToast: { _ in })
        let host = NSHostingView(rootView: row.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test("A marked row measures what an unmarked one does, wide and phone-narrow")
    func sameHeight() {
        var note = Note(
            id: "https://a-rather-long-host-name.example/users/ada/statuses/9",
            source: Source(host: "a-rather-long-host-name.example", kind: .mastodon),
            author: "Ada", handle: "@ada@a-rather-long-host-name.example", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public], audience: .everyone
        )
        let plain = DummyItem(note)
        note.goneSince = Date(timeIntervalSince1970: 1_700_000_000)
        let gone = DummyItem(note)
        for width: CGFloat in [720, 375] {
            #expect(Self.height(gone, width: width) == Self.height(plain, width: width), "at \(width)")
        }
    }
}
#endif
