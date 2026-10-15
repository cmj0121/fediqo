import Foundation
import Testing
@testable import FediqoCore

/// N3d: a server that speaks Mastodon's way of asking and is not Mastodon, put to this app's own
/// code as it stands — its detector, its join, and the Mastodon reader and writer behind them. A
/// GoToSocial 0.22.2, brought up only by `FEDIQO_SERVERS_GOTOSOCIAL=1 make servers`.
///
/// **It makes no such server a supported source** (#283 says so), and nothing here says what the
/// app ought to do beyond the first check, which holds that the server is named for what it is
/// and not joined. Each check holds what the code does today, so that the day one of them
/// changes it is seen; the table of what the server answers beside Mastodon's is
/// `servers/gotosocial/FINDINGS.md`.
///
/// **Passed over unless asked for**, and failing — not passing — where it was asked for and the
/// server is not up: the same two questions `LocalServers` asks of the three.
@Suite("What this app makes of a GoToSocial", .enabled(if: LocalServers.gotosocialRequested), .serialized)
struct GoToSocialSaysTests {
    private static let host = LocalServers.gotosocial

    /// Neither of the two things detection reads first names it: its front page carries no
    /// `generator` tag and links `joinmastodon.org` in its own words to a visitor, which is the
    /// last marker `HTMLKind.classify` takes for a Mastodon; and its document's `version` is a
    /// bare number, so `Probe` says Mastodon too. Its node information does name it, and that is
    /// what `Detector` asks a host it would have called a Mastodon. Until it did, this check held
    /// the opposite: named Mastodon, and added with nothing in it.
    @Test("Detect names it GoToSocial by what it says of itself, so a join refuses it by that name and adds nothing: its public timeline is kept from strangers and nothing is rising")
    func namedForWhatItIs() async throws {
        try await LocalServers.requireGoToSocial()
        let http = try LocalHTTP.client()
        let front = try #require(Host.httpsURL(host: Self.host, path: "/"))
        let instance = try #require(Host.httpsURL(host: Self.host, path: "/api/v2/instance"))
        let page = String(decoding: try await http.data(from: front).0, as: UTF8.self)
        #expect(HTMLKind.classify(page) == .named(.mastodon))
        #expect(Probe.kind(from: try await http.data(from: instance).0) == .mastodon)
        #expect(try await NodeInfo(http: http).software(of: Self.host) == "gotosocial")
        #expect(try await Detector(http: http).detect(Self.host) == .gotosocial)
        #expect(!SourceJoin.reads(.gotosocial))

        // What a join would still meet there, were it let through: one read refused, one empty.
        let client = MastodonClient(http: http, host: Self.host)
        let source = Source(host: Self.host, kind: .mastodon)
        await #expect(throws: MastodonRequestError.http(401)) { try await client.publicTimeline(source: source) }
        #expect(try await client.trending(source: source).isEmpty)

        let store = ItemStore()
        await #expect(throws: JoinError.unsupportedKind(.gotosocial)) {
            try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore()).join(host: Self.host)
        }
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test("Its document is read as a Mastodon's is: the kind, how long a post may be, how many hashtags an account may feature, and nothing of the other things asked about")
    func theDocument() async throws {
        try await LocalServers.requireGoToSocial()
        let said = try await MastodonClient(http: try LocalHTTP.client(), host: Self.host).said()
        #expect(said.kind == .mastodon)
        #expect(said.profile?.statusLimit == 5000)
        #expect(said.has.featuredTagLimit == 10 && said.has.has(.featuredTags) == .present)
        for thing in MastodonHostThing.allCases where thing != .featuredTags { #expect(said.has.has(thing) == .unsaid, "\(thing)") }
    }

    @Test("This app registers itself there for reading and acting, and a post and a boost go through the Mastodon writer and come back as the server answered")
    func registersAndWrites() async throws {
        try await LocalServers.requireGoToSocial()
        let http = try LocalHTTP.client()
        let app = try await MastodonOAuth(host: Self.host, sender: http)
            .register(scopes: MastodonOAuth.scopes(writing: true))
        #expect(!app.clientID.isEmpty && app.host == Self.host)

        // A join refuses this host, so the source is put in the store as the writer needs it.
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(
            host: Self.host, accessToken: try LocalServers.gotosocialWriterToken(), clientID: "x", clientSecret: "x"
        )
        try tokens.save(token)
        let write = MastodonWrite(door: MastodonAuthorized(token: token, sender: http, store: tokens), store: store)
        let marker = "fediqo-n3d-\(UUID().uuidString.prefix(8))"
        let note = try await write.post(marker, visibility: .everyone)
        #expect(note.body.contains(marker))
        #expect(await store.all().contains { $0.id == note.id })
        let boosted = try await write.boost(note, on: true)
        #expect(boosted.boosted == true)
        let back = try await write.boost(boosted, on: false)
        #expect(back.boosted == false)
    }

    @Test("What is taken from somebody followed is narrowed there as on a Mastodon: a follow said again with one word changes that thing and leaves the other, the answer is the whole standing, a follow with no word resets neither — and somebody who had to agree, once followed, is not asked again by it")
    func narrowsAFollow() async throws {
        try await LocalServers.requireGoToSocial()
        let seeded = try JSONSerialization.jsonObject(
            with: Data(contentsOf: LocalServers.repoRoot.appending(path: "servers/.run/gotosocial-tokens.json"))
        ) as? [String: Any]
        let other = try #require(seeded?["other_id"] as? String, "servers/.run/gotosocial-tokens.json names nobody to follow")
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(
            host: Self.host, accessToken: try LocalServers.gotosocialWriterToken(), clientID: "x", clientSecret: "x"
        )
        try tokens.save(token)
        let stands = MastodonStanding(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))

        // As the seed left it: followed, and agreed to — an account here is made locked.
        let before = try #require(try await stands.standing(to: other))
        #expect(before.following && !before.requested)
        let boosts = try #require(before.showsBoosts, "it says whether their boosts are shown")
        let notify = try #require(before.notifies, "and whether the reader is told of each post")
        var said = before
        do {
            said.showsBoosts = !boosts
            #expect(try await stands.narrow(other, boosts: !boosts) == said)
            said.notifies = !notify
            #expect(try await stands.narrow(other, notify: !notify) == said, "the other is left as it stood")
            #expect(try await stands.standing(to: other) == said)
            #expect(try await stands.follow(other) == said, "a follow with no word resets neither, and asks nobody again")
        } catch {
            _ = try? await stands.narrow(other, boosts: boosts, notify: notify)
            throw error
        }
        #expect(try await stands.narrow(other, boosts: boosts, notify: notify) == before, "put back as the seed left it")
    }

    @Test("Requests to follow are listed and answered there as on a Mastodon — accepted, refused, and a request that is not there refused as not found — but nobody is removed from following: that address is not there at all")
    func answersRequests() async throws {
        try await LocalServers.requireGoToSocial()
        let seeded = try JSONSerialization.jsonObject(
            with: Data(contentsOf: LocalServers.repoRoot.appending(path: "servers/.run/gotosocial-tokens.json"))
        ) as? [String: Any]
        let other = try #require(seeded?["other_id"] as? String), me = try #require(seeded?["writer_id"] as? String)
        let asker = try #require(seeded?["other"] as? String)
        let http = try LocalHTTP.client()
        func asAsker(_ act: String) async throws {
            var request = URLRequest(url: try #require(URL(string: "https://\(Self.host)/api/v1/accounts/\(me)/\(act)")))
            request.httpMethod = "POST"
            request.setValue("Bearer \(asker)", forHTTPHeaderField: "Authorization")
            _ = try await http.send(request)
        }
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: Self.host, accessToken: try LocalServers.gotosocialWriterToken(), clientID: "x", clientSecret: "x")
        try tokens.save(token)
        let door = MastodonAuthorized(token: token, sender: http, store: tokens)
        let stands = MastodonStanding(door: door), people = MastodonPeople(door: door)
        func listed() async throws -> [String] {
            try await people.stretch(.requests, source: Source(host: Self.host, kind: .mastodon), limit: 80).people.map(\.accountID)
        }
        // As the seed left it they follow the writer: they leave, and ask again.
        let thrown: (any Error)?
        do {
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await stands.removeFollower(other) }
            #expect(try await stands.standing(to: other)?.followedBy == true, "nobody was removed: there is no such address")
            try await asAsker("unfollow")
            #expect(try await listed().contains(other) == false)
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await stands.answer(other, accept: true) }
            try await asAsker("follow")
            #expect(try await listed() == [other])
            #expect(try await stands.answer(other, accept: false).followedBy == false)
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await stands.answer(other, accept: false) }
            try await asAsker("follow")
            #expect(try await stands.answer(other, accept: true).followedBy == true)
            await #expect(throws: MastodonAuthError.http(404)) { _ = try await stands.answer(other, accept: true) }
            thrown = nil
        } catch {
            thrown = error
        }
        // Put back as the seed left it, whatever became of the asking.
        if (try? await stands.standing(to: other))??.followedBy != true {
            try? await asAsker("follow")
            _ = try? await stands.answer(other, accept: true)
        }
        if let thrown { throw thrown }
    }

    /// Asked by hand first, 2026-10-15, as the seed's second person (FINDINGS, "Asked later — a
    /// change to one's own account"): no length is stated or held to, a form it will not take is
    /// a 400 with one sentence — never a 422 naming what — and `hide_collections` is sent only
    /// while it is `true`.
    @Test("One's own account is changed there through the same code: what is sent comes back and reads back the same, one empty field clears them all, a form it will not take is a 400 and not a refusal naming what, and the lists are said hidden only while they are")
    func changesOwnAccount() async throws {
        try await LocalServers.requireGoToSocial()
        let seeded = try JSONSerialization.jsonObject(
            with: Data(contentsOf: LocalServers.repoRoot.appending(path: "servers/.run/gotosocial-tokens.json"))
        ) as? [String: Any]
        let tokens = MemoryMastodonTokens()
        let token = MastodonToken(host: Self.host, accessToken: try #require(seeded?["other"] as? String), clientID: "x", clientSecret: "x")
        try tokens.save(token)
        let own = MastodonOwnAccount(door: MastodonAuthorized(token: token, sender: try LocalHTTP.client(), store: tokens))
        // As the seed leaves them: locked as made, and nothing said of the lists.
        let start = OwnAccount(name: "other", words: "", fields: [], followWithoutAsking: false, findable: false, listsShown: nil)

        let thrown: (any Error)?
        do {
            #expect(try await own.read() == start)
            #expect(try await own.limits() == OwnLimits(fields: 6), "only how many fields")

            var changed = start
            changed.name = String(repeating: "o", count: 600)
            changed.words = "Words of my own."
            changed.fields = [.init(name: "site", value: "own.example")]
            changed.followWithoutAsking = true
            changed.findable = true
            changed.listsShown = false
            #expect(try await own.change(from: start, to: changed)?.account == changed, "a name of 600 is taken")
            #expect(try await own.read() == changed)

            var cleared = changed
            cleared.fields = []
            cleared.listsShown = true
            let answer = try #require(try await own.change(from: changed, to: cleared))
            #expect(answer.account.fields.isEmpty)
            #expect(answer.account.listsShown == nil, "shown is not said: `hide_collections` is gone, not false")

            var seven = cleared
            seven.fields = (0 ..< 7).map { OwnAccount.Field(name: "n\($0)", value: "v\($0)") }
            await #expect(throws: MastodonAuthError.http(400)) { _ = try await own.change(from: cleared, to: seven) }
            #expect(try await own.read().fields.isEmpty, "nothing of it was kept")
            thrown = nil
        } catch {
            thrown = error
        }
        // Put back as the seed left it, whatever became of the asking.
        if let now = try? await own.read(), now != start {
            var back = start
            back.listsShown = now.listsShown == false ? true : nil
            _ = try? await own.change(from: now, to: back)
        }
        if let thrown { throw thrown }
        #expect(try await own.read() == start, "left changed on the server")
    }
}
