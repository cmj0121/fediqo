import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #86: a server's flavour is what that server says, not what was written down when it was joined.
@MainActor
@Suite("What a server says it is")
struct FlavourTests {
    private static let host = "one.example"
    private static let flavour = MastodonInstance.address(host)
    private static let publicTimeline = "https://one.example/api/v1/timelines/public?limit=40"
    private static let trends = "https://one.example/api/v1/trends/statuses?limit=20"

    init() {
        L10n.language = .english
    }

    private static func says(_ version: String) -> FixtureHTTP.Outcome {
        MastodonInstance.says(version, host: host)
    }

    private static let oneNote = FixtureHTTP.Outcome.text("""
        [{"id":"1","uri":"https://one.example/users/ada/statuses/1",
          "created_at":"2024-01-01T00:00:00.000Z","content":"<p>hello</p>",
          "account":{"username":"ada","acct":"ada","display_name":"Ada"}}]
        """)

    /// A session holding one source written down as a Mastodon, whatever its server now says.
    private func shell(_ routes: [String: FixtureHTTP.Outcome]) async -> (ShellSession, FixtureHTTP) {
        let http = FixtureHTTP(routes)
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        let session = ShellSession(http: http, store: store, posts: ForumPosts(http: http))
        await session.reloadFromStore()
        return (session, http)
    }

    private static var stillMastodon: [String: FixtureHTTP.Outcome] {
        [flavour: says("4.3.1"), publicTimeline: oneNote, trends: oneNote]
    }

    @Test("A Mastodon is asked what it is before it is read, and reading goes on as before")
    func asksAndReads() async {
        let (session, http) = await shell(Self.stillMastodon)

        await session.reload.timeline(.all, in: session)

        #expect(session.flavours.flavour(of: Self.host) == .said(.mastodon))
        #expect(await http.requested.map(\.absoluteString).contains(Self.flavour))
        #expect(session.notes.count == 1, "it still speaks Mastodon, so it is still read")
        #expect(session.reload.unspoken == nil)
        #expect(session.reload.line == nil)
    }

    @Test("The same server is asked once a run, however many timelines draw from it")
    func askedOnce() async {
        let (session, http) = await shell(Self.stillMastodon)

        await session.reload.timeline(.all, in: session)
        await session.reload.timeline(.trends, in: session)

        #expect(await http.requested.filter { $0.absoluteString == Self.flavour }.count == 1)
    }

    @Test("A server that now answers as something this app does not read is not spoken to as Mastodon")
    func migratedAway() async {
        let (session, http) = await shell([
            Self.flavour: Self.says("2.7.2 (compatible; Misskey 13.0.0)"),
            Self.publicTimeline: Self.oneNote,
            Self.trends: Self.oneNote,
        ])

        await session.reload.timeline(.all, in: session)

        #expect(session.flavours.flavour(of: Self.host) == .said(.misskey))
        #expect(session.sources.map(\.kind) == [.misskey],
                "the session speaks to it as what it says it is, everywhere at once")
        #expect(session.notes.isEmpty, "nothing was read from a server this app does not speak")
        #expect(await !http.requested.map(\.absoluteString).contains(Self.publicTimeline))
        #expect(session.reload.unspoken?.host == Self.host)
        #expect(session.reload.failed.isEmpty, "it answered; it did not fail to answer")
        #expect(
            session.reload.line
                == "one.example now answers as Misskey, which Fediqo does not read. "
                + "What it brought here is still here."
        )
    }

    @Test("What was stored is still stored: the source stays, its rows stay, its kind is untouched")
    func storedStaysStored() async throws {
        let (session, _) = await shell([
            Self.flavour: Self.says("Pleroma 2.5.0"),
            Self.publicTimeline: Self.oneNote,
            Self.trends: Self.oneNote,
        ])
        await session.store.ingest([Note(
            id: "https://one.example/users/ada/statuses/9", source: Source(host: Self.host, kind: .mastodon),
            author: "Ada", handle: "@ada@one.example", body: "kept", postedAt: Date(timeIntervalSince1970: 0),
            categories: [.public]
        )])
        await session.reloadFromStore()

        await session.reload.timeline(.all, in: session)

        // **The two halves of the issue, side by side.** This run speaks to it as what it says
        // it is; the index still holds what this device stored, which is what a relaunch reads.
        #expect(session.sources.map(\.kind) == [.pleroma], "this run speaks the server's answer")
        #expect(await session.store.sources().map(\.kind) == [.mastodon],
                "nothing wrote the flavour over what was joined")
        #expect(session.notes.map(\.body) == ["kept"], "what it brought here is still here")
        #expect(session.sources.map(\.host) == ["one.example"], "still a source, and still the same one")
    }

    @Test("A server that would not say leaves what was written down at join standing")
    func wouldNotSay() async {
        let (session, _) = await shell([
            Self.flavour: .fail, Self.publicTimeline: Self.oneNote, Self.trends: Self.oneNote,
        ])

        await session.reload.timeline(.all, in: session)

        #expect(session.flavours.flavour(of: Self.host) == .unsaid)
        #expect(session.flavours.speaking(Self.host, storedAs: .mastodon) == .mastodon)
        #expect(session.notes.count == 1, "an outage is not a migration")
        #expect(session.reload.unspoken == nil)
    }

    @Test("Nothing asked yet speaks what was stored, and an answer replaces only that")
    func fallsBackToStored() {
        let flavours = ShellFlavours()
        #expect(flavours.flavour(of: Self.host) == nil, "nobody has asked")
        #expect(flavours.speaking(Self.host, storedAs: .mastodon) == .mastodon)
        #expect(flavours.speaking("OTHER.example", storedAs: .discuz) == .discuz, "folded once, like every host")
        // A source nothing has been said about is the same value, not a copy of it.
        let source = Source(host: Self.host, kind: .mastodon, boards: [], lists: [])
        #expect(flavours.spoken(source) == source)
    }

    @Test("Clear lets go of what a server said, and the next read asks it again")
    func clearForgets() async {
        let (session, http) = await shell(Self.stillMastodon)
        await session.reload.timeline(.all, in: session)
        #expect(session.flavours.flavour(of: Self.host) == .said(.mastodon))

        session.flavours.forget(host: Self.host.uppercased())
        #expect(session.flavours.flavour(of: Self.host) == nil)

        await session.reload.timeline(.all, in: session)
        #expect(await http.requested.filter { $0.absoluteString == Self.flavour }.count == 2)
    }

    @Test("A run that found a server speaking something else does not carry it into the next run")
    func unspokenIsPerRun() async {
        let (session, _) = await shell([
            Self.flavour: Self.says("Akkoma 3.10.4"),
            Self.publicTimeline: Self.oneNote,
            Self.trends: Self.oneNote,
        ])
        await session.reload.timeline(.all, in: session)
        #expect(session.reload.unspoken?.kind == .akkoma)

        session.flavours.forget(host: Self.host)
        await session.reload.timeline(.all, in: session)
        #expect(session.reload.unspoken?.kind == .akkoma, "said once a run, not once more each time")
    }
}
