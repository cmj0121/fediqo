import Foundation
import Testing
@testable import FediqoCore

/// N3d: a server that speaks Mastodon's way of asking and is not Mastodon, put to this app's own
/// code as it stands — its detector, its join, and the Mastodon reader and writer behind them. A
/// GoToSocial 0.22.2, brought up only by `FEDIQO_SERVERS_GOTOSOCIAL=1 make servers`.
///
/// **It makes no such server a supported source** (#283 says so), and nothing here says what the
/// app ought to do. Each check holds what the code does today, so that the day one of them
/// changes it is seen; the table of what the server answers beside Mastodon's is
/// `servers/gotosocial/FINDINGS.md`.
///
/// **Passed over unless asked for**, and failing — not passing — where it was asked for and the
/// server is not up: the same two questions `LocalServers` asks of the three.
@Suite("What this app makes of a GoToSocial", .enabled(if: LocalServers.gotosocialRequested), .serialized)
struct GoToSocialSaysTests {
    private static let host = LocalServers.gotosocial

    private func joined(_ http: some HTTPClient & HTTPSender) async throws -> ItemStore {
        let store = ItemStore()
        try await SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore()).join(host: Self.host)
        return store
    }

    /// Twice over: its front page carries no `generator` tag and links `joinmastodon.org` in its
    /// own words to a visitor, which is the last marker `HTMLKind.classify` takes for a Mastodon;
    /// and its document's `version` is a bare number, so `Probe` would say Mastodon too.
    @Test("Detect names it Mastodon, so a join adds it as a Mastodon, with nothing to read: its public timeline is kept from strangers and nothing is rising")
    func takenForAMastodon() async throws {
        try await LocalServers.requireGoToSocial()
        let http = try LocalHTTP.client()
        #expect(try await Detector(http: http).detect(Self.host) == .mastodon)
        #expect(!SourceJoin.reads(.gotosocial), "the kind it is would have been refused")

        let client = MastodonClient(http: http, host: Self.host)
        let source = Source(host: Self.host, kind: .mastodon)
        await #expect(throws: MastodonRequestError.http(401)) { try await client.publicTimeline(source: source) }
        #expect(try await client.trending(source: source).isEmpty)

        let store = try await joined(http)
        #expect(await store.sources().map(\.host) == [Self.host])
        #expect(await store.sources().map(\.kind) == [.mastodon])
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

        let store = try await joined(http)
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
}
