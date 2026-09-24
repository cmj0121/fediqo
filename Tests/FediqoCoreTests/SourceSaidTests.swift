import Foundation
import Testing
@testable import FediqoCore

/// #188: what a source says about itself is kept with the source, marked as of when it was said,
/// and the next word replaces it whole.
@Suite("What a source said about itself")
struct SourceSaidTests {
    private static let host = "first.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let moment = Date(timeIntervalSince1970: 1_750_000_000)
    private static let later = Date(timeIntervalSince1970: 1_760_000_000)

    private static func word(limit: Int, title: String = "The first server") -> SourceProfile {
        SourceProfile(host: host, kind: .mastodon, title: title, statusLimit: limit)
    }

    @Test("A word is kept with its source, stamped as of when, and the next replaces it whole")
    func keptAndReplaced() async {
        let store = ItemStore()
        await store.add(Self.source)
        #expect(await store.said(host: Self.host) == nil, "nothing heard yet")

        await store.said(Self.word(limit: 1500), at: Self.moment)
        let kept = await store.said(host: Self.host)
        #expect(kept?.statusLimit == 1500)
        #expect(kept?.asOf == Self.moment, "marked as of when it was said")

        await store.said(
            SourceProfile(host: Self.host.uppercased(), kind: .mastodon, title: "Renamed", statusLimit: 2000),
            at: Self.later
        )
        let replaced = await store.said(host: Self.host)
        #expect(replaced?.statusLimit == 2000)
        #expect(replaced?.title == "Renamed")
        #expect(replaced?.asOf == Self.later)
        #expect(replaced?.host == Self.host, "folded once, like every host, on the way in")
        #expect(await store.said(host: Self.host.uppercased())?.asOf == Self.later, "and on the way out")
        #expect(await store.snapshot().said.map(\.host) == [Self.host])
    }

    @Test("The same word said again moves only the moment, and the moment alone is not written")
    func sameWordAgain() async {
        let store = ItemStore()
        await store.add(Self.source)
        await store.said(Self.word(limit: 1500), at: Self.moment)
        let revision = await store.revision

        await store.said(Self.word(limit: 1500), at: Self.later)

        #expect(await store.said(host: Self.host)?.asOf == Self.later, "the page says the newer moment")
        #expect(await store.revision == revision, "nothing a reader could tell apart, so nothing to write")

        await store.said(Self.word(limit: 1501), at: Self.later)
        #expect(await store.revision == revision + 1, "a word that changed is written")
    }

    @Test("A word of a kind this app cannot name is no word: refused, and not read back")
    func unknownIsNoWord() async {
        let store = ItemStore()
        await store.add(Self.source)
        let revision = await store.revision
        await store.said(SourceProfile(host: Self.host, kind: .unknown, title: "?"), at: Self.moment)
        #expect(await store.said(host: Self.host) == nil)
        #expect(await store.revision == revision)

        let unknown = SourceProfile(host: Self.host, kind: .unknown, title: "?").said(at: Self.moment)
        let again = ItemStore(sources: [Self.source], notes: [], said: [unknown])
        #expect(await again.said(host: Self.host) == nil)
    }

    @Test("A word about a server nobody joined goes nowhere")
    func strangerIsSilent() async {
        let store = ItemStore()
        let before = await store.revision
        await store.said(Self.word(limit: 1500), at: Self.moment)
        #expect(await store.said(host: Self.host) == nil)
        #expect(await store.revision == before, "nothing changed, so nothing to save")
    }

    @Test("Keeping a word is a change a save writes and no timeline shows")
    func movesTheRevision() async {
        let store = ItemStore()
        await store.add(Self.source)
        let revision = await store.revision
        let drawn = await store.drawn
        await store.said(Self.word(limit: 1500), at: Self.moment)
        #expect(await store.revision == revision + 1)
        #expect(await store.drawn == drawn)
        let snapshot = await store.snapshot()
        #expect(snapshot.said.map(\.host) == [Self.host])
        #expect(snapshot.said.first?.asOf == Self.moment)
    }

