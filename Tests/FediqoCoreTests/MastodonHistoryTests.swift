import Foundation
import Testing
@testable import FediqoCore

/// What a changed post said before, filled in from its source in the background (#332,
/// Decision 1): owed where a read brings a later change than the history held was answered for,
/// asked once in the source's line, landed in place of what this device saw, and a failure
/// leaving that as it was.
@Suite("A changed post's history, filled in")
struct MastodonHistoryTests {
    private typealias Captures = MastodonChangeCaptures
    private let host = MastodonFixture.host
    private let source = Source(host: MastodonFixture.host, kind: .mastodon)
    private static let path = "/api/v1/statuses/\(Captures.statusID)"

    private func note(_ json: String, sent: ReadMoment = .now()) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: source, category: .home, sent: sent)
    }

    private static func at(_ text: String) -> Date { MastodonJSON.date(from: text)! }

    /// The post as its source says it at each of four wordings: as written, then changed three times.
    private func version(_ n: Int) throws -> Note {
        let edited = n == 0 ? nil : "2026-10-21T00:3\(n):00.000Z"
        return try note(Captures.status(content: "<p>wording \(n)</p>", edited: edited, sensitive: false, language: "en"))
    }

    /// The source's history after three changes: four entries, the original first.
    private static let fourWordings = """
    [
      {"content":"<p>wording 0</p>","spoiler_text":"","sensitive":false,"created_at":"2026-10-21T00:24:12.838Z"},
      {"content":"<p>wording 1</p>","spoiler_text":"","sensitive":false,"created_at":"2026-10-21T00:31:00.000Z"},
      {"content":"<p>wording 2</p>","spoiler_text":"cw","sensitive":true,"created_at":"2026-10-21T00:32:00.000Z"},
      {"content":"<p>wording 3</p>","spoiler_text":"","sensitive":false,"created_at":"2026-10-21T00:33:00.000Z"}
    ]
    """

    /// A store holding `held`, with `sources`, and a fill over a line that starts each ask at once.
    private func filling(
        holding held: [Note], sources: [Source]? = nil, attempts: Int = 3
    ) async -> (ItemStore, MastodonHistoryFill) {
        let store = ItemStore()
        for one in sources ?? [source] { await store.add(one) }
        await store.ingest(held)
        var limits = LoadLimits()
        limits.interval = 0
        limits.backoff = 0
        limits.attempts = attempts
        return (store, MastodonHistoryFill(store: store, loads: LoadPacer(limits: limits)))
    }

    private func reader(_ routes: [String: FixtureSender.Outcome]) throws -> (MastodonPost, FixtureSender) {
        let server = FixtureSender(routes)
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonFixture.token)
        return (MastodonPost(door: MastodonAuthorized(token: MastodonFixture.token, sender: server, store: tokens)), server)
    }

    @Test("A history is owed by a Mastodon post its source says was changed, and not answered for that change; not by one never changed, a reblog, or one of another kind")
    func whatOwes() throws {
        let changed = try version(3)
        #expect(changed.historyOwed)
        #expect(!(try version(0)).historyOwed)
        let filled = changed.withHistory([], at: changed.editedAt!.addingTimeInterval(0.0004))
        #expect(!filled.historyOwed, "answered for that change, to the millisecond")
        #expect(changed.withHistory([], at: Self.at("2026-10-21T00:32:00.000Z")).historyOwed, "answered for an earlier one")
        let forum = Note(id: "t1", source: Source(host: "forum.example", kind: .discourse), author: "A", handle: "@a",
                         body: "x", postedAt: Date(), categories: [], statusID: "1", editedAt: Date())
        #expect(!forum.historyOwed)
    }

    @Test("A post changed three times elsewhere and seen once here holds all four wordings after one ask of its own source — the source's in place of what this device saw — and owes nothing more")
    func fourWordingsAfter() async throws {
        let (store, fill) = await filling(holding: [try version(0)])
        await store.refresh([try version(3)], ifSourceHere: host)
        let seen = try #require(await store.note(try version(0).key))
        #expect(seen.earlier.map(\.body) == ["wording 0"], "what this device saw: one change")

        let owed = await store.historyOwed(host: host)
        #expect(owed.map(\.statusID) == [Captures.statusID] && owed.first?.editedAt == Self.at("2026-10-21T00:33:00.000Z"))
        let (post, server) = try reader(["\(Self.path)/history": .json(Self.fourWordings)])
        #expect(await fill.fill(try #require(owed.first)) { post } == .done)

        let held = try #require(await store.note(seen.key))
        #expect(held.earlier == [
            Wording(body: "wording 0", spoiler: "", sensitive: false, until: Self.at("2026-10-21T00:31:00.000Z")),
            Wording(body: "wording 1", spoiler: "", sensitive: false, until: Self.at("2026-10-21T00:32:00.000Z")),
            Wording(body: "wording 2", spoiler: "cw", sensitive: true, until: Self.at("2026-10-21T00:33:00.000Z")),
        ])
        #expect(held.body == "wording 3" && held.historyAt == held.editedAt)
        #expect(await server.requests.map { $0.url?.host } == [host])
        #expect(await server.paths == ["\(Self.path)/history"])

        // Answered for that change: nothing more is owed, and nothing more is asked.
        #expect(await store.historyOwed(host: host).isEmpty)
        let again = try #require(ItemStore.HistoryOwed(seen))
        #expect(await fill.fill(again) { post } == .notTaken(.already))
        #expect(await server.requests.count == 1)

        // A later change owes one ask more.
        let later = try note(Captures.status(content: "<p>wording 4</p>", edited: "2026-10-21T00:34:00.000Z", sensitive: false, language: "en"))
        await store.refresh([later], ifSourceHere: host)
        #expect(await store.historyOwed(host: host).map(\.editedAt) == [Self.at("2026-10-21T00:34:00.000Z")])
        #expect(await store.note(seen.key)?.earlier.count == 4, "what this device saw is added until it is asked")
    }

    @Test("A failed ask, a refusal and an answer that is no history leave what this device saw and say nothing; given up, it is not asked again this run")
    func aFailureLeavesIt() async throws {
        for outcome in [FixtureSender.Outcome.fail, .json(#"{"error":"Record not found"}"#, status: 404), .json(#"{"error":"x"}"#)] {
            let (store, fill) = await filling(holding: [try version(0)], attempts: 2)
            await store.refresh([try version(3)], ifSourceHere: host)
            let seen = try #require(await store.note(try version(0).key))
            let owed = try #require(await store.historyOwed(host: host).first)
            let (post, server) = try reader(["\(Self.path)/history": outcome])
            let end = await fill.fill(owed) { post }
            #expect(end == .done || end == .gaveUp, "\(outcome)")
            #expect(await store.note(seen.key) == seen, "\(outcome)")
            #expect(await store.historyOwed(host: host).isEmpty, "given up for the run: \(outcome)")
            let asked = await server.requests.count
            #expect(await fill.fill(owed) { post } == .notTaken(.already))
            #expect(await server.requests.count == asked)
        }
    }

    @Test("Nothing to ask through takes nothing and gives nothing up: the post still owes its ask")
    func nobodyToAsk() async throws {
        let (store, fill) = await filling(holding: [try version(0)])
        await store.refresh([try version(3)], ifSourceHere: host)
        let owed = try #require(await store.historyOwed(host: host).first)
        #expect(await fill.fill(owed) { nil } == .done)
        #expect(await store.historyOwed(host: host) == [owed])
    }

    @Test("A history lands only over the change it was asked for, and only where its newest wording is what the row says")
    func landsOnlyOverItsChange() async throws {
        let (store, _) = await filling(holding: [try version(0)])
        await store.refresh([try version(2)], ifSourceHere: host)
        let owed = try #require(await store.historyOwed(host: host).first)
        let before = try #require(await store.note(owed.item))
        let first = Wording(body: "wording 0", spoiler: "", until: Self.at("2026-10-21T00:31:00.000Z"))
        // The source changed again since the row was read: its history ends in words the row does not hold.
        let ahead = PostHistory(earlier: [first, Wording(body: "wording 2", spoiler: "", until: Self.at("2026-10-21T00:33:00.000Z"))],
                                now: Wording(body: "wording 3", spoiler: "", until: Self.at("2026-10-21T00:33:00.000Z")))
        #expect(await store.takeHistory(owed))
        #expect(!(await store.landHistory(ahead, for: owed)))
        #expect(!(await store.landHistory(PostHistory(earlier: [first], now: nil), for: owed)), "a history with nothing now")
        #expect(await store.note(owed.item) == before)
        // Read again meanwhile: the change asked about is no longer the row's.
        #expect(await store.takeHistory(owed))
        await store.refresh([try version(3)], ifSourceHere: host)
        let mine = PostHistory(earlier: [first], now: Wording(body: "wording 2", spoiler: "", until: Self.at("2026-10-21T00:32:00.000Z")))
        #expect(!(await store.landHistory(mine, for: owed)))
        #expect(await store.historyOwed(host: host).map(\.editedAt) == [Self.at("2026-10-21T00:33:00.000Z")])
    }

    @Test("Another server's post, whose source dates each entry when it heard of it — later than the author's own moment of the change — still lands: no moment is compared, only the words it ends in")
    func aRemotePostLands() async throws {
        let (store, fill) = await filling(holding: [try version(0)])
        await store.refresh([try version(3)], ifSourceHere: host)
        let owed = try #require(await store.historyOwed(host: host).first)
        let heard = """
        [{"content":"<p>wording 0</p>","spoiler_text":"","sensitive":false,"created_at":"2026-10-21T00:40:00.000Z"},
         {"content":"<p>wording 3</p>","spoiler_text":"","sensitive":false,"created_at":"2026-10-21T00:45:00.000Z"}]
        """
        let (post, _) = try reader(["\(Self.path)/history": .json(heard)])
        #expect(await fill.fill(owed) { post } == .done)
        let held = try #require(await store.note(owed.item))
        #expect(held.earlier == [Wording(body: "wording 0", spoiler: "", sensitive: false, until: Self.at("2026-10-21T00:45:00.000Z"))])
        #expect(held.historyAt == owed.editedAt && !held.historyOwed)
    }

    @Test("The source's wordings replace the device's within the cap: fifty, the oldest going first")
    func heldToTheCap() async throws {
        let (store, fill) = await filling(holding: [try version(0)])
        await store.refresh([try version(3)], ifSourceHere: host)
        let owed = try #require(await store.historyOwed(host: host).first)
        let start = Self.at("2026-10-20T00:00:00.000Z")
        let entries = (0..<60).map { i in
            #"{"content":"<p>w\#(i)</p>","spoiler_text":"","sensitive":false,"created_at":"\#(ISO8601DateFormatter().string(from: start.addingTimeInterval(Double(i) * 60)))"}"#
        } + [#"{"content":"<p>wording 3</p>","spoiler_text":"","sensitive":false,"created_at":"2026-10-21T00:33:00.000Z"}"#]
        let (post, _) = try reader(["\(Self.path)/history": .json("[" + entries.joined(separator: ",") + "]")])
        _ = await fill.fill(owed) { post }
        let held = try #require(await store.note(owed.item))
        #expect(held.earlier.count == Wording.kept && held.earlier.first?.body == "w10" && held.earlier.last?.body == "w59")
    }

    @Test("Two sessions over one store: what one has taken the other does not ask, and what one has answered the other owes nothing of")
    func twoSessions() async throws {
        let (store, first) = await filling(holding: [try version(0)])
        var limits = LoadLimits()
        limits.interval = 0
        let second = MastodonHistoryFill(store: store, loads: LoadPacer(limits: limits))
        await store.refresh([try version(3)], ifSourceHere: host)
        let owed = try #require(await store.historyOwed(host: host).first)
        #expect(await store.takeHistory(owed))
        let (post, server) = try reader(["\(Self.path)/history": .json(Self.fourWordings)])
        #expect(await second.fill(owed) { post } == .notTaken(.already))
        await store.releaseHistory(owed, givenUp: false)
        #expect(await first.fill(owed) { post } == .done)
        #expect(await second.fill(owed) { post } == .notTaken(.already))
        #expect(await server.requests.count == 1)
        // A store made again from what this one holds — a relaunch — owes nothing either.
        let relaunched = ItemStore(sources: [source], notes: await store.all())
        #expect(await relaunched.historyOwed(host: host).isEmpty)
    }

    @Test("Each owed ask is of the post's own source: a source holding the same post owes its own, and a host that is not a source here owes nothing")
    func ownSourceOnly() async throws {
        let other = Source(host: "other.example", kind: .mastodon)
        let theirs = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(Captures.status(content: "<p>wording 3</p>", edited: "2026-10-21T00:33:00.000Z", sensitive: false, language: "en").utf8))
            .asNote(source: other, category: .home, sent: .now())
        let (store, _) = await filling(holding: [try version(3), theirs], sources: [source, other])
        let mine = await store.historyOwed(host: host)
        let elsewhere = await store.historyOwed(host: other.host)
        #expect(mine.map(\.item.host) == [host] && elsewhere.map(\.item.host) == [other.host])
        #expect(await store.historyOwed(host: "nobody.example").isEmpty)
    }
}
