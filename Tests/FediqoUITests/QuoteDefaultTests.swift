import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #437: a new post's choice of who may quote it starts from what the person set at the source,
/// and that setting is read and changed from the source's page.
///
/// Every wait here is on an ask arriving (`PageServer`), tied to the work that made it.
@MainActor
@Suite("Who may quote a new post starts from the source's setting", .serialized, .watched)
struct QuoteDefaultTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let all = "\(reading) write:accounts"
    private static let reading = MastodonOAuth.scopes(writing: true)
    private static let settings = "/api/v1/preferences"
    private static let who = "/api/v1/accounts/verify_credentials"
    private static let document = "/api/v2/instance"
    private static let change = "/api/v1/accounts/update_credentials"
    private static let post = "/api/v1/statuses"

    private static func set(_ policy: String) -> PageServer.Answer {
        PageServer.Answer(body: #"{"posting:default:visibility":"public","posting:default:quote_policy":"\#(policy)"}"#)
    }

    private static func own(_ policy: String) -> PageServer.Answer {
        PageServer.Answer(body: #"""
        {"id":"7","acct":"me","username":"me","display_name":"Me","note":"","fields":[],"followers_count":0,"following_count":0,"statuses_count":0,
         "source":{"note":"","fields":[],"quote_policy":"\#(policy)"}}
        """#)
    }

    private static func instance(api: Int?) -> PageServer.Answer {
        let versions = api.map { #","api_versions":{"mastodon":\#($0)}"# } ?? ""
        return PageServer.Answer(body: #"{"domain":"m.example","title":"M","version":"4.6.6"\#(versions)}"#)
    }

    private struct Made {
        let session: ShellSession
        let server: PageServer
        let hosts: ShellHostsKnown
        let pages: ShellPersonPages
        let you: ShellYouThere
    }

    private func made(api: Int? = 11, policy: String = "followers", scopes: String = QuoteDefaultTests.all) async throws -> Made {
        let server = PageServer([
            Self.settings: Self.set(policy), Self.who: Self.own(policy), Self.document: Self.instance(api: api),
            Self.change: Self.own("nobody"),
        ])
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        session.work = SourceWork()
        await session.store.add(Self.source)
        session.sources = await session.store.sources()
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        let hosts = ShellHostsKnown(errands: PageErrands())
        session.quoting.hosts = hosts
        await session.reloadFromStore()
        session.prepareCompose()
        let pages = ShellPersonPages()
        session.personPages = pages
        return Made(session: session, server: server, hosts: hosts, pages: pages, you: pages.you)
    }

    private func form(_ server: PageServer) async -> [String] {
        await server.sent.filter { $0.ask == Self.change }.map(\.body)
    }

    // MARK: - The composer

    @Test("The menu's unsaid line names the source's setting where it is handed one; a menu handed none says what it always said, and the change sheet hands none")
    func theWords() throws {
        #expect(QuoteWords.unsaid(host: Self.host, language: .english) == "As your account at m.example is set")
        #expect(QuoteWords.unsaid(host: Self.host, set: .nobody, language: .english) == "As your account at m.example is set: Only you")
        #expect(QuotePolicyMenu(draft: .constant(PostDraft()), host: Self.host).set == nil)
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1, !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root.deleteLastPathComponent()
        }
        let change = try String(contentsOf: root.appending(path: "Sources/FediqoUI/Shell/ChangeSheet.swift"), encoding: .utf8)
        #expect(change.contains("QuotePolicyMenu(draft: Bindable(changes).draft, host: host)"))
    }

    @Test("A new post shows the source's setting, nothing of it is copied into the draft, and a post sent carries nothing of its own into the next")
    func aNewPost() async throws {
        let made = try await made()
        let session = made.session
        #expect(session.composeQuoteSet(host: Self.host) == nil, "before anything answered")
        await session.loadComposeDefaults()
        #expect(session.composeQuoteSet(host: Self.host) == .followers)
        #expect(session.composeDraft.quotePolicy == nil && session.composeDraft.quotePolicySent == nil, "nothing to send")

        session.composeDraft.quotePolicy = .nobody
        await session.loadComposeDefaults()
        session.postingDefaultsChanged(at: Self.host)
        await session.loadComposeDefaults()
        #expect(session.composeDraft.quotePolicy == .nobody, "a draft's own choice stays")

        session.composeDraft.text = "words"
        #expect(session.send())
        #expect(session.composeDraft.quotePolicy == nil, "the next post starts from the setting again")
    }

    @Test("What one sign-in was told is not named for another at the same host; a new look asks again")
    func anotherReader() async throws {
        let made = try await made()
        let session = made.session
        await session.loadComposeDefaults()
        #expect(session.composeQuoteSet(host: Self.host) == .followers)
        let held = try #require(try session.mastodon.tokens.token(host: Self.host))
        _ = try session.mastodon.tokens.forget(held)
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "theirs", clientID: "c", clientSecret: "s", scopes: Self.all, asked: Self.all
        ))
        session.mastodon.refresh()
        #expect(session.composeQuoteSet(host: Self.host) == nil)
        await made.server.answer(Self.settings, Self.set("nobody"))
        await session.loadComposeDefaults()
        #expect(session.composeQuoteSet(host: Self.host) == .nobody)
    }

    // MARK: - The row

    @Test("A source with no quotes is handed no row, its account is not read for one, and a press sends nothing; what is drawn of that is `theRowLaidOut`")
    func noQuotesNoTrace() async throws {
        let made = try await made(api: 1)
        await made.you.quotesOpened(Self.host, in: made.session)
        #expect(made.you.quotes(at: Self.host, in: made.session) == nil)
        #expect(await made.server.arrivals(of: Self.document) == 1)
        #expect(await made.server.arrivals(of: Self.who) == 1, "only who signed in was asked")
        #expect(made.you.chooseQuotes(.nobody, at: Self.host, in: made.session) == nil)
    }

    @Test("A source whose account says nothing of it draws no row")
    func unsaidNoRow() async throws {
        let made = try await made()
        await made.server.answer(Self.who, Self.own("somebody"))
        await made.you.quotesOpened(Self.host, in: made.session)
        #expect(made.you.quotes(at: Self.host, in: made.session) == nil)
    }

    @Test("A sign-in without the account part sees the lock and what the source said, what its press asks opens the question for the part, and the account is not read")
    func theLock() async throws {
        let made = try await made(scopes: Self.reading)
        await made.you.opened(Self.host, in: made.session)
        await made.you.quotesOpened(Self.host, in: made.session)
        let row = try #require(made.you.quotes(at: Self.host, in: made.session))
        guard case .locked(let sentence, let set) = row.shape else {
            Issue.record("not locked: \(row.shape)")
            return
        }
        #expect(!sentence.isEmpty && !sentence.contains("%@") && set == .followers)
        #expect(await made.server.arrivals(of: Self.who) == 1, "only who signed in was asked")
        #expect(made.you.chooseQuotes(.nobody, at: Self.host, in: made.session) == nil)
        #expect(made.session.askFor([.account], host: Self.host))
        #expect(made.session.partAsks.open?.ticked == [.account])
    }

    @Test("A change sends that alone; the composer and the page ask again, and the next new post names the new setting")
    func aChange() async throws {
        let made = try await made()
        let (session, server, you) = (made.session, made.server, made.you)
        await session.loadComposeDefaults()
        await you.opened(Self.host, in: session)
        await you.quotesOpened(Self.host, in: session)
        #expect(you.quotes(at: Self.host, in: session)?.shape == .held(.followers, sending: false, told: nil))
        let turned = you.opening(Self.host, in: session)

        await server.answer(Self.settings, Self.set("nobody"))
        await you.chooseQuotes(.nobody, at: Self.host, in: session)?.value
        #expect(await form(server) == ["source%5Bquote_policy%5D=nobody"])
        #expect(you.quotes(at: Self.host, in: session)?.shape == .held(.nobody, sending: false, told: nil))
        #expect(you.opening(Self.host, in: session) != turned, "a block up asks again")
        #expect(session.composeQuoteSet(host: Self.host) == nil, "what was said is let go")
        await session.loadComposeDefaults()
        #expect(session.composeQuoteSet(host: Self.host) == .nobody)
        #expect(you.chooseQuotes(.nobody, at: Self.host, in: session) == nil, "what it holds sends nothing")
    }

    @Test("Two quick presses send one change, and a press after it goes from what the source answered")
    func twoQuickPresses() async throws {
        let made = try await made()
        let (session, server, you) = (made.session, made.server, made.you)
        await you.quotesOpened(Self.host, in: session)
        await server.hold(Self.change)
        let guarded = watching("the change, held at its server") { await server.release(Self.change) }
        defer { guarded.cancel() }
        let first = try #require(you.chooseQuotes(.nobody, at: Self.host, in: session))
        await server.arrival(of: Self.change, by: first)
        #expect(you.quotes(at: Self.host, in: session)?.shape == .held(.nobody, sending: true, told: nil))
        #expect(you.chooseQuotes(.anyone, at: Self.host, in: session) == nil)
        await server.release(Self.change)
        await first.value
        #expect(await form(server).count == 1)
        await you.chooseQuotes(.anyone, at: Self.host, in: session)?.value
        #expect(await form(server).last == "source%5Bquote_policy%5D=public")
    }

    @Test("The answer to a read of the settings already out when a change lands is written nowhere: the menu names nothing until it asks again, and then what the source says now")
    func aReadOnItsWay() async throws {
        let made = try await made()
        let (session, server, you) = (made.session, made.server, made.you)
        await session.loadComposeDefaults()
        session.postingDefaultsChanged(at: Self.host)
        await server.hold(Self.settings)
        let guarded = watching("the settings, held at their server") { await server.release(Self.settings) }
        defer { guarded.cancel() }
        let late = Task { await session.loadComposeDefaults() }
        await server.arrival(of: Self.settings, times: 2, by: late)
        await you.quotesOpened(Self.host, in: session)
        await you.chooseQuotes(.nobody, at: Self.host, in: session)?.value
        await server.release(Self.settings)
        await late.value
        #expect(session.composeQuoteSet(host: Self.host) == nil, "the old answer lands nowhere")
        await server.answer(Self.settings, Self.set("nobody"))
        await session.loadComposeDefaults()
        #expect(session.composeQuoteSet(host: Self.host) == .nobody)
    }

    @Test("A refusal changes nothing and says the source's own word, on the row where it names it")
    func aRefusal() async throws {
        let made = try await made()
        let (session, server, you) = (made.session, made.server, made.you)
        await session.loadComposeDefaults()
        await you.quotesOpened(Self.host, in: session)
        await server.answer(Self.change, PageServer.Answer(
            body: #"{"error":"Bad","details":{"quote_policy":[{"description":"is not valid"}]}}"#, status: 422
        ))
        await you.chooseQuotes(.nobody, at: Self.host, in: session)?.value
        #expect(you.quotes(at: Self.host, in: session)?.shape == .held(.followers, sending: false, told: .refused("is not valid")))
        #expect(session.composeQuoteSet(host: Self.host) == .followers, "nothing changed: the composer's word stays")
        #expect(YouThereQuotesRow.words(.refused(""), source: Self.host, language: .english) == "m.example would not take that.")
    }

    @Test("A change with no answer may have landed: everything is let go, the account read again, and the row says so")
    func noAnswer() async throws {
        let made = try await made()
        let (session, server, you) = (made.session, made.server, made.you)
        await session.loadComposeDefaults()
        await you.quotesOpened(Self.host, in: session)
        await server.answer(Self.change, nil)
        await server.answer(Self.who, Self.own("nobody"))
        await you.chooseQuotes(.nobody, at: Self.host, in: session)?.value
        #expect(session.composeQuoteSet(host: Self.host) == nil)
        await you.quotesOpened(Self.host, in: session)
        #expect(you.quotes(at: Self.host, in: session)?.shape == .held(.nobody, sending: false, told: .missed))
    }

    @Test("A sign-in that took another's place while its change is out sees neither that change's choice nor its answer, and can send its own; the first answer does not end the second's")
    func anotherSignInWhileAChangeIsOut() async throws {
        let made = try await made()
        let (session, server, you) = (made.session, made.server, made.you)
        await you.quotesOpened(Self.host, in: session)
        await server.hold(Self.change)
        let guarded = watching("the changes, held at their server") { await server.release(Self.change) }
        defer { guarded.cancel() }
        let first = try #require(you.chooseQuotes(.nobody, at: Self.host, in: session))
        await server.arrival(of: Self.change, by: first)
        let before = you.quotesOpening(Self.host, in: session)

        let held = try #require(try session.mastodon.tokens.token(host: Self.host))
        _ = try session.mastodon.tokens.forget(held)
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "theirs", clientID: "c", clientSecret: "s", scopes: Self.all, asked: Self.all
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        #expect(ShellPersonPages.askedAs(at: Self.host, in: session) == before.page.askedAs, "the same name")
        #expect(you.quotesOpening(Self.host, in: session) != before, "and still another sign-in: the row's task runs again")
        #expect(you.quotes(at: Self.host, in: session)?.shape == .asking, "what the last was told is not theirs, nor is its choice")
        await server.answer(Self.who, Self.own("public"))
        await you.quotesOpened(Self.host, in: session)
        #expect(you.quotes(at: Self.host, in: session)?.shape == .held(.anyone, sending: false, told: nil))

        let second = try #require(you.chooseQuotes(.followers, at: Self.host, in: session), "their press goes")
        await server.arrival(of: Self.change, times: 2, by: second)
        #expect(you.quotes(at: Self.host, in: session)?.shape == .held(.followers, sending: true, told: nil))

        await server.releaseOne(Self.change)
        await first.value
        #expect(you.quotes(at: Self.host, in: session)?.shape == .asking, "the first answer lets go, and is drawn for nobody")
        await you.quotesOpened(Self.host, in: session)
        #expect(you.quotes(at: Self.host, in: session)?.shape == .held(.followers, sending: true, told: nil), "the second is still out")

        await server.release(Self.change)
        await second.value
        #expect(you.quotes(at: Self.host, in: session)?.shape == .held(.nobody, sending: false, told: nil), "its own answer stands")
    }

    @Test("The row's words for the part gone name the source; the path to them is not reached here")
    func thePartGone() {
        #expect(YouThereQuotesRow.words(.partGone, source: Self.host, language: .english) == "m.example says this sign-in was not given that change.")
    }

    @Test("The row draws no height with no quotes, and held, locked and failed each draw within the width given, in light and in dark")
    func theRowLaidOut() async throws {
        func size(_ made: Made, _ width: CGFloat, _ scheme: ColorScheme) -> CGSize {
            let row = VStack(spacing: 0) { YouThereQuotesRow(host: Self.host, you: made.you, session: made.session) }
                .frame(width: width).environment(\.colorScheme, scheme)
            let hosted = NSHostingView(rootView: row)
            hosted.layoutSubtreeIfNeeded()
            return hosted.fittingSize
        }
        let none = try await made(api: 1)
        await none.you.quotesOpened(Self.host, in: none.session)
        let held = try await made()
        await held.you.quotesOpened(Self.host, in: held.session)
        let locked = try await made(scopes: Self.reading)
        await locked.you.opened(Self.host, in: locked.session)
        await locked.you.quotesOpened(Self.host, in: locked.session)
        let failed = try await made()
        await failed.server.answer(Self.who, PageServer.Answer(body: "", status: 500))
        await failed.you.quotesOpened(Self.host, in: failed.session)

        #expect(none.you.quotes(at: Self.host, in: none.session) == nil)
        #expect(held.you.quotes(at: Self.host, in: held.session)?.shape == .held(.followers, sending: false, told: nil))
        guard case .locked? = locked.you.quotes(at: Self.host, in: locked.session)?.shape else {
            Issue.record("not locked")
            return
        }
        #expect(failed.you.quotes(at: Self.host, in: failed.session)?.shape == .failed)

        for (width, scheme) in [(CGFloat(720), ColorScheme.light), (320, .dark), (720, .dark), (320, .light)] {
            #expect(size(none, width, scheme).height == 0)
            for state in [held, locked, failed] {
                let drawn = size(state, width, scheme)
                #expect(drawn.width == width && drawn.height > 0, "\(String(describing: state.you.quotes(at: Self.host, in: state.session)?.shape)) at \(width)")
            }
        }
    }

    @Test("A read that failed says so, and its press asks once more")
    func aFailedRead() async throws {
        let made = try await made()
        let (session, server, you) = (made.session, made.server, made.you)
        await server.answer(Self.who, PageServer.Answer(body: "", status: 500))
        await you.quotesOpened(Self.host, in: session)
        #expect(you.quotes(at: Self.host, in: session)?.shape == .failed)
        await server.answer(Self.who, Self.own("public"))
        await you.quotesAgain(Self.host, in: session)
        #expect(you.quotes(at: Self.host, in: session)?.shape == .held(.anyone, sending: false, told: nil))
    }
}