    @Test("A Remove takes the word with the source; a Clear lets it go and the source stays")
    func removedAndCleared() async {
        let store = ItemStore()
        await store.add(Self.source)
        await store.said(Self.word(limit: 1500), at: Self.moment)

        await store.forgetSaid(host: Self.host)
        #expect(await store.said(host: Self.host) == nil)
        #expect(await store.sources().map(\.host) == [Self.host], "Clear does not undo a join")
        let revision = await store.revision
        await store.forgetSaid(host: Self.host)
        #expect(await store.revision == revision, "letting go of nothing changes nothing")

        await store.said(Self.word(limit: 1500), at: Self.moment)
        await store.remove(host: Self.host)
        #expect(await store.said(host: Self.host) == nil)
        await store.add(Self.source)
        #expect(await store.said(host: Self.host) == nil, "a source joined again starts unheard")
    }

    @Test("A relaunch reads back only a word of a source still here, and only one said at a moment")
    func relaunchReadsBack() async {
        let stranger = SourceProfile(host: "gone.example", kind: .mastodon, asOf: Self.moment)
        let unstamped = Self.word(limit: 1500)
        let store = ItemStore(sources: [Self.source], notes: [], said: [stranger, unstamped])
        #expect(await store.said(host: "gone.example") == nil, "its source is not here")
        #expect(await store.said(host: Self.host) == nil, "a word with no moment is not one said then")

        let kept = Self.word(limit: 1500).said(at: Self.moment)
        let again = ItemStore(sources: [Self.source], notes: [], said: [kept])
        #expect(await again.said(host: Self.host) == kept)
        #expect(await again.snapshot().said == [kept], "and a save writes it back as it was")
    }

    @Test("Subscribing to a source keeps what its look heard it say, as of now")
    func joinKeepsTheLook() async throws {
        let store = ItemStore()
        let joiner = SourceJoin(http: JoinTests.joinHTTP(), store: store, catalogues: EmojiCatalogueStore())
        let heard = Self.word(limit: 1500)
        let before = Date()
        let step = try await joiner.begin(SourcePreview(host: Self.host, kind: .mastodon, profile: .stated(heard)))
        guard case .joined = step else {
            Issue.record("a Mastodon joins at once")
            return
        }
        let kept = try #require(await store.said(host: Self.host))
        #expect(kept.statusLimit == 1500)
        let asOf = try #require(kept.asOf)
        #expect(asOf >= before && asOf <= Date())
    }

    @Test("A look that heard nothing keeps nothing")
    func silentLookKeepsNothing() async throws {
        let store = ItemStore()
        let joiner = SourceJoin(http: JoinTests.joinHTTP(), store: store, catalogues: EmojiCatalogueStore())
        _ = try await joiner.begin(SourcePreview(
            host: Self.host, kind: .mastodon, profile: .unread(host: Self.host, kind: .mastodon, .unreachable)
        ))
        #expect(await store.sources().map(\.host) == [Self.host])
        #expect(await store.said(host: Self.host) == nil)
    }

    @Test("One instance document says what the server is and what it is like, under that name")
    func introductionReadsOnce() async throws {
        let http = FixtureHTTP([
            "https://first.example/api/v2/instance": .text("""
                {"domain":"first.example","title":"Akkoma here","version":"3.10.4 (compatible; Akkoma 3.10.4)",
                 "configuration":{"statuses":{"max_characters":5000}}}
                """),
        ])
        let (kind, profile) = try await MastodonClient(http: http, host: Self.host).introduction()
        #expect(kind == .akkoma)
        #expect(profile?.kind == .akkoma, "written down as the word of what it said it is")
        #expect(profile?.title == "Akkoma here")
        #expect(profile?.statusLimit == 5000)
        #expect(profile?.asOf == nil, "the store stamps it, not the wire")
        #expect(await http.requested.count == 1)
    }
}
