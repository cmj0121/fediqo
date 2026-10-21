import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #332 (Decision 1) through the session: a changed post that lands owing its history has it
/// asked of its own source, in that source's line, and the row holds the source's wordings after
/// — once, and not again on the next landing.
@MainActor
@Suite("A changed post's history is filled in", .watched)
struct HistoryLoadTests {
    private let host = "social.example"
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private var source: Source { Source(host: host, kind: .mastodon) }

    private static let history = """
    [{"content":"<p>one</p>","spoiler_text":"","sensitive":false,"created_at":"2023-11-14T22:13:20.000Z"},
     {"content":"<p>two</p>","spoiler_text":"","sensitive":false,"created_at":"2023-11-14T23:00:00.000Z"},
     {"content":"<p>three</p>","spoiler_text":"","sensitive":false,"created_at":"2023-11-15T00:00:00.000Z"}]
    """

    private func post(_ id: String, edited: Bool) -> Note {
        Note(
            id: "https://social.example/users/ada/statuses/\(id)", source: source, author: "Ada",
            handle: "@ada@social.example", body: edited ? "three" : "one", postedAt: Self.origin, categories: [.public],
            statusID: id, editedAt: edited ? ISO8601DateFormatter().date(from: "2023-11-15T00:00:00Z") : nil
        )
    }

    private func shell(_ http: FixtureHTTP) async -> ShellSession {
        let store = ItemStore()
        await store.add(source)
        let work = SourceWork()
        work.govern(sources: [host])
        let session = ShellSession(http: http, store: store, mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:])))
        session.deadlinesUnturned()
        session.work = work
        var limits = LoadLimits()
        limits.interval = 0
        limits.backoff = 0
        session.loads = LoadPacer(limits: limits, clock: StillClock())
        session.mastodon.refresh()
        await session.reloadFromStore()
        return session
    }

    private func land(_ notes: [Note], in session: ShellSession) async {
        await session.store.ingest(notes, ifSourceHere: host)
        await session.reloadFromStore()
        await session.history.settled()
        await session.reloadFromStore()
    }

    @Test("A changed post lands and its history is asked of its own source, once: the row holds every wording before the one it says now, and the next landing asks nothing; a post never changed asks nothing")
    func filledOnce() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/9/history": .text(Self.history)])
        let session = await shell(http)
        await land([post("9", edited: true), post("8", edited: false)], in: session)

        #expect(await http.requested.map(\.absoluteString) == ["https://social.example/api/v1/statuses/9/history"])
        let row = try #require(session.notes.first { $0.statusID == "9" })
        #expect(row.earlier.map(\.body) == ["one", "two"] && row.historyAt == row.editedAt)

        await land([post("7", edited: false)], in: session)
        #expect(await http.requested.count == 1, "answered for that change: not asked again")
    }

    @Test("An ask let go of without being asked — its source's line would not take it — is looked at again by a later landing")
    func notTakenIsOfferedAgain() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/9/history": .text(Self.history)])
        let session = await shell(http)
        var full = LoadLimits()
        full.queued = 0
        session.loads = LoadPacer(limits: full, clock: StillClock())
        await land([post("9", edited: true)], in: session)
        #expect(await http.requested.isEmpty)

        var open = LoadLimits()
        open.interval = 0
        session.loads = LoadPacer(limits: open, clock: StillClock())
        await land([post("7", edited: false)], in: session)
        #expect(await http.requested.map(\.path) == ["/api/v1/statuses/9/history"])
        #expect(session.notes.first { $0.statusID == "9" }?.earlier.map(\.body) == ["one", "two"])
    }

    @Test("A history the source will not give leaves the row as this device saw it, and says nothing")
    func aFailureSaysNothing() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/9/history": .text(#"{"error":"Record not found"}"#, status: 404)])
        let session = await shell(http)
        await land([post("9", edited: true)], in: session)
        let row = try #require(session.notes.first { $0.statusID == "9" })
        #expect(row.earlier.isEmpty && row.historyAt == nil)
        // Given up for the run: a later landing does not ask again.
        await land([post("7", edited: false)], in: session)
        #expect(await http.requested.count == 1)
    }
}
