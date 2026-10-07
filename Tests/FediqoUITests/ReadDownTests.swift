import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A place where posts may be missing reads down when reached, and says so for good where the
/// source has nothing (#204).
///
/// What a test can reach: what reaching the place asks and lands, with no hole and no row twice;
/// what the list says there after, in which words; that the post being read stays; that the wait
/// and the press let a settled place go and count it. What it cannot: the row drawn in light and
/// dark on a Mac and a phone, a finger or VoiceOver on it.
@MainActor
@Suite("A place where posts may be missing reads down when reached")
struct ReadDownTests {
    private static let one = "one.example"
    private static let source = Source(host: one, kind: .mastodon)
    private static let stretch = Stretch(host: one, category: .public)
    private static let day: TimeInterval = 86_400

    private static func note(_ id: Int) -> Note {
        Note(
            id: "https://\(one)/users/ada/statuses/\(id)", source: source, author: "Ada", handle: "@ada",
            body: "\(id)", postedAt: ReadOnTests.posted(id), categories: [.public], statusID: "\(id)",
            listed: [.public: "\(id)"]
        )
    }

    private static func key(_ id: Int) -> NoteKey { note(id).key }

    /// A session holding 1 to 10, read again after 11 to 60 arrived and all but 31 to 60 were let
    /// go at the source: posts may be missing below 31.
    private func marked() async -> (ShellSession, TimelineServer) {
        let server = TimelineServer(host: Self.one, 1...10)
        let store = ItemStore()
        await store.add(Self.source)
        await store.ingest((1...10).map(Self.note))
        let session = ShellSession(
            http: server, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:]))
        )
        await session.reloadFromStore()
        await server.post(11...60)
        await server.keep(from: 31)
        await session.reload.timeline(.all, in: session)
        return (session, server)
    }

    private func drawn(_ session: ShellSession) -> [Int] {
        session.timelineItems(latest: nil).compactMap { $0.statusID.flatMap(Int.init) }
    }

    private func marks(_ session: ShellSession) -> [String: TimelineGapMarks] {
        session.gapMarks(in: session.timelineItems(latest: nil))
    }

    @Test("Reached, a place the source can fill is filled in order, no row twice; the mark goes, the post being read stays")
    func filled() async throws {
        let (session, server) = await marked()
        #expect(marks(session)[Self.key(31).rowID]?.below == [Self.stretch], "the premise")
        #expect(marks(session)[Self.key(31).rowID]?.posts[Self.one] == Self.key(31))
        await server.post(1...30)
        let selected = Self.key(45).rowID
        let landed = session.reload.landed

        await session.reload.readDown(Self.stretch, below: Self.key(31), in: session)

        #expect(await server.cursors.last == "max_id=31")
        #expect(drawn(session) == Array((1...60).reversed()), "every one, newest first, none twice")
        #expect(marks(session).isEmpty, "the mark went")
        #expect(session.reload.landed == landed, "nothing re-centred")
        let items = session.timelineItems(latest: nil)
        #expect(DummyCommand.focused(in: items, selected: selected) == .post(try #require(session.held(selected))))
        #expect(session.reload.asking.isEmpty && session.reload.failed.isEmpty)
    }

    @Test("A source with nothing more settles the place, in a deleted post's words; reaching it asks nothing more")
    func settles() async {
        let (session, server) = await marked()
        await session.reload.readDown(Self.stretch, below: Self.key(31), in: session)
        let row = marks(session)[Self.key(31).rowID]
        #expect(row?.settled == [Self.stretch] && row?.below == [])
        #expect(!TimelineGapRow.reads(.settled), "a settled place's row asks nothing as it comes into view")

        let asked = await server.cursors.count
        await session.reload.readDown(Self.stretch, below: Self.key(31), in: session)
        #expect(await server.cursors.count == asked, "and a reach that got through asks nothing either")
        #expect(drawn(session) == Array((31...60).reversed()) + Array((1...10).reversed()), "nothing invented")
    }

    @Test("A failed read leaves the mark as it was and says so; reaching it again tries again")
    func failedThenAgain() async {
        let (session, server) = await marked()
        await server.post(1...30)
        await server.refuse("max_id=31")
        await session.reload.readDown(Self.stretch, below: Self.key(31), in: session)
        #expect(marks(session)[Self.key(31).rowID]?.below == [Self.stretch])
        #expect(session.reload.failed == [Self.one])

        await server.refuse(nil)
        await session.reload.readDown(Self.stretch, below: Self.key(31), in: session)
        #expect(marks(session).isEmpty)
        #expect(drawn(session) == Array((1...60).reversed()))
        #expect(session.reload.failed.isEmpty)
    }

    @Test("A place reached while an ask for more is out waits for it, then reads down")
    func reachedWhileMore() async {
        let (session, server) = await marked()
        await server.post(1...30)
        let asked = await server.cursors.filter { $0 == "max_id=31" }.count
        await server.hold("max_id=1")
        let guardTask = hangGuard(server.gate)
        defer { guardTask.cancel() }
        let more = Task { await session.reload.more(.all, in: session) }
        #expect(await spun { await server.parked == 1 })
        await session.reload.readDown(Self.stretch, below: Self.key(31), in: session)
        #expect(session.reload.asking == [.more], "not dropped, and not beside the other")
        await server.gate.open()
        await more.value
        #expect(await spun { marks(session).isEmpty && session.reload.asking.isEmpty }, "read down once that one ended")
        #expect(await server.cursors.filter { $0 == "max_id=31" }.count == asked + 1, "once")
    }

    @Test("A settled place is counted apart from posts and goes by the wait; its post stays")
    func settledLetGo() async throws {
        let (session, _) = await marked()
        await session.reload.readDown(Self.stretch, below: Self.key(31), in: session)
        #expect(await session.store.goneCount() == 0)
        #expect(await session.store.settledCount() == 1)
        let now = Date()
        #expect(await session.letGoneGo(waitingDays: 7, keepingMonths: nil, from: now) == WentGone())
        #expect(await session.letGoneGo(waitingDays: nil, keepingMonths: nil, from: now + 400 * Self.day) == WentGone(),
                "never keeps it")
        #expect(await session.letGoneGo(waitingDays: 7, keepingMonths: nil, from: now + 8 * Self.day)
                == WentGone(places: 1))
        #expect(marks(session).isEmpty)
        #expect(drawn(session).contains(31), "the mark went, the post it sat by stays")
    }

    @Test("A settled place has its words, in English and in 中文, in every bundle")
    func words() throws {
        for language in [DummyLanguage.english, .taiwanese] {
            let settled = TimelineGapRow.words(.settled, host: Self.one, language: language)
            #expect(settled.contains(Self.one))
            #expect(settled.hasPrefix(DummyItemRow.goneWord(language: language)), "heard as a deleted post is")
            #expect(TimelineGapRow.symbol(.settled) == "xmark.bin")
            #expect(L10n.t("timeline.gap.settled", language: language) != "timeline.gap.settled", "\(language)")
        }
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        for lproj in ["zh-Hant", "zh-TW"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            #expect(strings.contains("\"timeline.gap.settled\""), "timeline.gap.settled in \(lproj)")
        }
    }
}
