import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #321, "You there": what a source's page is handed of what the person set at that source,
/// what is asked for it and when, and what the block says in each state — only where the
/// reader is signed in, as whoever is signed in, and never of a forum.
///
/// Every wait here is on an ask arriving or being let go (`PageServer`), and is tied to the
/// work that made the ask: a held ask is let go in a `defer`, and by a guard when the run has
/// gone still — never by `PageServer`'s own patience, which every hold here turns off.
@MainActor
@Suite("What the person set at a source, on that source's page", .serialized, .watched)
struct YouThereTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let asked = "/api/v1/preferences"
    private static let who = "/api/v1/accounts/verify_credentials"

    private static func set(_ reach: String = "unlisted", _ language: String = "zh-TW", covered: Bool = true) -> PageServer.Answer {
        PageServer.Answer(body: #"{"posting:default:visibility":"\#(reach)","posting:default:sensitive":\#(covered),"posting:default:language":"\#(language)","reading:expand:media":"default"}"#)
    }

    private static let unlisted = PostingDefaults(reach: .known(.unlisted), language: "zh-TW", coversMedia: true)
    private static let notGiven = PageServer.Answer(body: #"{"error":"This action is outside the authorized scopes"}"#, status: 403)

    private func session(_ routes: [String: PageServer.Answer]) async -> (ShellSession, PageServer, SourceWork) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        // Every deadline an ask waits on, on a clock nobody turns: an ask held at its server is not
        // ended by one — what is asked through the sign-in included — and no check here waits for
        // one to pass.
        session.deadlinesUnturned()
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        for source in [Self.source, Self.forum] { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server, work)
    }

    /// Waits until `ask` has arrived at `server` `times` times, by the work that was to send it
    /// — and not by `PageServer.arrival`, which gives up by a clock.
    private func arrival(
        of ask: String, at server: PageServer, times: Int = 1, by work: Task<Void, Never>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await met("the ask of \(ask) has arrived at its server, \(times) in all", by: work, sourceLocation: sourceLocation) {
            await server.asked.count { $0 == ask } >= times
        }
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

    private static var shell: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI/Shell")
    }

    /// Hands out the wires of a test one at a time, in order: the first ask's, then the next's.
    @MainActor
    private final class Wires {
        var servers: [PageServer]
        init(_ servers: [PageServer]) { self.servers = servers }
        func next() -> PageServer { servers.count > 1 ? servers.removeFirst() : servers[0] }
    }

    /// Wires that go on answering an ask that was called off, each ask through the next server.
    private func bare(_ you: ShellYouThere, _ servers: [PageServer]) {
        let wires = Wires(servers)
        you.reaching = { token in
            MastodonSettings(door: MastodonAuthorized(token: token, sender: wires.next(), store: MemoryMastodonTokens()))
        }
    }

    // MARK: - What is asked, and when

    @Test("Opening the page of a source the reader is signed in to asks it what they set there — one ask, as them, through the signed-in door, of that host, listed in the run's record as that, and nothing held — and the page is handed the three; opened again, nobody is asked")
    func openingAsksOnceAsTheReader() async throws {
        let (session, server, work) = await session([Self.asked: Self.set()])
        try signIn(session)
        let you = ShellPersonPages().you
        #expect(you.said(at: Self.host, in: session) == YouThereSaid(source: Self.host), "before anything answered")
        await you.opened(Self.host, in: session)
        #expect(await server.asked == [Self.asked])
        #expect(await server.bearers == ["Bearer tok"])
        #expect(work.record.map(\.purpose) == [.ownSettings] && work.record.allSatisfy { $0.reached == Self.host && $0.source == Self.host })
        #expect(you.said(at: Self.host, in: session) == YouThereSaid(source: Self.host, reading: .said(Self.unlisted)))
        #expect(session.notes.isEmpty && session.composeAudience == .everyone, "nothing is held, and no post starts from it")
        #expect(await session.store.held(host: Self.host).isEmpty)

        await you.opened(Self.host, in: session)
        await you.again(Self.host, in: session)
        #expect(await server.asked.count == 1, "answered: asked once a run")
        #expect(ShellYouThere.opening(Self.host, in: session) == ShellPersonPages.Opening(id: Self.host, askedAs: .reader(nil)))
    }

    @Test("With no sign-in there is no block and nobody is asked; a forum has none, signed in or not; and what a sign-in was given is not drawn once it has ended")
    func onlyWhereSignedIn() async throws {
        let (session, server, work) = await session([Self.asked: Self.set()])
        let pages = ShellPersonPages()
        let you = pages.you
        #expect(you.said(at: Self.host, in: session) == nil && you.said(at: Self.forum.host, in: session) == nil)
        await you.opened(Self.host, in: session)
        await you.again(Self.host, in: session)
        await you.opened(Self.forum.host, in: session)
        await you.again(Self.forum.host, in: session)
        #expect(await server.asked.isEmpty && work.record.isEmpty)

        // Even a sign-in kept under a forum's name makes no block there: the source is not one asked who people are.
        try session.mastodon.tokens.save(MastodonToken(host: Self.forum.host, accessToken: "odd", clientID: "c", clientSecret: "s"))
        session.mastodon.refresh()
        #expect(session.mastodon.signedInHosts.contains(Self.forum.host) && you.said(at: Self.forum.host, in: session) == nil)
        await you.opened(Self.forum.host, in: session)
        await you.again(Self.forum.host, in: session)
        #expect(await server.asked.isEmpty)

        try signIn(session)
        await you.opened(Self.host, in: session)
        #expect(you.said(at: Self.host, in: session)?.reading == .said(Self.unlisted))
        try signOut(session)
        #expect(you.said(at: Self.host, in: session) == nil, "ended: not drawn")
        await you.opened(Self.host, in: session)
        #expect(await server.asked == [Self.asked], "and nobody is asked for nobody")

        func height<Block: View>(_ block: Block) -> CGFloat {
            let hosted = NSHostingView(rootView: VStack(spacing: 0) { block }.frame(width: 460))
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize.height
        }
        #expect(height(YouThereBlock(host: Self.host, you: you, session: session)) == 0)
        #expect(height(YouThereBlock(host: Self.forum.host, you: you, session: session)) == 0, "a forum's page gains nothing")
        try signIn(session)
        #expect(height(YouThereBlock(host: Self.host, you: you, session: session)) > 0)
        #expect(height(YouThereBlock(host: Self.forum.host, you: you, session: session)) == 0)
        #expect(await server.asked == [Self.asked], "drawing asks nobody: the asking is the page opening")

        for file in ["SourceYouThere.swift", "ShellYouThere.swift"] {
            let text = try String(contentsOf: Self.shell.appending(path: file), encoding: .utf8)
            // The pages reach the session's sign-ins, which are named for what they sign in to:
            // that is the one place the word stands, and nothing is decided by it.
            let reaches = file == "ShellYouThere.swift" ? ["session.mastodon."] : []
            let read = reaches.reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
            for word in ["ProtocolKind", ".kind ", ".kind)", ".kind.", "isForum", ".mastodon", ".discuz", ".discourse", "offers.", "compose"] {
                #expect(!read.contains(word), "\(file) names \(word)")
            }
        }
        let asked = try String(contentsOf: Self.shell.appending(path: "ShellYouThere.swift"), encoding: .utf8)
        #expect(asked.contains("ShellPersonPages.source(at:"), "the one fact is read where a person's page reads it")
    }

    @Test("A sign-in the source refuses this is said to have not been given it, in one sentence with no press: it is not asked again by opening or by any press, and the sign-in stands")
    func aSignInNotGivenIt() async throws {
        let (session, server, _) = await session([Self.asked: Self.notGiven])
        try signIn(session)
        let you = ShellPersonPages().you
        await you.opened(Self.host, in: session)
        #expect(you.said(at: Self.host, in: session) == YouThereSaid(source: Self.host, reading: .notGiven))
        #expect(YouThereSaid.notGiven(Self.host, language: .english) == "This sign-in was not given what m.example uses for your new posts.")
        await you.opened(Self.host, in: session)
        await you.again(Self.host, in: session)
        #expect(await server.asked == [Self.asked], "refused once is refused for the run")
        #expect(session.mastodon.signedInHosts.contains(Self.host) && session.mastodon.ended.isEmpty)
        #expect(ShellYouThere.wasNotGiven(MastodonAuthError.http(403)) && !ShellYouThere.wasNotGiven(MastodonAuthError.http(401)))
        #expect(!ShellYouThere.wasNotGiven(MastodonAuthError.signedOut) && !ShellYouThere.wasNotGiven(MastodonRequestError.http(403)))
    }

    @Test("A failure says so and offers the press that asks again — one ask a press, and a press or an opening while that ask is on the wire asks nothing more; a sign-out the door confirmed is told to the session, and the block is gone with the sign-in")
    func aFailureAsksAgainAtAPress() async throws {
        let (session, server, _) = await session([Self.asked: PageServer.Answer(body: "", status: 500)])
        try signIn(session)
        let you = ShellPersonPages().you
        await you.opened(Self.host, in: session)
        #expect(you.said(at: Self.host, in: session) == YouThereSaid(source: Self.host, reading: .failed))
        await you.opened(Self.host, in: session)
        #expect(await server.asked.count == 1, "a failure is not asked again by opening")

        await server.answer(Self.asked, Self.set())
        await server.hold(Self.asked, lettingGoByItself: false)
        defer { Task { await server.release(Self.asked) } }
        let askedGuard = watching("the ask of \(Self.asked), held at its server") { await server.release(Self.asked) }
        defer { askedGuard.cancel() }
        let press = Task { await you.again(Self.host, in: session) }
        await arrival(of: Self.asked, at: server, times: 2, by: press)
        #expect(you.said(at: Self.host, in: session) == YouThereSaid(source: Self.host, reading: .failed, asking: true))
        await you.again(Self.host, in: session)
        let visit = Task { await you.opened(Self.host, in: session) }
        #expect(await server.asked.count == 2, "one on the wire, and no second")
        await server.release(Self.asked)
        await press.value
        await visit.value
        #expect(you.said(at: Self.host, in: session)?.reading == .said(Self.unlisted))
        #expect(await server.asked.count == 2)

        let over = PageServer.Answer(body: #"{"error":"The access token is invalid"}"#, status: 401)
        let (other, gone, _) = await self.session([Self.asked: over, Self.who: over])
        try signIn(other)
        let ended = ShellPersonPages().you
        await ended.opened(Self.host, in: other)
        #expect(await gone.asked == [Self.asked, Self.who] && other.mastodon.ended == [Self.host])
        #expect(ended.said(at: Self.host, in: other) == nil)
    }

    @Test("An ask that was stopped before it answered leaves a block that says nothing of it and is asked again when the page opens, never one that says Asking for the rest of the run")
    func aStoppedAskIsAskedAgain() async throws {
        let (session, server, _) = await session([Self.asked: PageServer.Answer(body: "", cancelled: true)])
        try signIn(session)
        let you = ShellPersonPages().you
        await you.opened(Self.host, in: session)
        #expect(you.said(at: Self.host, in: session) == YouThereSaid(source: Self.host, reading: .asking, asking: false))
        await you.again(Self.host, in: session)
        #expect(await server.asked.count == 1, "nothing failed: there is no press to ask again by")
        await server.answer(Self.asked, Self.set())
        await you.opened(Self.host, in: session)
        #expect(you.said(at: Self.host, in: session)?.reading == .said(Self.unlisted))
    }

    @Test("Opened again while its ask is on the wire, the page waits on that ask and starts none")
    func openedTwiceWhileOnTheWire() async throws {
        let (session, server, _) = await session([Self.asked: Self.set()])
        try signIn(session)
        let you = ShellPersonPages().you
        await server.hold(Self.asked, lettingGoByItself: false)
        defer { Task { await server.release(Self.asked) } }
        let askedGuard = watching("the ask of \(Self.asked), held at its server") { await server.release(Self.asked) }
        defer { askedGuard.cancel() }
        let first = Task { await you.opened(Self.host, in: session) }
        await arrival(of: Self.asked, at: server, by: first)
        #expect(you.said(at: Self.host, in: session) == YouThereSaid(source: Self.host, asking: true))
        let second = Task { await you.opened(Self.host, in: session) }
        await server.release(Self.asked)
        await first.value
        await second.value
        #expect(await server.asked == [Self.asked] && you.said(at: Self.host, in: session)?.reading == .said(Self.unlisted))
    }

    // MARK: - As whoever asked

    @Test("What a source says one reader set is that reader's: when the sign-in changes, what the last was given is let go and the page is asked as whoever is signed in now — and the answer to the one before, come late, lands nowhere, whether it is what they set, a refusal, or a failure")
    func asWhoeverAsked() async throws {
        let late: [PageServer.Answer?] = [Self.set("private", "fr", covered: false), Self.notGiven, PageServer.Answer(body: "", status: 500), nil]
        for answer in late {
            let (session, _, _) = await session([:])
            let first = PageServer(answer.map { [Self.asked: $0] } ?? [:]), second = PageServer([Self.asked: Self.set()])
            let you = ShellPersonPages().you
            bare(you, [first, second])
            try signIn(session, as: "one")
            await first.hold(Self.asked, lettingGoByItself: false)
            defer { Task { await first.release(Self.asked) } }
            let askedGuard = watching("the ask of \(Self.asked), held at its server") { await first.release(Self.asked) }
            defer { askedGuard.cancel() }
            let before = Task { await you.opened(Self.host, in: session) }
            await arrival(of: Self.asked, at: first, by: before)
            #expect(you.said(at: Self.host, in: session)?.asking == true)

            try signIn(session, as: "two")
            await you.opened(Self.host, in: session)
            #expect(you.said(at: Self.host, in: session) == YouThereSaid(source: Self.host, reading: .said(Self.unlisted)))
            await first.release(Self.asked)
            await before.value
            #expect(you.said(at: Self.host, in: session) == YouThereSaid(source: Self.host, reading: .said(Self.unlisted)), "the late answer was nobody's")
            let asked = await first.bearers + second.bearers
            #expect(asked == ["Bearer one", "Bearer two"])
            #expect(session.mastodon.ended.isEmpty)
        }
    }

    @Test("A reader who signs out while the ask is on the wire is shown nothing, and its answer lands nowhere: signed in again as another, the page is asked afresh")
    func signedOutWhileAsking() async throws {
        let (session, _, _) = await session([:])
        let first = PageServer([Self.asked: Self.set("private", "fr", covered: false)]), second = PageServer([Self.asked: Self.set()])
        let you = ShellPersonPages().you
        bare(you, [first, second])
        try signIn(session, as: "one")
        await first.hold(Self.asked, lettingGoByItself: false)
        defer { Task { await first.release(Self.asked) } }
        let askedGuard = watching("the ask of \(Self.asked), held at its server") { await first.release(Self.asked) }
        defer { askedGuard.cancel() }
        let before = Task { await you.opened(Self.host, in: session) }
        await arrival(of: Self.asked, at: first, by: before)
        try signOut(session)
        #expect(you.said(at: Self.host, in: session) == nil)
        await first.release(Self.asked)
        await before.value
        #expect(you.said(at: Self.host, in: session) == nil)
        try signIn(session, as: "two")
        #expect(you.said(at: Self.host, in: session) == YouThereSaid(source: Self.host), "the one before's is not the next one's")
        await you.opened(Self.host, in: session)
        #expect(you.said(at: Self.host, in: session)?.reading == .said(Self.unlisted))
    }

    @Test("Once the source has named the reader, an answer is that reader's by name: asked a moment before the name was learnt it is still theirs, and it is not drawn for whoever the source names next")
    func byName() async throws {
        let (session, server, _) = await session([Self.asked: Self.set(), Self.who: PageServer.Answer(body: #"{"id":"1","acct":"me"}"#)])
        try signIn(session)
        let you = ShellPersonPages().you
        await you.opened(Self.host, in: session)
        await session.mastodon.learnWho(host: Self.host)
        #expect(ShellPersonPages.askedAs(at: Self.host, in: session) == .reader("@me@m.example"))
        #expect(you.said(at: Self.host, in: session)?.reading == .said(Self.unlisted), "the same reader, named since")
        await you.opened(Self.host, in: session)
        #expect(await server.asked.filter { $0 == Self.asked }.count == 1)

        await server.answer(Self.who, PageServer.Answer(body: #"{"id":"2","acct":"you"}"#))
        await session.mastodon.learnWho(host: Self.host)
        #expect(you.said(at: Self.host, in: session) == YouThereSaid(source: Self.host), "another by name: not theirs")
    }

    // MARK: - What the block says

    @Test("Each setting is said in the app's own words where it has them — a reach as a row says a post's, a language by its name, media as covered or not — and as the source wrote it where it has none; one the source did not say is not listed")
    func theWords() {
        #expect(YouThereSaid.title(language: .english) == "You there")
        #expect(YouThereSaid.line("m.example", language: .english) == "What m.example uses for a new post of yours.")
        #expect(YouThereSaid.askingLine("m.example", language: .english) == "Asking m.example what it uses for your new posts…")
        #expect(YouThereSaid.failed("m.example", language: .english) == "Could not ask m.example what it uses for your new posts.")
        #expect(YouThereSaid.nothing("m.example", language: .english) == "m.example said nothing of what it uses for a new post of yours.")
        #expect(YouThereSaid.Fact.allCases.map { YouThereSaid.label($0, language: .english) } == ["A new post is for", "Its language", "Its media"])
        #expect(Audience.allCases.map { YouThereSaid.reach(.known($0), language: .english) } == ["Public", "Unlisted", "Followers", "Mentioned"])
        #expect(YouThereSaid.reach(.other("local only"), language: .taiwanese) == "local only")
        #expect(YouThereSaid.languageName("en", language: .english) == "English")
        #expect(YouThereSaid.languageName("zh-TW", language: .english) == L10n.locale(.english).localizedString(forIdentifier: "zh-TW"))
        #expect(YouThereSaid.languageName("zh-TW", language: .english).contains("Chinese"))
        #expect(YouThereSaid.languageName("en", language: .taiwanese) == "英文")
        // What is no tag is the source's word, drawn as it wrote it and looked up nowhere.
        for word in ["two words", "en_US;rm", "語言", "en/../x"] {
            #expect(YouThereSaid.languageName(word, language: .english) == word)
        }
        #expect(YouThereSaid.media(covered: true, language: .english) == "Covered" && YouThereSaid.media(covered: false, language: .english) == "Not covered")

        let all = YouThereSaid.facts(of: Self.unlisted, language: .english)
        #expect(all.map(\.fact) == [.reach, .language, .media] && all.map(\.value)[0] == "Unlisted" && all.map(\.value)[2] == "Covered")
        let some = YouThereSaid.facts(of: PostingDefaults(reach: .other("local"), coversMedia: false), language: .english)
        #expect(some.map(\.fact) == [.reach, .media] && some.map(\.value) == ["local", "Not covered"])
        #expect(YouThereSaid.facts(of: PostingDefaults()).isEmpty)
    }

    @Test("Every sentence of the block is written in each language the app speaks, with the places it fills, and the two Chinese tables alike; the ask is listed as one of the source's own")
    func writtenInEveryLanguage() throws {
        let resources = Self.shell.deletingLastPathComponent().appending(path: "Resources")
        let english = try String(contentsOf: resources.appending(path: "en.lproj/Localizable.strings"), encoding: .utf8)
        let keys = english.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\"source.you.") || line.hasPrefix("\"work.purpose.ownSettings\"") else { return nil }
            return line.dropFirst().split(separator: "\"").first.map(String.init)
        }
        #expect(keys.count == 13 && keys.contains("source.you.notGiven") && keys.contains("work.purpose.ownSettings"))
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
            #expect(!L10n.t(key, language: .taiwanese).contains("站台"), "\(key): a source the person added is a 來源")
        }
        let taiwan = try Data(contentsOf: resources.appending(path: "zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appending(path: "zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
        #expect(SourceWork.Purpose.ownSettings.isOfTheSource && !SourceWork.Purpose.ownSettings.gathers)
        #expect(!SourceWork.Purpose.ownSettings.symbol.isEmpty)
    }

    @Test("The block is laid out to the width it is given and never past it, in light and in dark, in each state it has: asking, the three said, a word the source wrote, nothing said, not given, and a failure")
    func theBlockLaidOut() {
        func size(_ said: YouThereSaid, _ width: CGFloat, _ scheme: ColorScheme) -> CGSize {
            let block = VStack(spacing: 0) { YouThereSection(said: said) }.frame(width: width).environment(\.colorScheme, scheme)
            let hosted = NSHostingView(rootView: block)
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize
        }
        let odd = PostingDefaults(reach: .other(String(repeating: "w", count: 35)), language: String(repeating: "x", count: 35), coversMedia: nil)
        let states: [YouThereSaid.Reading] = [.asking, .said(Self.unlisted), .said(odd), .said(PostingDefaults()), .notGiven, .failed]
        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (460, .dark), (390, .light), (320, .dark)] {
            for reading in states {
                let drawn = size(YouThereSaid(source: "a-rather-long-name-of-a-server.example", reading: reading, asking: reading == .asking), width, scheme)
                #expect(drawn.width == width && drawn.height > 0, "\(reading) at \(width)")
            }
            let head = size(YouThereSaid(source: Self.host), width, scheme).height
            #expect(size(YouThereSaid(source: Self.host, reading: .said(Self.unlisted)), width, scheme).height > head)
            #expect(size(YouThereSaid(source: Self.host, reading: .notGiven), width, scheme).height > head)
            #expect(size(YouThereSaid(source: Self.host, asking: true), width, scheme).height > head, "asking is said only while an ask is out")
        }
    }
}
