import Foundation
import Testing
@testable import FediqoCore

/// The acts a reader performs on a post someone else wrote, sent to the source it was read
/// through (#106, #107).
///
/// What this suite holds is the half of "survives a relaunch because the source says so" that
/// lives in Core: the mark's state is a field the server sends, carried on the note, laid over
/// what was held by what the server answers to the press, and never invented by a press that did
/// not land.
@Suite("Acting on a post")
struct MastodonActTests {
    private let host = MastodonFixture.host
    private let source = Source(host: MastodonFixture.host, kind: .mastodon)

    /// One status as the server sends it. `reblogged` is left out entirely where it is nil,
    /// because that is what an unsigned read looks like on the wire.
    static func status(id: String = "9", reblogged: Bool? = nil, favourited: Bool? = nil) -> String {
        let flag = (reblogged.map { #","reblogged":\#($0)"# } ?? "")
            + (favourited.map { #","favourited":\#($0)"# } ?? "")
        return """
        {"id":"\(id)","uri":"https://social.example/users/ada/statuses/\(id)",
         "created_at":"2024-06-01T00:00:00.000Z","content":"<p>hello</p>",
         "visibility":"public","reblogs_count":2\(flag),
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    /// The wrapper `/reblog` answers with: a status of the reader's own carrying the post inside.
    static func wrapper(around inner: String, reblogged: Bool) -> String {
        """
        {"id":"500","uri":"https://social.example/users/me/statuses/500/activity",
         "created_at":"2024-06-02T00:00:00.000Z","content":"","visibility":"public",
         "reblogged":\(reblogged),
         "account":{"username":"me","acct":"me","display_name":"Me"},
         "reblog":\(inner)}
        """
    }

    private func held(_ json: String) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: source, category: .home)
    }

    private func actor(
        holding note: Note, _ routes: [String: FixtureSender.Outcome]
    ) async throws -> (MastodonWrite, ItemStore, FixtureSender, MemoryMastodonTokens) {
        let store = ItemStore()
        await store.add(source)
        await store.ingest([note])
        let server = FixtureSender(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
        return (MastodonWrite(door: door, store: store), store, server, tokens)
    }

    // MARK: - What the source says

    @Test("Whether a post is boosted is what the source sent, and nothing where it sent nothing")
    func boostedIsTheSourcesWord() throws {
        #expect(try held(Self.status(reblogged: true)).boosted == true)
        #expect(try held(Self.status(reblogged: false)).boosted == false)
        // An unsigned read has no such field. Silence is not a no.
        #expect(try held(Self.status()).boosted == nil)
    }

    @Test("On a boost it is the post's own flag that is read, not the wrapper's")
    func aBoostReadsTheSubject() throws {
        let note = try held(Self.wrapper(around: Self.status(reblogged: false), reblogged: true))
        #expect(note.boosted == false)
        #expect(note.statusID == "9")
    }

    @Test("A read that says nothing keeps what an earlier read said; one that says something wins")
    func silenceDoesNotUndoAnAnswer() throws {
        let yes = try held(Self.status(reblogged: true))
        #expect(try held(Self.status()).refreshed(over: yes).boosted == true)
        #expect(try held(Self.status(reblogged: false)).refreshed(over: yes).boosted == false)
    }

    // MARK: - The press

    @Test("A boost is sent as the reader to the post's own id, and the row takes the answer")
    func aBoostLands() async throws {
        let before = try held(Self.status(reblogged: false))
        let (write, store, server, _) = try await actor(holding: before, [
            "/api/v1/statuses/9/reblog": .json(Self.wrapper(around: Self.status(reblogged: true), reblogged: true)),
        ])
        let after = try await write.boost(before, on: true)
        #expect(after.boosted == true)
        #expect(after.key == before.key, "the answer is the same row, not a new one")
        #expect(after.categories == before.categories)
        #expect(after.boostedBy == nil, "the reader's own boost does not make the row say they boosted it")
        #expect(await store.all().map(\.boosted) == [true])

        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(await server.paths == ["/api/v1/statuses/9/reblog"])
    }

    @Test("Taking it back is the same act the other way, and the row says so")
    func unboostLands() async throws {
        let before = try held(Self.status(reblogged: true))
        let (write, store, server, _) = try await actor(holding: before, [
            "/api/v1/statuses/9/unreblog": .json(Self.status(reblogged: false)),
        ])
        let after = try await write.boost(before, on: false)
        #expect(after.boosted == false)
        #expect(await store.all().map(\.boosted) == [false])
        #expect(await server.paths == ["/api/v1/statuses/9/unreblog"])
    }

    @Test("A refusal leaves the post exactly as it was, and is not a sign-out")
    func aRefusalChangesNothing() async throws {
        let before = try held(Self.status(reblogged: false))
        let (write, store, _, tokens) = try await actor(holding: before, [
            "/api/v1/statuses/9/reblog": .json("{}", status: 403),
        ])
        await #expect(throws: MastodonAuthError.http(403)) {
            _ = try await write.boost(before, on: true)
        }
        #expect(await store.all() == [before])
        #expect(try tokens.signedInHosts() == [host])
    }

    @Test("A miss on the wire leaves the post as it was")
    func aMissChangesNothing() async throws {
        let before = try held(Self.status(reblogged: false))
        let (write, store, _, _) = try await actor(holding: before, [
            "/api/v1/statuses/9/reblog": .fail,
        ])
        await #expect(throws: URLError.self) {
            _ = try await write.boost(before, on: true)
        }
        #expect(await store.all() == [before])
    }

    @Test("A post this device cannot name on its server is not sent at all")
    func anUnnameablePostAsksNothing() async throws {
        let bare = Note(
            id: "https://social.example/x", source: source, author: "Ada", handle: "@ada@social.example",
            body: "hi", postedAt: Date(timeIntervalSince1970: 0), categories: [.home]
        )
        let (write, _, server, _) = try await actor(holding: bare, [:])
        await #expect(throws: MastodonWriteError.unfindable) {
            _ = try await write.boost(bare, on: true)
        }
        #expect(await server.paths.isEmpty)
    }

    @Test("A source removed before the press asks nothing and gets nothing back")
    func aRemovedSourceAsksNothing() async throws {
        let before = try held(Self.status(reblogged: false))
        let (write, store, server, _) = try await actor(holding: before, [
            "/api/v1/statuses/9/reblog": .json(Self.status(reblogged: true)),
        ])
        await store.remove(host: host)
        await #expect(throws: MastodonWriteError.noSource) {
            _ = try await write.boost(before, on: true)
        }
        #expect(await server.paths.isEmpty)
        #expect(await store.all().isEmpty)
    }

    // MARK: - Favouriting (#107)

    @Test("Whether a post is favourited is the source's word, kept apart from a boost")
    func favouritedIsTheSourcesWord() throws {
        #expect(try held(Self.status(favourited: true)).favourited == true)
        #expect(try held(Self.status(favourited: false)).favourited == false)
        #expect(try held(Self.status()).favourited == nil)
        let both = try held(Self.status(reblogged: false, favourited: true))
        #expect(both.boosted == false && both.favourited == true)
        let wrapped = try held(Self.wrapper(around: Self.status(favourited: true), reblogged: true))
        #expect(wrapped.favourited == true)
        #expect(try held(Self.status()).refreshed(over: both).favourited == true)
    }

    @Test("A favourite and taking it back go to the post's own id, and the row takes the answer",
          arguments: [(true, "favourite"), (false, "unfavourite")])
    func aFavouriteLands(on: Bool, path: String) async throws {
        let before = try held(Self.status(favourited: !on))
        let (write, store, server, _) = try await actor(holding: before, [
            "/api/v1/statuses/9/\(path)": .json(Self.status(favourited: on)),
        ])
        let after = try await write.favourite(before, on: on)
        #expect(after.favourited == on)
        #expect(after.key == before.key)
        #expect(await store.all().map(\.favourited) == [on])
        #expect(await server.paths == ["/api/v1/statuses/9/\(path)"])
    }

    @Test("A refused favourite leaves the post exactly as it was")
    func aRefusedFavouriteChangesNothing() async throws {
        let before = try held(Self.status(favourited: false))
        let (write, store, _, _) = try await actor(holding: before, [
            "/api/v1/statuses/9/favourite": .json("{}", status: 403),
        ])
        await #expect(throws: MastodonAuthError.http(403)) {
            _ = try await write.favourite(before, on: true)
        }
        #expect(await store.all() == [before])
    }

    // MARK: - What a post offers

    @Test("Only a post on a source that writes, and that can be named there, offers the acts")
    func whatAPostOffers() {
        #expect(PostActs.on(.writes, nameable: true).offers(.boost))
        #expect(PostActs.on(.writes, nameable: true).offers(.favourite))
        #expect(!PostActs.on(.reads, nameable: true).offers(.favourite))
        #expect(PostActs.on(.writes, nameable: true).refused == nil)
        #expect(PostActs.on(.writes, nameable: false) == PostActs(offered: [], refused: .unnameable))
        #expect(PostActs.on(.reads, nameable: true) == PostActs(offered: [], refused: .notSignedIn))
        #expect(PostActs.on(.refused, nameable: true) == PostActs(offered: [], refused: .turnedAway))
        #expect(PostActs.on(.never, nameable: true) == PostActs(offered: [], refused: .protocolCannot))
        // The source's reason is given before the row's own.
        #expect(PostActs.on(.never, nameable: false).refused == .protocolCannot)
        #expect(PostActs.none.offered.isEmpty && PostActs.none.refused == nil)
    }

    // MARK: - Answering (#108)

    static func answerStatus(id: String = "20", to parent: String = "9", visibility: String = "followers") -> String {
        """
        {"id":"\(id)","uri":"https://social.example/users/me/statuses/\(id)",
         "created_at":"2024-06-03T00:00:00.000Z","content":"<p>@ada yes</p>",
         "visibility":"\(visibility)","in_reply_to_id":"\(parent)",
         "mentions":[{"acct":"ada"}],
         "account":{"username":"me","acct":"me","display_name":"Me"}}
        """
    }

    @Test("An answer names the post it answers by its own id, as the reader, and lands")
    func anAnswerLands() async throws {
        let answered = try held(Self.status())
        let (write, store, server, _) = try await actor(holding: answered, [
            "/api/v1/statuses": .json(Self.answerStatus(visibility: "private")),
        ])
        let note = try await write.post("@ada yes", visibility: .followers, answering: answered)
        let form = await server.form("/api/v1/statuses")
        #expect(form["in_reply_to_id"] == "9")
        #expect(form["visibility"] == "private")
        #expect(form["status"] == "@ada yes")
        #expect(note.reply?.inReplyToId == "9")
        #expect(await store.all().contains { $0.key == note.key })
        #expect(await server.paths == ["/api/v1/statuses"], "nothing is read again")
    }

    @Test("A post this device cannot name, or one from another source, is not answered at all")
    func anUnnameableAnswerIsNotSent() async throws {
        let bare = Note(
            id: "https://social.example/x", source: source, author: "Ada", handle: "@ada@social.example",
            body: "hi", postedAt: Date(timeIntervalSince1970: 0), categories: [.home]
        )
        let (write, _, server, _) = try await actor(holding: bare, [:])
        await #expect(throws: MastodonWriteError.unfindable) {
            _ = try await write.post("yes", visibility: .everyone, answering: bare)
        }
        let elsewhere = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Self.status().utf8))
            .asNote(source: Source(host: "other.example", kind: .mastodon), category: .home)
        await #expect(throws: MastodonWriteError.unfindable) {
            _ = try await write.post("yes", visibility: .everyone, answering: elsewhere)
        }
        #expect(await server.paths.isEmpty, "an answer is never sent as a post that answers nothing")
    }

    @Test("An answer starts no wider than the post it answers, and at the narrowest where unknown")
    func theReachStartsNoWider() {
        for audience in Audience.allCases {
            #expect(Audience.answering(audience) == audience)
            #expect(!Audience.answering(audience).isWider(than: audience))
        }
        #expect(Audience.answering(nil) == .mentioned)
        let ladder: [Audience] = [.mentioned, .followers, .unlisted, .everyone]
        for (lower, higher) in zip(ladder, ladder.dropFirst()) {
            #expect(higher.isWider(than: lower))
            #expect(!lower.isWider(than: higher))
        }
    }

    // MARK: - Taking back (#109)

    @Test("Taking back asks the source to delete the post, then lets go of the row and only it")
    func aWithdrawLands() async throws {
        let mine = try held(Self.status())
        let other = try held(Self.status(id: "10"))
        let (write, store, server, _) = try await actor(holding: mine, [
            "/api/v1/statuses/9": .json(Self.status()),
        ])
        await store.ingest([other])
        try await write.withdraw(mine)
        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/v1/statuses/9")
        #expect(await store.all().map(\.key) == [other.key])
        #expect(await store.snapshot().notes.map(\.key) == [other.key], "a save writes it gone")
    }

    @Test("A refusal or a miss leaves the post where it is")
    func aFailedWithdrawKeepsThePost() async throws {
        let mine = try held(Self.status())
        let (refused, store, _, _) = try await actor(holding: mine, [
            "/api/v1/statuses/9": .json("{}", status: 403),
        ])
        await #expect(throws: MastodonAuthError.http(403)) { try await refused.withdraw(mine) }
        #expect(await store.all() == [mine])

        let (missed, kept, _, _) = try await actor(holding: mine, ["/api/v1/statuses/9": .fail])
        await #expect(throws: URLError.self) { try await missed.withdraw(mine) }
        #expect(await kept.all() == [mine])
    }

    @Test("A post the source says is not there is gone here too")
    func aMissingPostGoes() async throws {
        let mine = try held(Self.status())
        let (write, store, _, _) = try await actor(holding: mine, [
            "/api/v1/statuses/9": .json(#"{"error":"Record not found"}"#, status: 404),
        ])
        try await write.withdraw(mine)
        #expect(await store.all().isEmpty)
    }

    @Test("Who the reader is comes from the source, spelled as a post's author is")
    func whoTheReaderIs() async throws {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let local = MastodonAuthorized(
            token: MastodonFixture.token,
            sender: FixtureSender(["/api/v1/accounts/verify_credentials": .json(#"{"acct":"ada"}"#)]),
            store: tokens
        )
        #expect(try await local.handle() == "@ada@\(host)")
        #expect(try await local.handle() == (try held(Self.status())).handle)
        let odd = MastodonAuthorized(
            token: MastodonFixture.token,
            sender: FixtureSender(["/api/v1/accounts/verify_credentials": .json("{}")]),
            store: tokens
        )
        await #expect(throws: MastodonWriteError.unreadable) { _ = try await odd.handle() }
    }

    @Test("Taking back is offered only on the reader's own post, on a source that writes")
    func takingBackIsOnlyYours() {
        #expect(PostActs.on(.writes, nameable: true, mine: true).offers(.withdraw))
        #expect(!PostActs.on(.writes, nameable: true, mine: false).offers(.withdraw))
        #expect(!PostActs.on(.writes, nameable: true).offers(.withdraw), "not known is not yours")
        #expect(PostActs.on(.writes, nameable: true, mine: false).offers(.boost))
        for writing in [SourceWriting.reads, .never, .refused] {
            #expect(!PostActs.on(writing, nameable: true, mine: true).offers(.withdraw))
        }
        #expect(!PostActs.on(.writes, nameable: false, mine: true).offers(.withdraw))
    }
}
