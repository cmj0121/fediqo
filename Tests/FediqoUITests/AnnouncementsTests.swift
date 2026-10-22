import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #321, what a source announces: what its page is handed, what is asked for it and when, the
/// mark on its row, what seen and dismissed each are, and a reaction — only where the reader is
/// signed in, as whoever is signed in, and never of a forum.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), tied to the work that
/// made it; the fifteen minutes are a clock this check turns by hand.
@MainActor
@Suite("What a source announces, on its page and its row", .serialized, .watched)
struct AnnouncementsTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let asked = "/api/v1/announcements"
    private static let dismissing = "/api/v1/announcements/2/dismiss"
    private static let thumbs = "/api/v1/announcements/2/reactions/👍"
    private static let party = "/api/v1/announcements/2/reactions/🎉"
    private static let reads = "read:statuses read:lists read:accounts"
    private static let all = "\(reads) write:statuses write:favourites write:accounts"

    /// Two announcements as a real server lists them: one not dismissed, one the source says is read.
    private static func listed(thumbs count: Int = 12, mine: Bool = false, secondRead: Bool = true) -> PageServer.Answer {
        PageServer.Answer(body: #"""
        [{"id":"2","content":"<p>Maintenance on Sunday.</p>","published_at":"2026-10-12T09:00:00.000Z","updated_at":"2026-10-12T09:00:00.000Z",
          "starts_at":null,"ends_at":null,"all_day":false,"read":false,"mentions":[],"statuses":[],"tags":[],"emojis":[],
          "reactions":[{"name":"👍","count":\#(count),"me":\#(mine)}]},
         {"id":"1","content":"<p>Welcome.</p>","published_at":"2026-10-10T00:00:00.000Z","read":\#(secondRead),
          "reactions":[{"name":"❤️","count":40,"me":true}]}]
        """#)
    }

    private static let done = PageServer.Answer(body: "{}")

    /// The clock the fifteen minutes are read on, turned by hand.
    @MainActor
    private final class Clock {
        var at = ContinuousClock.now
        func turn(_ by: Duration = ShellAnnouncements.between) { at = at.advanced(by: by) }
    }

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server, work)
    }

    private func pages(_ clock: Clock) -> ShellAnnouncements {
        let announcements = ShellPersonPages().announcements
        announcements.now = { clock.at }
        return announcements
    }

    private func signOut(_ session: ShellSession) throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        session.mastodon.refresh()
    }

    private func signIn(_ session: ShellSession, as access: String = "tok", holding scopes: String = AnnouncementsTests.all) throws {
        try signOut(session)
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: access, clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
    }

    private static var shell: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI/Shell")
    }

    // MARK: - What is asked, and when

    @Test("Opening a signed-in source's page asks it what it announces — once, as the reader, listed as that — and draws the one not dismissed as New with the dismissed folded under it; opened again within fifteen minutes nobody is asked, after them it is asked again")
    func openingAsks() async throws {
        let (session, server, work) = await session([Self.asked: Self.listed()])
        try signIn(session)
        let clock = Clock()
        let announcements = pages(clock)
        #expect(announcements.said(at: Self.host, in: session)?.reading == .asking, "before anything answered")
        await announcements.opened(Self.host, in: session)
        #expect(await server.asked == [Self.asked])
        #expect(await server.bearers == ["Bearer tok"])
        #expect(work.record.map(\.purpose) == [.announcements] && work.record.allSatisfy { $0.reached == Self.host })
        let said = try #require(announcements.said(at: Self.host, in: session))
        #expect(said.reading == .said && said.shown.map(\.id) == ["2"] && said.dismissed.map(\.id) == ["1"] && said.folded)
        #expect(said.shown[0].new && !said.dismissed[0].new, "a dismissed one is not New")
        #expect(said.shown[0].reactions == [AnnouncementsSaid.Reaction(name: "👍", count: 12, mine: false, picture: nil)])
        #expect(said.reacts && said.dismissLock == nil)
        #expect(await session.store.held(host: Self.host).isEmpty, "nothing is held")

        await announcements.opened(Self.host, in: session)
        #expect(announcements.checked(Self.host, in: session) == nil)
        #expect(await server.asked.count == 1, "within fifteen minutes: asked once")
        clock.turn()
        await announcements.opened(Self.host, in: session)
        #expect(await server.asked.count == 2, "fifteen minutes on, the page opening asks again")
    }

    @Test("A round that read the source asks it, at most once every fifteen minutes whatever asked last; the reload tells each host a timeline's or the wait's round got through to, and none it did not")
    func roundsAsk() async throws {
        let (session, server, _) = await session([Self.asked: Self.listed()])
        try signIn(session)
        let clock = Clock()
        let announcements = pages(clock)
        let first = try #require(announcements.checked(Self.host, in: session))
        await first.value
        #expect(await server.asked == [Self.asked])
        #expect(announcements.checked(Self.host, in: session) == nil)
        await announcements.opened(Self.host, in: session)
        #expect(await server.asked.count == 1, "the page opening is held back by the round's ask")
        clock.turn(.seconds(14 * 60))
        #expect(announcements.checked(Self.host, in: session) == nil)
        clock.turn(.seconds(60))
        await announcements.checked(Self.host, in: session)?.value
        #expect(await server.asked.count == 2)
        #expect(announcements.checked(Self.forum.host, in: session) == nil, "a forum is asked nothing")

        // The reload's own round, of a source that answers and of one that does not.
        for answers in [true, false] {
            let quiet = "quiet.example"
            let http = FixtureHTTP(answers ? [
                MastodonInstance.address(quiet): MastodonInstance.mastodon(quiet),
                "/api/v1/timelines/public": .text("[]"),
                "/api/v1/trends/statuses": .text("[]"),
            ] : [:])
            let reading = ShellSession(
                http: http, store: ItemStore(),
                pictures: ShellPictures(http: FixtureHTTP()),
                emojis: EmojiCache(http: FixtureHTTP()),
                forums: ForumSessions(credentials: MemoryCredentials()),
                mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: PageServer([:])),
                posts: ForumPosts(http: http)
            )
            reading.work = SourceWork()
            reading.jar = SystemJar(
                cookies: HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "fediqo.tests.\(UUID())"),
                credentials: .shared
            )
            await reading.store.add(Source(host: quiet, kind: .mastodon))
            await reading.reloadFromStore()
            final class Heard { var hosts: [String] = [] }
            let heard = Heard()
            reading.reload.sourceAnswered = { heard.hosts.append($0) }
            await reading.reload.held(in: reading)
            #expect(heard.hosts == (answers ? [quiet] : []), "answered: \(answers)")
        }
    }

    @Test("With no sign-in there is no block and nobody is asked; a forum has none; and once the sign-in ends nothing is drawn, the mark goes out, and nobody is asked")
    func onlyWhereSignedIn() async throws {
        let (session, server, work) = await session([Self.asked: Self.listed()])
        let announcements = pages(Clock())
        #expect(announcements.said(at: Self.host, in: session) == nil && announcements.said(at: Self.forum.host, in: session) == nil)
        await announcements.opened(Self.host, in: session)
        await announcements.opened(Self.forum.host, in: session)
        #expect(announcements.checked(Self.host, in: session) == nil)
        #expect(await server.asked.isEmpty && work.record.isEmpty)

        try signIn(session)
        await announcements.checked(Self.host, in: session)?.value
        #expect(announcements.mark(at: Self.host, in: session) == 1)
        try signOut(session)
        #expect(announcements.said(at: Self.host, in: session) == nil && announcements.mark(at: Self.host, in: session) == nil)
        await announcements.opened(Self.host, in: session)
        #expect(await server.asked == [Self.asked])

        func height<Block: View>(_ block: Block) -> CGFloat {
            let hosted = NSHostingView(rootView: VStack(spacing: 0) { block }.frame(width: 460))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize.height
        }
        #expect(height(AnnouncementsBlock(host: Self.host, announcements: announcements, session: session)) == 0)
        try signIn(session)
        #expect(height(AnnouncementsBlock(host: Self.host, announcements: announcements, session: session)) > 0)
        #expect(height(AnnouncementsBlock(host: Self.forum.host, announcements: announcements, session: session)) == 0)
    }

    @Test("An empty list is not the host having none: no block and no mark, and the page asks again in time; a not-found of the address is the host having none, for the run; a sign-in the source refuses is said so, once, with no mark")
    func emptyAbsentForbidden() async throws {
        let (session, server, _) = await session([Self.asked: PageServer.Answer(body: "[]")])
        try signIn(session)
        let clock = Clock()
        let announcements = pages(clock)
        await announcements.opened(Self.host, in: session)
        #expect(announcements.said(at: Self.host, in: session) == nil && announcements.mark(at: Self.host, in: session) == nil)
        clock.turn()
        await server.answer(Self.asked, Self.listed())
        await announcements.opened(Self.host, in: session)
        #expect(announcements.said(at: Self.host, in: session)?.shown.map(\.id) == ["2"], "empty was not absent")

        let (gone, goneServer, _) = await self.session([Self.asked: PageServer.Answer(body: #"{"error":"Not Found"}"#, status: 404)])
        try signIn(gone)
        let none = pages(clock)
        await none.opened(Self.host, in: gone)
        #expect(none.said(at: Self.host, in: gone) == nil && none.mark(at: Self.host, in: gone) == nil)
        clock.turn()
        await none.opened(Self.host, in: gone)
        #expect(none.checked(Self.host, in: gone) == nil)
        #expect(await goneServer.asked == [Self.asked], "absent for the run")

        let refused = PageServer.Answer(body: #"{"error":"This action is outside the authorized scopes"}"#, status: 403)
        let (shut, shutServer, _) = await self.session([Self.asked: refused])
        try signIn(shut)
        let closed = pages(clock)
        await closed.opened(Self.host, in: shut)
        #expect(closed.said(at: Self.host, in: shut) == AnnouncementsSaid(
            source: Self.host, reading: .forbidden, reacts: true, dismissLock: nil
        ))
        #expect(closed.mark(at: Self.host, in: shut) == nil)
        clock.turn()
        await closed.opened(Self.host, in: shut)
        #expect(closed.checked(Self.host, in: shut) == nil)
        #expect(await shutServer.asked == [Self.asked] && shut.mastodon.signedInHosts.contains(Self.host))
    }

    @Test("A failure says so with a press that asks at once, and what was held stays drawn under it")
    func aFailureAsksAgain() async throws {
        let (session, server, _) = await session([Self.asked: Self.listed()])
        try signIn(session)
        let clock = Clock()
        let announcements = pages(clock)
        await announcements.opened(Self.host, in: session)
        clock.turn()
        await server.answer(Self.asked, PageServer.Answer(body: "", status: 500))
        await announcements.checked(Self.host, in: session)?.value
        let failed = try #require(announcements.said(at: Self.host, in: session))
        #expect(failed.reading == .failed && failed.shown.map(\.id) == ["2"], "held stays")
        await server.answer(Self.asked, Self.listed(secondRead: false))
        await announcements.again(Self.host, in: session)
        #expect(await server.asked.count == 3)
        #expect(announcements.said(at: Self.host, in: session)?.shown.map(\.id) == ["2", "1"])
        await announcements.again(Self.host, in: session)
        #expect(await server.asked.count == 3, "nothing failed: Try again asks nothing")
    }

    @Test("After a failure a round within fifteen minutes asks nothing, and one after them asks again")
    func aFailureWaitsForTheRound() async throws {
        let (session, server, _) = await session([Self.asked: PageServer.Answer(body: "", status: 500)])
        try signIn(session)
        let clock = Clock()
        let announcements = pages(clock)
        await announcements.checked(Self.host, in: session)?.value
        #expect(announcements.said(at: Self.host, in: session)?.reading == .failed)
        clock.turn(.seconds(14 * 60))
        #expect(announcements.checked(Self.host, in: session) == nil)
        #expect(await server.asked.count == 1, "within fifteen minutes: no second ask")
        await server.answer(Self.asked, Self.listed())
        clock.turn(.seconds(60))
        let round = try #require(announcements.checked(Self.host, in: session))
        await round.value
        #expect(await server.asked.count == 2)
        #expect(announcements.said(at: Self.host, in: session)?.reading == .said)
    }

    // MARK: - Seen, and the mark

    @Test("The mark is lit by what is neither seen nor dismissed, as last asked, and drawing it asks nothing; the page opened marks them seen — New while it stays open, not New when it opens again — and nothing is sent for it")
    func seenOnThisDevice() async throws {
        let (session, server, _) = await session([Self.asked: Self.listed(secondRead: false)])
        try signIn(session)
        let clock = Clock()
        let announcements = pages(clock)
        #expect(announcements.mark(at: Self.host, in: session) == nil)
        await announcements.checked(Self.host, in: session)?.value
        #expect(announcements.mark(at: Self.host, in: session) == 2)
        #expect(await server.asked.count == 1, "drawing the mark asks nothing")

        await announcements.opened(Self.host, in: session)
        #expect(announcements.mark(at: Self.host, in: session) == nil)
        #expect(announcements.said(at: Self.host, in: session)?.shown.map(\.new) == [true, true])
        announcements.left(Self.host)
        await announcements.opened(Self.host, in: session)
        #expect(announcements.said(at: Self.host, in: session)?.shown.map(\.new) == [false, false])
        #expect(await server.asked == [Self.asked], "seeing sends nothing")
        #expect(SourceRow.announcedSpoken(2, Self.host, language: .english) == "2 new announcements from m.example")
        #expect(SourceRow.announcedSpoken(1, Self.host, language: .english) == "1 new announcement from m.example")
        #expect(SourceRow.announcedSpoken(2, Self.host, language: .taiwanese) == "m.example 有 2 則新公告")
    }

    @Test("The row draws the megaphone only while it is handed a count, says the count to a listener and never draws it, and its press opens the source's page")
    func theRowsMark() {
        let row = SourceRow(source: Self.source, profile: .unasked(host: Self.host, kind: .mastodon), signedIn: true, writing: .writes)
        let mark = SourceRow.announcedMark(Self.host, language: .english)
        #expect(mark.symbol == "megaphone.fill" && mark.count == nil && mark.look == .live)
        #expect(mark.name == "m.example has announcements you have not seen. Opens its page.")
        func view(_ announced: Int?) -> SourceRowView {
            SourceRowView(
                row: row, actsLive: true, waiting: nil, refusal: nil, announced: announced,
                clearAsks: { ShellConfirmation(symbol: "x", title: "", line: "", help: nil, choices: []) },
                removeAsks: { ShellConfirmation(symbol: "x", title: "", line: "", help: nil, choices: []) },
                presses: SourceRow.Presses()
            )
        }
        #expect(view(3).heard.contains(SourceRow.announcedSpoken(3, Self.host)))
        #expect(!view(nil).heard.contains(SourceRow.announcedSpoken(1, Self.host)))
        #expect(SourceRow.heard(row: "r", said: ["s"], holds: "h", announced: "a") == "r a s h")
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(390), 320] {
                for announced in [nil, 2] as [Int?] {
                    let hosted = NSHostingView(rootView: view(announced).frame(width: width).environment(\.colorScheme, scheme))
                    hosted.layoutSubtreeIfNeeded()
                    #expect(hosted.fittingSize.width == width && hosted.fittingSize.height > 0)
                }
            }
        }
        #expect(AccountPane.sourcesHelp(language: .english).contains(L10n.t("account.sources.announced", language: .english)))
    }

    // MARK: - Dismiss

    @Test("Dismiss is asked first, folds at the yes, is sent to the source, and stays folded — a read already on its way says it is not and changes nothing; a miss puts it back and says so")
    func dismissing() async throws {
        let (session, server, _) = await session([Self.asked: Self.listed(), Self.dismissing: Self.done])
        try signIn(session)
        let clock = Clock()
        let announcements = pages(clock)
        await announcements.checked(Self.host, in: session)?.value
        let shown = try #require(announcements.said(at: Self.host, in: session)?.shown.first)
        let more = AnnouncementsSaid.more(shown, source: Self.host, lock: nil, onDismiss: {}, onAsk: {}, language: .english)
        let item = try #require(more.items.first)
        #expect(item.isDanger && item.question?.title == "Dismiss this announcement of m.example?")
        #expect(item.question?.chorded?.label == "Dismiss" && item.question?.cancel != nil)

        // A round's read is on its way when the yes is pressed, and lands saying it is not read.
        clock.turn()
        await server.hold(Self.asked)
        defer { Task { await server.release(Self.asked) } }
        let askedGuard = watching("the ask of \(Self.asked), held at its server") { await server.release(Self.asked) }
        defer { askedGuard.cancel() }
        let round = try #require(announcements.checked(Self.host, in: session))
        await server.arrival(of: Self.asked, times: 2, by: round)
        await announcements.dismiss("2", at: Self.host, in: session)
        #expect(await server.asked.filter { $0 == Self.dismissing }.count == 1)
        #expect(announcements.said(at: Self.host, in: session)?.dismissed.map(\.id) == ["2", "1"])
        await server.release(Self.asked)
        await round.value
        #expect(announcements.said(at: Self.host, in: session)?.dismissed.map(\.id) == ["2", "1"], "not undone by the read")
        #expect(announcements.mark(at: Self.host, in: session) == nil)
        #expect(announcements.said(at: Self.host, in: session) != nil, "every one dismissed: the fold line alone")

        let (other, otherServer, _) = await self.session([Self.asked: Self.listed(), Self.dismissing: PageServer.Answer(body: "", status: 500)])
        try signIn(other)
        let missing = pages(clock)
        await missing.opened(Self.host, in: other)
        await missing.dismiss("2", at: Self.host, in: other)
        let back = try #require(missing.said(at: Self.host, in: other))
        #expect(back.shown.map(\.id) == ["2"] && back.shown[0].missed == .dismiss)
        #expect(AnnouncementsSaid.missed(.dismiss, Self.host, language: .english) == "Could not dismiss this announcement at m.example.")
        #expect(await otherServer.asked.filter { $0 == Self.dismissing }.count == 1)
    }

    @Test("Without the account part Dismiss is dim with the lock, its press asks for the part, and nothing is sent")
    func dismissNeedsTheAccountPart() async throws {
        let (session, server, _) = await session([Self.asked: Self.listed(), Self.dismissing: Self.done])
        try signIn(session, holding: "\(Self.reads) write:statuses write:favourites")
        let announcements = pages(Clock())
        await announcements.opened(Self.host, in: session)
        let said = try #require(announcements.said(at: Self.host, in: session))
        let lock = try #require(said.dismissLock)
        #expect(lock.asks)
        final class Asked { var count = 0 }
        let asked = Asked()
        let more = AnnouncementsSaid.more(
            said.shown[0], source: Self.host, lock: lock, onDismiss: {}, onAsk: { asked.count += 1 }, language: .english
        )
        let item = try #require(more.items.first)
        #expect(!item.isDanger && item.look == .dim(.askAgain) && item.answers)
        #expect(more.whys.contains(String(format: L10n.t(lock.key, language: .english), Self.host)))
        item.press { _ in }
        #expect(asked.count == 1)
        await announcements.dismiss("2", at: Self.host, in: session)
        #expect(await !server.asked.contains(Self.dismissing))
    }

    // MARK: - Reactions

    @Test("A pill pressed puts the reader's reaction on, pressed again takes it back, Add puts a new one on — each sent once, drawn at once; a read already on its way undoes none of it, a read begun after says what the source says")
    func reacting() async throws {
        let (session, server, _) = await session([Self.asked: Self.listed(), Self.thumbs: Self.done, Self.party: Self.done])
        try signIn(session)
        let clock = Clock()
        let announcements = pages(clock)
        await announcements.opened(Self.host, in: session)
        func thumbs() -> AnnouncementsSaid.Reaction? {
            announcements.said(at: Self.host, in: session)?.shown.first?.reactions.first { $0.name == "👍" }
        }

        // A read on its way, begun before the press, answers as it was before.
        clock.turn()
        await server.hold(Self.asked)
        defer { Task { await server.release(Self.asked) } }
        let askedGuard = watching("the ask of \(Self.asked), held at its server") { await server.release(Self.asked) }
        defer { askedGuard.cancel() }
        let round = try #require(announcements.checked(Self.host, in: session))
        await server.arrival(of: Self.asked, times: 2, by: round)
        await announcements.react("👍", on: "2", at: Self.host, in: session)
        #expect(await server.asked.last == Self.thumbs)
        #expect(thumbs() == AnnouncementsSaid.Reaction(name: "👍", count: 13, mine: true, picture: nil))
        await server.release(Self.asked)
        await round.value
        #expect(thumbs()?.count == 13 && thumbs()?.mine == true, "not undone by the read")

        // A read begun after says what the source says.
        clock.turn()
        await server.answer(Self.asked, Self.listed(thumbs: 20, mine: true))
        await announcements.checked(Self.host, in: session)?.value
        #expect(thumbs()?.count == 20)

        await announcements.react("👍", on: "2", at: Self.host, in: session)
        #expect(thumbs()?.count == 19 && thumbs()?.mine == false)
        await announcements.react("🎉", on: "2", at: Self.host, adding: true, in: session)
        await announcements.react("🎉", on: "2", at: Self.host, adding: true, in: session)
        let party = announcements.said(at: Self.host, in: session)?.shown.first?.reactions.first { $0.name == "🎉" }
        #expect(party == AnnouncementsSaid.Reaction(name: "🎉", count: 1, mine: true, picture: nil))
        #expect(await server.asked.filter { $0.contains("/reactions/") } == [Self.thumbs, Self.thumbs, Self.party], "Add of one already yours sends nothing")
    }

    @Test("A reaction that did not arrive is put back and said; a sign-in that only reads draws the reactions as words and sends nothing — it is never asked for the acting part")
    func reactionsMissedAndRead() async throws {
        let (session, server, _) = await session([Self.asked: Self.listed(), Self.thumbs: PageServer.Answer(body: "", status: 500)])
        try signIn(session)
        let announcements = pages(Clock())
        await announcements.opened(Self.host, in: session)
        await announcements.react("👍", on: "2", at: Self.host, in: session)
        let shown = try #require(announcements.said(at: Self.host, in: session)?.shown.first)
        #expect(shown.reactions.first?.count == 12 && shown.reactions.first?.mine == false && shown.missed == .react("👍"))
        #expect(AnnouncementsSaid.missed(.react("👍"), Self.host, language: .english) == "Could not add your 👍 at m.example.")

        let (reading, readingServer, _) = await self.session([Self.asked: Self.listed(), Self.thumbs: Self.done])
        try signIn(reading, holding: Self.reads)
        let only = pages(Clock())
        await only.opened(Self.host, in: reading)
        #expect(only.said(at: Self.host, in: reading)?.reacts == false)
        await only.react("👍", on: "2", at: Self.host, in: reading)
        #expect(await readingServer.asked == [Self.asked])
        _ = server
    }

    @Test("What a reader hears of a reaction, and what Add takes: exactly one emoji, not a digit, a mark or two")
    func reactionWords() {
        let mine = AnnouncementsSaid.Reaction(name: "👍", count: 12, mine: true, picture: nil)
        #expect(AnnouncementsSaid.reactionSpoken(mine, language: .english) == "👍, 12, you among them")
        #expect(AnnouncementsSaid.reactionHint(mine, language: .english) == "Takes yours back")
        #expect(AnnouncementsSaid.oneEmoji("👍") == "👍" && AnnouncementsSaid.oneEmoji(" 🎉 ") == "🎉")
        #expect(AnnouncementsSaid.oneEmoji("👍🏽") == "👍🏽" && AnnouncementsSaid.oneEmoji("👨‍👩‍👧") == "👨‍👩‍👧")
        #expect(AnnouncementsSaid.oneEmoji("❤️") == "❤️" && AnnouncementsSaid.oneEmoji("©️") == "©️", "asked to be drawn as one")
        for typed in ["", "1", "#", "a", "👍👍", "ok", "*", "©", "®", "™", "‼"] {
            #expect(AnnouncementsSaid.oneEmoji(typed) == nil, "\(typed)")
        }
    }

    // MARK: - Words and the block

    @Test("When is the published time, or the time it is about — dates alone for whole days — with when it was edited after it")
    func when() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let day = { (text: String) in try #require(ISO8601DateFormatter().date(from: text)) }
        let plain = Announcement(id: "1", words: "w", publishedAt: try day("2026-10-12T09:00:00Z"))
        #expect(AnnouncementsSaid.when(plain, language: .english, zone: utc).contains("Oct"))
        let span = Announcement(id: "2", words: "w", startsAt: try day("2026-10-12T00:00:00Z"), endsAt: try day("2026-10-14T00:00:00Z"), allDay: true)
        let spanned = AnnouncementsSaid.when(span, language: .english, zone: utc)
        #expect(spanned.contains(" to ") && !spanned.contains(":"), "\(spanned)")
        let edited = Announcement(id: "3", words: "w", publishedAt: try day("2026-10-12T09:00:00Z"), updatedAt: try day("2026-10-13T09:00:00Z"))
        #expect(AnnouncementsSaid.when(edited, language: .english, zone: utc).contains(" · edited "))
        #expect(AnnouncementsSaid.when(Announcement(id: "4", words: "w")).isEmpty)
        #expect(AnnouncementsSaid.dismissedLine(1, language: .english) == "1 dismissed")
        #expect(AnnouncementsSaid.dismissedLine(3, language: .english) == "3 dismissed")
        #expect(AnnouncementsSaid.dismissedLine(3, language: .taiwanese) == "已關閉 3 則")
    }

    @Test("Every sentence of the block and the mark is written in each language the app speaks, with the places it fills, and the two Chinese tables alike; the ask is listed as one of the source's own")
    func writtenInEveryLanguage() throws {
        let resources = Self.shell.deletingLastPathComponent().appending(path: "Resources")
        let english = try String(contentsOf: resources.appending(path: "en.lproj/Localizable.strings"), encoding: .utf8)
        let keys = english.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\"announce.") || line.hasPrefix("\"account.source.announced")
                || line.hasPrefix("\"account.sources.announced") || line.hasPrefix("\"work.purpose.announcements")
            else { return nil }
            return line.dropFirst().split(separator: "\"").first.map(String.init)
        }
        #expect(keys.count == 34)
        func places(_ text: String) -> [String] {
            text.matches(of: /%(\d\$)?[@d]/).map { String($0.output.0) }.sorted()
        }
        for key in keys {
            let written = L10n.t(key, language: .english)
            for language in DummyLanguage.allCases {
                let other = L10n.t(key, language: language)
                #expect(other != key && places(other) == places(written), "\(key) in \(language)")
            }
            #expect(!L10n.t(key, language: .taiwanese).contains("站台"), "\(key)")
        }
        let taiwan = try Data(contentsOf: resources.appending(path: "zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appending(path: "zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
        #expect(SourceWork.Purpose.announcements.isOfTheSource && !SourceWork.Purpose.announcements.gathers)
    }

    @Test("The block is laid out to the width it is given and never past it, in light and in dark, in each state: asking, read with reactions and the fold open and shut, read by a sign-in that only reads, refused, failed")
    func theBlockLaidOut() {
        func size(_ said: AnnouncementsSaid, _ width: CGFloat, _ scheme: ColorScheme) -> CGSize {
            let block = VStack(spacing: 0) { AnnouncementsSection(said: said) }.frame(width: width).environment(\.colorScheme, scheme)
            let hosted = NSHostingView(rootView: block)
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize
        }
        let long = String(repeating: "A rather long announcement of maintenance. ", count: 8)
        let reactions = (0..<14).map { AnnouncementsSaid.Reaction(name: ["👍", "🎉", "❤️", "🙏"][$0 % 4], count: $0 * 97, mine: $0 == 2, picture: nil) }
        let one = AnnouncementsSaid.Shown(
            announcement: Announcement(id: "2", words: long, publishedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            reactions: reactions, new: true, missed: .react("👍")
        )
        let folded = AnnouncementsSaid.Shown(announcement: Announcement(id: "1", words: "Welcome."), reactions: [])
        let source = "a-rather-long-name-of-a-server.example"
        let states = [
            AnnouncementsSaid(source: source, asking: true),
            AnnouncementsSaid(source: source, reading: .said, shown: [one], dismissed: [folded], reacts: true),
            AnnouncementsSaid(source: source, reading: .said, shown: [one], dismissed: [folded], folded: false, reacts: true),
            AnnouncementsSaid(source: source, reading: .said, shown: [one], reacts: false),
            AnnouncementsSaid(source: source, reading: .forbidden),
            AnnouncementsSaid(source: source, reading: .failed, shown: [one]),
        ]
        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (460, .dark), (390, .light), (320, .dark)] {
            for said in states {
                let drawn = size(said, width, scheme)
                #expect(drawn.width == width && drawn.height > 0, "\(said.reading) at \(width)")
            }
            #expect(size(states[2], width, scheme).height > size(states[1], width, scheme).height, "the fold opens in place")
        }
        let placed = PillsWrap.rows([CGSize(width: 60, height: 20), CGSize(width: 60, height: 20), CGSize(width: 60, height: 20)], width: 130, spacing: 4)
        #expect(placed.origins.map(\.y) == [0, 0, 24] && placed.size == CGSize(width: 124, height: 44))
    }

    @Test("The two files name no kind of source: the one fact is read where a person's page reads it")
    func namesNoKind() throws {
        for file in ["Announcements.swift", "ShellAnnouncements.swift"] {
            let text = try String(contentsOf: Self.shell.appending(path: file), encoding: .utf8)
            let read = ["session.mastodon."].reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
            for word in ["ProtocolKind", ".kind ", ".kind)", ".kind.", "isForum", ".mastodon", ".discuz", ".discourse", "offers."] {
                #expect(!read.contains(word), "\(file) names \(word)")
            }
        }
        let asked = try String(contentsOf: Self.shell.appending(path: "ShellAnnouncements.swift"), encoding: .utf8)
        #expect(asked.contains("ShellPersonPages.source(at:"))
    }
}
