import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// What you wrote can be taken back from the app you wrote it in (#109).
///
/// What a test can reach: that the act is offered only on the reader's own posts on a source
/// signed in with writing, and never on anybody else's; that asking sends nothing and cancelling
/// leaves everything as it was; that the question names what goes; that a confirmed act leaves the
/// timeline and the store and a failed one leaves the post where it is to be asked again; the key.
/// What it cannot: the question drawn on a Mac and a phone, in light and dark, and VoiceOver
/// reaching it — that lives in a view body.
@Suite("Taking back what you wrote")
@MainActor
struct WithdrawTests {
    init() {
        L10n.language = .english
    }

    private let host = "social.example"
    private let writing = MastodonOAuth.scopes(writing: true)

    private func post(_ id: String, by who: String) -> Note {
        Note(
            id: "https://social.example/users/\(who)/statuses/\(id)",
            source: Source(host: host, kind: .mastodon),
            author: who.capitalized, handle: "@\(who)@social.example", body: "words of \(who) \(id)",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)!), categories: [.home],
            statusID: id
        )
    }

    /// A shell signed in as `me`, holding one post of theirs and one of somebody else's, having
    /// asked the source who the reader is — which is the only way this device knows.
    private func shell(
        scopes: String? = MastodonOAuth.scopes(writing: true),
        me: String? = "me",
        routes: [String: ActServer.Outcome] = [:]
    ) async throws -> (ShellSession, ActServer) {
        let tokens = MemoryMastodonTokens()
        if let scopes {
            try tokens.save(MastodonToken(
                host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
                scopes: scopes
            ))
        }
        var all = routes
        if let me {
            all["/api/v1/accounts/verify_credentials"] = .json(#"{"acct":"\#(me)"}"#)
        }
        let server = ActServer(all)
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon))
        await store.ingest([post("1", by: "me"), post("2", by: "ada")])
        let session = ShellSession(
            http: FixtureHTTP(), store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.mastodon.verifyAll()
        await session.reloadFromStore()
        return (session, server)
    }

    private func item(_ session: ShellSession, by who: String) throws -> DummyItem {
        DummyItem(try #require(session.notes.first { $0.handle == "@\(who)@social.example" }))
    }

    // MARK: - Offered only on your own

    @Test("Offered on the reader's own post, never on somebody else's")
    func onlyYourOwn() async throws {
        let (session, _) = try await shell()
        #expect(session.mastodon.handles[host] == "@me@social.example", "asked of the source")
        #expect(session.acts(on: try item(session, by: "me")).offers(.withdraw))
        #expect(!session.acts(on: try item(session, by: "ada")).offers(.withdraw))
        #expect(!session.askToWithdraw(try item(session, by: "ada")))
        #expect(session.withdrawing == nil)
    }

    @Test("Not offered where the source is not signed in to with writing, or has not said who you are")
    func onlyOnASignedInSource() async throws {
        let (reads, _) = try await shell(scopes: MastodonOAuth.reading)
        #expect(!reads.acts(on: try item(reads, by: "me")).offers(.withdraw))

        let (unknown, _) = try await shell(me: nil)
        #expect(unknown.mastodon.handles.isEmpty)
        #expect(!unknown.acts(on: try item(unknown, by: "me")).offers(.withdraw),
                "not known is not yours")
    }

    @Test("Signing out forgets who you are, so nothing is offered for taking back")
    func signingOutForgets() async throws {
        let (session, _) = try await shell(routes: ["/oauth/revoke": .json("{}")])
        await session.mastodon.signOut(host: host)
        #expect(session.mastodon.handles[host] == nil)
        #expect(!session.acts(on: try item(session, by: "me")).offers(.withdraw))
    }

    // MARK: - Asked, and answered

    @Test("Asking sends nothing, and cancelling leaves everything as it was")
    func askingAndCancelling() async throws {
        let (session, server) = try await shell()
        let mine = try item(session, by: "me")
        let before = session.notes
        #expect(session.askToWithdraw(mine))
        #expect(session.withdrawing == mine)
        session.cancelWithdraw()
        #expect(session.withdrawing == nil)
        #expect(session.notes == before)
        #expect(session.acts.standings.isEmpty)
        #expect(await server.methods.allSatisfy { $0 == "GET" }, "only the account check was asked")
    }

    @Test("The question names what goes and where it goes from, in every language")
    func theQuestionNamesWhatGoes() async throws {
        let (session, _) = try await shell()
        let mine = try item(session, by: "me")
        let question = ItemActs.withdrawQuestion(mine)
        #expect(question.title == "Take this post back?")
        #expect(question.detail.contains("words of me 1"))
        #expect(question.detail.contains(host))
        #expect(question.detail.contains("does not come back"))
        let chinese = ItemActs.withdrawQuestion(mine, language: .taiwanese)
        #expect(chinese.detail.contains("words of me 1") && chinese.detail.contains(host))
        for key in ["withdraw.title", "withdraw.detail", "withdraw.confirm", "item.act.withdraw",
                    "shortcut.withdraw"] {
            #expect(L10n.t(key, language: .taiwanese) != key)
        }
        #expect(ItemActs.spoken(.withdraw, done: false, standing: .failed)
            == "Take back what you wrote did not arrive. Press to try again.")
    }

    @Test("d asks, and is the draft's while typing")
    func theKey() {
        #expect(DummyCommand.from("d") == .withdraw)
        #expect(DummyCommand.from("d", typing: true) == nil)
    }

    // MARK: - Confirmed

    @Test("Confirmed, it goes from the source, then from the timeline, with no full reload")
    func confirmedItGoes() async throws {
        let (session, server) = try await shell(routes: ["/api/v1/statuses/1": .json("{}")])
        var saved = 0
        session.persist = { saved += 1 }
        let mine = try item(session, by: "me")
        session.askToWithdraw(mine)
        await session.withdraw(mine)
        #expect(session.withdrawing == nil)
        #expect(await server.requests.last?.httpMethod == "DELETE")
        #expect(await server.paths.last == "/api/v1/statuses/1")
        #expect(!session.notes.contains { $0.key.rowID == mine.id })
        #expect(session.notes.count == 1, "somebody else's post stays")
        #expect(await session.store.all().count == 1, "gone from what a save writes")
        #expect(saved == 1)
        #expect(session.acts.standings.isEmpty)
        #expect(await server.paths.filter { $0.contains("timelines") }.isEmpty, "no timeline read")
    }

    @Test("A failure leaves the post where it is, says so, and can be asked again")
    func aFailureKeepsThePost() async throws {
        let (session, server) = try await shell(routes: ["/api/v1/statuses/1": .fail])
        let mine = try item(session, by: "me")
        await session.withdraw(mine)
        #expect(session.notes.contains { $0.key.rowID == mine.id })
        #expect(session.acts.standing(of: mine.id, .withdraw) == .failed)
        #expect(session.askToWithdraw(mine), "the same act asks again")
        await session.withdraw(mine)
        #expect(await server.paths.filter { $0 == "/api/v1/statuses/1" }.count == 2)
    }
}
