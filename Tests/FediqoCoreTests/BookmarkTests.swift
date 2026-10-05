import Foundation
import Security
import Testing
@testable import FediqoCore

/// A bookmark is kept at the source (#285), in the half of it Core holds: what a sign-in asks
/// for and what an earlier one still is, the ladder a server that has no bookmark scope is asked
/// on, what a post offers, the source's word carried on the note, and the act itself.
@Suite("A bookmark kept at the source")
struct BookmarkTests {
    private let host = MastodonFixture.host
    private let source = Source(host: MastodonFixture.host, kind: .mastodon)

    /// What a sign-in to read and act asked for before bookmarks were.
    private static let before = "read:statuses read:lists read:accounts read:search write:statuses write:favourites"

    static func status(bookmarked: Bool? = nil, favourited: Bool? = nil) -> String {
        let flag = (bookmarked.map { #","bookmarked":\#($0)"# } ?? "")
            + (favourited.map { #","favourited":\#($0)"# } ?? "")
        return """
        {"id":"9","uri":"https://social.example/users/ada/statuses/9",
         "created_at":"2024-06-01T00:00:00.000Z","content":"<p>hello</p>",
         "visibility":"public"\(flag),
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private func held(_ json: String) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: source, category: .home, sent: .now())
    }

    private func actor(
        holding note: Note, _ routes: [String: FixtureSender.Outcome]
    ) async throws -> (MastodonWrite, ItemStore, FixtureSender) {
        let store = ItemStore()
        await store.add(source)
        await store.ingest([note])
        let server = FixtureSender(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        let door = MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)
        return (MastodonWrite(door: door, store: store), store, server)
    }

    // MARK: - What a sign-in asks for

    @Test("Reading alone asks for exactly what it asked; reading and acting asks for bookmarks too, and for nothing wider")
    func whatIsAsked() {
        #expect(MastodonOAuth.scopes(writing: false) == "read:statuses read:lists read:accounts read:search")
        #expect(MastodonOAuth.bookmarking == "write:bookmarks")
        #expect(MastodonOAuth.scopes(writing: true) == Self.before + " write:bookmarks")
        #expect(MastodonOAuth.scopes(writing: true, bookmarks: false) == Self.before)
        #expect(MastodonOAuth.scopes(writing: false, bookmarks: true) == MastodonOAuth.reading, "never without acting")
        let asked = Set(MastodonOAuth.scopes(writing: true).split(separator: " "))
        for wider in ["write", "write:follows", "write:accounts", "write:filters", "read", "admin"] {
            #expect(!asked.contains(Substring(wider)), "\(wider) is asked for and nothing in this app uses it")
        }
    }

    @Test("A sign-in made before bookmarks were asked for still writes; it only may not bookmark")
    func anEarlierSignInStillWrites() {
        #expect(MastodonOAuth.writes(Self.before))
        #expect(MastodonGrant.of(scopes: Self.before) == .writing)
        #expect(!MastodonOAuth.bookmarks(Self.before))
        #expect(MastodonOAuth.writes(MastodonOAuth.scopes(writing: true)))
        #expect(MastodonOAuth.bookmarks(MastodonOAuth.scopes(writing: true)))
        // Scope by scope, in any order, and never a substring.
        #expect(MastodonOAuth.bookmarks("write:bookmarks read:statuses"))
        #expect(!MastodonOAuth.bookmarks("read:bookmarks write:bookmarks-ish"))
        #expect(!MastodonOAuth.bookmarks(nil) && !MastodonOAuth.bookmarks(""))
        #expect(!MastodonOAuth.bookmarks(MastodonOAuth.reading))
    }

    @Test("The ladder falls from bookmarks to the sign-in without them, after read:search's rung; reading's is as it was")
    func theLadder() {
        #expect(MastodonOAuth.ladder(writing: false) == [MastodonOAuth.reading, MastodonOAuth.readingWithoutSearch])
        let without = "read:statuses read:lists read:accounts write:statuses write:favourites"
        #expect(MastodonOAuth.ladder(writing: true) == [
            Self.before + " write:bookmarks", without + " write:bookmarks", Self.before, without,
        ])
        #expect(MastodonOAuth.ladder(writing: true).allSatisfy(MastodonOAuth.writes), "every rung still writes")
        // A sign-in is never started on a registration that leaves bookmarks out.
        #expect(MastodonOAuth.known(writing: true) == [Self.before + " write:bookmarks", without + " write:bookmarks"])
        #expect(!MastodonOAuth.known(writing: true).contains(Self.before))
    }

    @Test("What a held token may do is read off its attributes: bookmarking only where the scope is written down")
    func theAttributeSaysSo() throws {
        func row(_ scopes: String?) -> [String: Any] {
            MastodonKeychain.attributes(for: MastodonToken(
                host: host, accessToken: "t", clientID: "c", clientSecret: "s", scopes: scopes
            ))
        }
        #expect(MastodonKeychain.bookmarks(row(MastodonOAuth.scopes(writing: true))))
        #expect(!MastodonKeychain.bookmarks(row(Self.before)))
        #expect(MastodonKeychain.grant(row(Self.before)) == .writing)
        #expect(!MastodonKeychain.bookmarks(row(nil)), "a token nobody asked says nothing, and nothing is no")

        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: "old.example", accessToken: "t", clientID: "c", clientSecret: "s", scopes: Self.before))
        try tokens.save(MastodonToken(host: "new.example", accessToken: "t", clientID: "c", clientSecret: "s", scopes: MastodonOAuth.scopes(writing: true)))
        #expect(try tokens.bookmarking() == ["new.example"])
        #expect(try tokens.grants() == ["old.example": .writing, "new.example": .writing])
    }

    // MARK: - What a post offers

    @Test("The bookmark is offered where the sign-in bought it, asks where it was made before, and is absent otherwise; every other act is untouched")
    func whatAPostOffers() {
        let others: Set<PostAct> = [.boost, .favourite, .answer]
        let allowed = PostActs.on(.writes, nameable: true, bookmarks: .allowed)
        #expect(allowed.offered == others.union([.bookmark]) && allowed.asking.isEmpty)
        let unasked = PostActs.on(.writes, nameable: true, bookmarks: .unasked)
        #expect(unasked.offered == others, "an earlier sign-in lost an act it had")
        #expect(unasked.asks(.bookmark) && !unasked.offers(.bookmark) && unasked.refused == nil)
        let unavailable = PostActs.on(.writes, nameable: true, bookmarks: .unavailable)
        #expect(unavailable.offered == others && unavailable.asking.isEmpty)
        #expect(PostActs.on(.writes, nameable: true) == unavailable, "not known is not allowed")
        #expect(PostActs.on(.writes, nameable: true, mine: true, bookmarks: .allowed).offers(.withdraw))
        // Where nothing is offered, nothing is asked about either, and the reason is the source's.
        for writing in [SourceWriting.reads, .refused, .never] {
            let acts = PostActs.on(writing, nameable: true, bookmarks: .allowed)
            #expect(acts.offered.isEmpty && acts.asking.isEmpty && acts.refused != nil)
        }
        #expect(PostActs.on(.writes, nameable: false, bookmarks: .unasked) == PostActs(offered: [], refused: .unnameable))
        #expect(PostActs.on(.writes, nameable: true, gone: true, bookmarks: .unasked) == .none)
        // An act offered is never also asked about.
        #expect(PostActs(offered: [.bookmark], asking: [.bookmark]).asking.isEmpty)
    }

    // MARK: - The source's word

    @Test("What the source says of a bookmark is carried as it said it: yes, no, or nothing at all")
    func theSourcesWord() throws {
        #expect(try held(Self.status(bookmarked: true)).bookmarked == true)
        #expect(try held(Self.status(bookmarked: false)).bookmarked == false)
        #expect(try held(Self.status()).bookmarked == nil, "an unsigned read says nothing, and nothing is not no")
    }

    @Test("Read again, a bookmark taken off at the source reads as off; a read that says nothing leaves what was held")
    func readAgain() async throws {
        let store = ItemStore()
        await store.add(source)
        await store.ingest([try held(Self.status(bookmarked: true))])

        await store.refresh([try held(Self.status(bookmarked: false))], ifSourceHere: host)
        #expect(await store.all().first?.bookmarked == false)

        await store.refresh([try held(Self.status(bookmarked: true))], ifSourceHere: host)
        await store.refresh([try held(Self.status())], ifSourceHere: host)
        #expect(await store.all().first?.bookmarked == true, "a read made signed out wiped the source's word")
        // A copy that says it fills in a row that never heard, and leaves the first word otherwise.
        let fresh = ItemStore()
        await fresh.add(source)
        await fresh.ingest([try held(Self.status())])
        await fresh.ingest([try held(Self.status(bookmarked: true))])
        #expect(await fresh.all().first?.bookmarked == true)
    }

    @Test("An ordinary reload that says the reader's word takes it, on or off, for all three marks; one that says nothing leaves what was held")
    func aReloadTakesTheLaterWord() async throws {
        func status(_ said: Bool?) -> String {
            let flag = said.map { #","bookmarked":\#($0),"favourited":\#($0),"reblogged":\#($0)"# } ?? ""
            return """
            {"id":"9","uri":"https://social.example/users/ada/statuses/9",
             "created_at":"2024-06-01T00:00:00.000Z","content":"<p>hello</p>","visibility":"public"\(flag),
             "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
            """
        }
        let store = ItemStore()
        await store.add(source)
        await store.ingest([try held(status(true))], ifSourceHere: host)

        // Taken off at the source, in another app, and the timeline read again signed in.
        await store.ingest([try held(status(false))], ifSourceHere: host)
        var row = try #require(await store.all().first)
        #expect(row.bookmarked == false, "a bookmark taken off at the source still reads as on after a reload")
        #expect(row.favourited == false && row.boosted == false)

        // The same timeline read signed out says nothing, and what was held stands.
        await store.ingest([try held(status(nil))], ifSourceHere: host)
        row = try #require(await store.all().first)
        #expect(row.bookmarked == false && row.favourited == false && row.boosted == false)

        // And put back on elsewhere: on again here.
        let revision = await store.revision
        await store.ingest([try held(status(true))], ifSourceHere: host)
        row = try #require(await store.all().first)
        #expect(row.bookmarked == true && row.favourited == true && row.boosted == true)
        #expect(await store.revision == revision + 1, "written down, since the word changed")
        await store.ingest([try held(status(true))], ifSourceHere: host)
        #expect(await store.revision == revision + 1, "and the same word again changes nothing")
    }

    @Test("When a reader's sign-in ends, what the source said they did to its posts goes; the posts, and what is kept, stay")
    func readerMarksGoWithTheReader() async throws {
        let other = Source(host: "other.example", kind: .mastodon)
        func note(_ id: String, _ source: Source, said: Bool?) -> Note {
            Note(
                id: id, source: source, author: "Ada", handle: "@ada", body: "hello",
                postedAt: Date(timeIntervalSince1970: 0), categories: [.home],
                boosted: said, favourited: said, bookmarked: said, statusID: id
            )
        }
        let store = ItemStore(sources: [source, other], notes: [
            note("1", source, said: true), note("2", source, said: false), note("3", source, said: nil),
            note("4", other, said: true),
        ])
        await store.setKept(true, for: NoteKey(host: host, id: "1"))
        let revision = await store.revision

        #expect(await store.forgetReaderMarks(host: host.uppercased()))

        let rows = await store.snapshot().notes
        #expect(rows.map(\.id) == ["1", "2", "3", "4"], "no post goes")
        #expect(rows.prefix(3).allSatisfy { $0.bookmarked == nil && $0.favourited == nil && $0.boosted == nil })
        #expect(rows[0].kept, "what this device keeps is its own")
        #expect(rows[3].bookmarked == true && rows[3].favourited == true, "another source's reader is still here")
        #expect(await store.revision == revision + 1)
        #expect(await !store.forgetReaderMarks(host: host), "nothing left to let go of")
        #expect(await store.revision == revision + 1)

        #expect(await !store.forgetReaderMarks(keeping: [other.host]))
        #expect(await store.forgetReaderMarks(keeping: []))
        #expect(await store.snapshot().notes[3].bookmarked == nil)
    }

    // MARK: - What a sign-in writes down

    @Test("Only the scopes the page asked for are written down from the server's answer: a narrower one narrows, a wider one widens nothing")
    func theAnswerNeverWidens() async throws {
        let asked = "read:statuses write:statuses write:favourites"
        #expect(MastodonOAuth.granted(nil, of: asked) == asked)
        #expect(MastodonOAuth.granted("", of: asked) == asked)
        #expect(MastodonOAuth.granted("read:statuses", of: asked) == "read:statuses")
        #expect(MastodonOAuth.granted("write:favourites write:statuses read:statuses", of: asked) == asked, "its order is not the point")
        #expect(MastodonOAuth.granted(asked + " write:bookmarks write:follows admin", of: asked) == asked)
        #expect(MastodonOAuth.granted("write:bookmarks", of: asked) == "")

        // Through the sign-in itself: a server naming bookmarks to a page that asked for none.
        let wide = MastodonOAuth.reading + " write:statuses write:favourites write:bookmarks"
        let server = MastodonFixture.server(issued: #"{"access_token":"tok-123","scope":"\#(wide)"}"#)
        let token = try await MastodonOAuth(host: host, sender: server)
            .signIn(as: MastodonFixture.app, through: await FixtureBrowser.approving())
        #expect(token.scopes == MastodonOAuth.reading)
        #expect(token.asked == MastodonOAuth.reading)
        #expect(token.grant == .reading && !MastodonOAuth.bookmarks(token.scopes))
    }

    @Test("An answer that does not carry this attempt's state is not this attempt's answer, a refusal included")
    func aRefusalNeedsItsState() {
        for answer in ["error=invalid_scope", "error=access_denied", "error=invalid_scope&state=other", "error=access_denied&state="] {
            #expect(throws: MastodonSignInError.stateMismatch, "\(answer)") {
                try MastodonOAuth.code(from: URL(string: "fediqo://oauth?\(answer)")!, state: "st")
            }
        }
        #expect(throws: MastodonSignInError.invalidScope) {
            try MastodonOAuth.code(from: URL(string: "fediqo://oauth?error=invalid_scope&state=st")!, state: "st")
        }
    }

    @Test("A registration the server refuses for its scopes is a scope refusal; any other failure is what it was")
    func aRegistrationRefusedForItsScopes() async {
        func register(_ outcome: FixtureSender.Outcome) async throws {
            _ = try await MastodonOAuth(host: host, sender: FixtureSender(["/api/v1/apps": outcome]))
                .register(scopes: MastodonOAuth.scopes(writing: true))
        }
        let refusal = #"{"error":"Validation failed: Scopes doesn't match configured on the server."}"#
        await #expect(throws: MastodonSignInError.invalidScope) { try await register(.json(refusal, status: 422)) }
        await #expect(throws: MastodonSignInError.invalidScope) { try await register(.json(#"{"error":"invalid_scope"}"#, status: 400)) }
        // Not a scope refusal: a server failing, a refusal about something else, no word at all.
        await #expect(throws: MastodonSignInError.http(500)) { try await register(.json(refusal, status: 500)) }
        await #expect(throws: MastodonSignInError.http(422)) { try await register(.json(#"{"error":"Validation failed: Redirect URI is invalid"}"#, status: 422)) }
        await #expect(throws: MastodonSignInError.http(422)) { try await register(.json("{}", status: 422)) }
        await #expect(throws: MastodonSignInError.http(429)) { try await register(.json("Too many requests", status: 429)) }
        await #expect(throws: MastodonSignInError.unreachable) { try await register(.fail) }
    }

    @Test("What a sign-in asked for is written down beside it, readable without the token, and tells asked-and-refused from never asked")
    func askedIsWrittenDown() throws {
        let acting = MastodonOAuth.scopes(writing: true)
        func token(scopes: String?, asked: String?) -> MastodonToken {
            MastodonToken(host: host, accessToken: "t", clientID: "c", clientSecret: "s", scopes: scopes, asked: asked)
        }
        let refused = token(scopes: Self.before, asked: acting)
        let earlier = token(scopes: Self.before, asked: nil)
        let allowed = token(scopes: acting, asked: acting)
        #expect(refused.bookmarksRefused && !earlier.bookmarksRefused && !allowed.bookmarksRefused)

        // In the item's attributes — scope names, never the token — and in its value.
        let row = MastodonKeychain.attributes(for: refused)
        #expect(row[kSecAttrComment as String] as? String == acting)
        #expect(MastodonKeychain.bookmarksRefused(row))
        #expect(!MastodonKeychain.bookmarksRefused(MastodonKeychain.attributes(for: earlier)))
        #expect(MastodonKeychain.attributes(for: earlier)[kSecAttrComment as String] == nil)
        #expect(!MastodonKeychain.bookmarksRefused(MastodonKeychain.attributes(for: allowed)))
        #expect(MastodonKeychain.Wire.decode(MastodonKeychain.Wire.encode(refused), host: host) == refused)
        #expect(MastodonKeychain.Wire.decode(MastodonKeychain.Wire.encode(earlier), host: host) == earlier)
        #expect(String(describing: refused) == "MastodonToken(host: \(host))", "and it still prints as its host alone")

        let tokens = MemoryMastodonTokens()
        try tokens.save(refused)
        #expect(try tokens.bookmarksRefused() == [host] && tokens.bookmarking().isEmpty)
        try tokens.save(allowed)
        #expect(try tokens.bookmarksRefused().isEmpty && tokens.bookmarking() == [host])
    }

    // MARK: - The act

    @Test("Bookmarking asks the source by the post's own id and lands as its answer; taking it off does the same, and nothing else moves")
    func aBookmarkLands() async throws {
        let before = try held(Self.status(bookmarked: false, favourited: true))
        let (write, store, server) = try await actor(holding: before, [
            "/api/v1/statuses/9/bookmark": .json(Self.status(bookmarked: true, favourited: true)),
            "/api/v1/statuses/9/unbookmark": .json(Self.status(bookmarked: false, favourited: true)),
        ])

        let on = try await write.bookmark(before, on: true)
        #expect(on.bookmarked == true && on.favourited == true)
        #expect(await store.all().first?.bookmarked == true)

        let off = try await write.bookmark(on, on: false)
        #expect(off.bookmarked == false)
        #expect(await store.all().first?.bookmarked == false)
        #expect(await server.paths == ["/api/v1/statuses/9/bookmark", "/api/v1/statuses/9/unbookmark"])
    }

    @Test("A bookmark the source turns away leaves the post exactly as it was")
    func aRefusedBookmarkChangesNothing() async throws {
        let before = try held(Self.status(bookmarked: false))
        let (write, store, _) = try await actor(holding: before, [
            "/api/v1/statuses/9/bookmark": .json("{}", status: 403),
        ])
        await #expect(throws: MastodonAuthError.http(403)) {
            _ = try await write.bookmark(before, on: true)
        }
        #expect(await store.all() == [before])
    }

    @Test("Keeping and bookmarking are two marks: neither moves the other")
    func keptIsNotBookmarked() async throws {
        let store = ItemStore()
        await store.add(source)
        let note = try held(Self.status(bookmarked: true))
        await store.ingest([note])
        await store.setKept(true, for: note.key)
        await store.refresh([try held(Self.status(bookmarked: false))], ifSourceHere: host)
        #expect(await store.note(note.key)?.kept == true)
        #expect(await store.note(note.key)?.bookmarked == false)
    }
}
