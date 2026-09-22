import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A post is answered from inside the conversation it belongs to (#108).
///
/// What a test can reach: which posts offer an answer and what the row says where one does not;
/// where the reach starts; that the answer goes to the post's own source and names the post; that
/// a failure keeps every character and the same press sends again; that what landed is laid into
/// the open conversation under what it answers, with nothing read again; the key, and every word
/// of the surface in every language. What it cannot: the sheet itself on a Mac and a phone, in
/// light and dark, and VoiceOver walking it — that lives in a view body.
@Suite("Answering a post")
@MainActor
struct AnswerTests {
    init() {
        L10n.language = .english
    }

    private let host = "social.example"
    private let writing = MastodonOAuth.scopes(writing: true)

    /// A status as the source sends it, answering `parent` where one is named.
    static func status(
        _ id: String, by who: String = "ada", answering parent: String? = nil,
        visibility: String = "public", body: String = "hello"
    ) -> String {
        let reply = parent.map { #","in_reply_to_id":"\#($0)""# } ?? ""
        return """
        {"id":"\(id)","uri":"https://social.example/users/\(who)/statuses/\(id)",
         "created_at":"2024-06-01T0\(id.count):00:00.000Z","content":"<p>\(body)</p>",
         "visibility":"\(visibility)"\(reply),
         "account":{"username":"\(who)","acct":"\(who)","display_name":"\(who.capitalized)"}}
        """
    }

    private func root(visibility: Audience? = .followers) -> Note {
        Note(
            id: "https://social.example/users/ada/statuses/9",
            source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: "@ada@social.example", body: "the post",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home],
            audience: visibility, statusID: "9"
        )
    }

    private func shell(
        scopes: String?, holding: Note, routes: [String: ActServer.Outcome] = [:]
    ) async throws -> (ShellSession, ActServer) {
        let tokens = MemoryMastodonTokens()
        if let scopes {
            try tokens.save(MastodonToken(
                host: host, accessToken: "tok-123", clientID: "cid", clientSecret: "csecret",
                scopes: scopes
            ))
        }
        let server = ActServer(routes)
        let store = ItemStore()
        await store.add(Source(host: host, kind: .mastodon))
        await store.ingest([holding])
        let session = ShellSession(
            http: FixtureHTTP(), store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        return (session, server)
    }

    private func item(_ session: ShellSession) throws -> DummyItem {
        DummyItem(try #require(session.notes.first))
    }

    // MARK: - Offered, or said why not

    @Test("A post on a source not signed in to with writing offers no answer, and says why")
    func notSignedInOffersNothing() async throws {
        let (reads, _) = try await shell(scopes: MastodonOAuth.reading, holding: root())
        let post = try item(reads)
        #expect(!reads.openAnswer(to: post, in: post))
        #expect(reads.answering == nil)
        #expect(reads.acts(on: post).refused == .notSignedIn)

        let (none, _) = try await shell(scopes: nil, holding: root())
        #expect(!none.openAnswer(to: try item(none), in: try item(none)))
    }

    // MARK: - The surface

    @Test("The answer opens on the post, its author named, its reach no wider than the post")
    func theAnswerOpens() async throws {
        let (session, _) = try await shell(scopes: writing, holding: root(visibility: .followers))
        let post = try item(session)
        #expect(session.openAnswer(to: post, in: post))
        let target = try #require(session.answering)
        #expect(target.item == post && target.root == post)
        #expect(target.start == .followers)
        #expect(session.answerReach[post.id] == .followers)
        #expect(session.answerDraft(target) == "@ada@social.example ", "the author is named first")
        #expect(!AnswerSheet.widens(.followers, from: target.start))
        #expect(!AnswerSheet.widens(.mentioned, from: target.start))
        #expect(AnswerSheet.widens(.everyone, from: target.start), "widening is said where it is chosen")
    }

    @Test("A post whose reach was never told starts at the narrowest")
    func anUnknownReachStartsNarrow() async throws {
        let (session, _) = try await shell(scopes: writing, holding: root(visibility: nil))
        let post = try item(session)
        session.openAnswer(to: post, in: post)
        #expect(session.answering?.start == .mentioned)
    }

    @Test("Every word of the answer surface is in every language, and the post is spoken")
    func everyWord() {
        for language in [DummyLanguage.english, .taiwanese] {
            for key in ["answer.title", "answer.to", "answer.goesTo", "answer.reach", "answer.wider",
                        "answer.body", "answer.send", "item.act.answer", "shortcut.answer"] {
                #expect(L10n.t(key, language: language) != key, "\(key) has no words in \(language)")
            }
        }
        #expect(AnswerSheet.goesTo(host: host) == "Goes to social.example")
        let post = DummyItem(root())
        #expect(AnswerSheet.answering(post) == "Answering Ada the post")
        #expect(ItemActs.spoken(.answer, done: false, standing: nil) == "Answer")
    }

    @Test("w answers, and is the draft's while typing")
    func theKey() {
        #expect(DummyCommand.from("w") == .answer)
        #expect(DummyCommand.from("w", typing: true) == nil)
        #expect(DummyShortcut.all.contains { $0.commands == [.answer] && $0.touch == .press })
    }

    // MARK: - Sending

    @Test("A send that fails keeps every character, and the same send goes again")
    func aFailureKeepsTheText() async throws {
        let (session, server) = try await shell(
            scopes: writing, holding: root(), routes: ["/api/v1/statuses": .fail]
        )
        let post = try item(session)
        session.openAnswer(to: post, in: post)
        let target = try #require(session.answering)
        let written = "@ada@social.example  yes — and 100% so, «quoted» + more\n"
        session.answerDrafts[target.id] = written
        await #expect(throws: URLError.self) { try await session.answer(target) }
        #expect(session.answerDraft(target) == written, "every character kept")
        await #expect(throws: URLError.self) { try await session.answer(target) }
        #expect(await server.paths == ["/api/v1/statuses", "/api/v1/statuses"])
    }

    @Test("The answer goes to the post's own source, names the post, and at the reach chosen")
    func theAnswerNamesThePost() async throws {
        let (session, server) = try await shell(
            scopes: writing, holding: root(),
            routes: [
                "/api/v1/statuses/9/context": .json(#"{"ancestors":[],"descendants":[]}"#),
                "/api/v1/statuses": .json(Self.status("20", by: "me", answering: "9", visibility: "private")),
            ]
        )
        let post = try item(session)
        await session.conversations.open(post, in: session)
        session.openAnswer(to: post, in: post)
        let target = try #require(session.answering)
        session.answerDrafts[target.id] = "@ada yes"
        try await session.answer(target)
        let form = await server.form("/api/v1/statuses")
        #expect(form["in_reply_to_id"] == "9")
        #expect(form["visibility"] == "private")
        #expect(session.answerDrafts[target.id] == nil, "a landing clears the draft")
    }

    @Test("What landed is in the conversation under what it answers, with nothing read again")
    func whatLandedIsInPlace() async throws {
        let context = """
        {"ancestors":[],"descendants":[\(Self.status("12", by: "bo", answering: "9")),
         \(Self.status("13", by: "cy", answering: "12")),
         \(Self.status("14", by: "di", answering: "9"))]}
        """
        let (session, server) = try await shell(
            scopes: writing, holding: root(),
            routes: [
                "/api/v1/statuses/9/context": .json(context),
                "/api/v1/statuses": .json(Self.status("20", by: "me", answering: "12", body: "mine")),
            ]
        )
        let post = try item(session)
        await session.conversations.open(post, in: session)
        let bo = try #require(session.conversations.conversation(around: post).descendants.first?.item)
        #expect(session.openAnswer(to: bo, in: post))
        let target = try #require(session.answering)
        session.answerDrafts[target.id] = "mine"
        try await session.answer(target)

        let thread = session.conversations.conversation(around: post)
        #expect(thread.descendants.map(\.item.body) == ["hello", "hello", "mine", "hello"],
                "after the last post under the one it answers, before the next answer to the root")
        let mine = try #require(thread.descendants.first { $0.item.body == "mine" })
        #expect(mine.depth == 2, "under what it answers")
        #expect(await server.paths.filter { $0.hasSuffix("/context") }.count == 1,
                "the conversation was not read again")
    }

    @Test("Answering a post alone makes it a conversation of one answer")
    func answeringALonePost() async throws {
        let (session, _) = try await shell(
            scopes: writing, holding: root(),
            routes: [
                "/api/v1/statuses/9/context": .json(#"{"ancestors":[],"descendants":[]}"#),
                "/api/v1/statuses": .json(Self.status("20", by: "me", answering: "9", body: "first")),
            ]
        )
        let post = try item(session)
        await session.conversations.open(post, in: session)
        session.openAnswer(to: post, in: post)
        let target = try #require(session.answering)
        session.answerDrafts[target.id] = "first"
        try await session.answer(target)
        let thread = session.conversations.conversation(around: post)
        #expect(thread.descendants.map(\.item.body) == ["first"])
        #expect(thread.descendants.first?.depth == 1)
    }

    @Test("An answer is placed after the last post under its parent, and never twice")
    func placement() throws {
        func note(_ id: String, _ parent: String) throws -> Note {
            try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Self.status(id, answering: parent).utf8))
                .asNote(source: Source(host: host, kind: .mastodon), categories: [])
        }
        let held = [try note("12", "9"), try note("13", "12"), try note("15", "13"), try note("14", "9")]
        let under12 = try note("20", "12")
        #expect(ShellConversations.placed(under12, in: held, rootID: "9").map(\.statusID)
            == ["12", "13", "15", "20", "14"])
        let underRoot = try note("21", "9")
        #expect(ShellConversations.placed(underRoot, in: held, rootID: "9").last?.statusID == "21")
        #expect(ShellConversations.placed(held[1], in: held, rootID: "9") == held)
    }

    @Test("An answer to a row that stands for two copies names the post as the row's own copy's source does")
    func aMergedRowIsAnsweredThroughItsOwnCopy() async throws {
        let tokens = MemoryMastodonTokens()
        for signed in ["a.example", "b.example"] {
            try tokens.save(MastodonToken(
                host: signed, accessToken: "tok-\(signed)", clientID: "cid", clientSecret: "csecret",
                scopes: writing
            ))
        }
        let server = ActServer(["/api/v1/statuses": .json(Self.status("20", by: "me", answering: "111"))])
        let store = ItemStore()
        func copy(on host: String, _ statusID: String) -> Note {
            Note(
                id: "https://origin.example/users/ada/statuses/1",
                source: Source(host: host, kind: .mastodon),
                author: "Ada", handle: "@ada@origin.example", body: "hello",
                postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home],
                audience: .everyone, statusID: statusID
            )
        }
        for host in ["a.example", "b.example"] { await store.add(Source(host: host, kind: .mastodon)) }
        await store.ingest([copy(on: "a.example", "111"), copy(on: "b.example", "222")])
        let session = ShellSession(
            http: FixtureHTTP(), store: store,
            mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        let row = try #require(DummyItem.merged(session.notes).first)
        let own = row.source.host
        let ownID = try #require(row.statusID)

        #expect(session.openAnswer(to: row, in: row))
        let target = try #require(session.answering)
        session.answerDrafts[target.id] = "yes"
        try? await session.answer(target)
        let request = try #require(await server.requests.first)
        #expect(await server.requests.count == 1)
        #expect(request.url?.host == own, "the answer goes to the row's own source")
        #expect(await server.form("/api/v1/statuses")["in_reply_to_id"] == ownID,
                "named by the id that source gave the post, never the other copy's")
    }
}
