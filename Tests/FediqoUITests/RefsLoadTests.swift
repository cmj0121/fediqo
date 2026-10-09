import Foundation
import os
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A clock that stands still: no second passes, and whoever waits on it waits until they are
/// cancelled. With no pace and no backoff to wait out (`RefsLoadTests.unpaced`), loads are
/// asked in order, one after another, and a try's deadline never comes. The pace, the backoff
/// and the deadline are the pacer's own tests'.
final class StillClock: PacerClock, @unchecked Sendable {
    private let sleepers = OSAllocatedUnfairLock(uncheckedState: [UUID: CheckedContinuation<Void, any Error>]())
    func elapsed() -> TimeInterval { 0 }
    func wall() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(until moment: TimeInterval) async throws {
        guard moment > 0 else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, any Error>) in
                let cancelled = sleepers.withLockUnchecked { sleepers -> Bool in
                    if Task.isCancelled { return true }
                    sleepers[id] = wake
                    return false
                }
                if cancelled { wake.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            sleepers.withLockUnchecked { $0.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}

/// #293 through the session: an item that arrives referring to a post not held has that post
/// loaded — once, through the source that brought it, in that source's line — and the row says
/// it is on its way until it has come.
@MainActor
@Suite("What an item refers to is loaded")
struct RefsLoadTests {
    private let host = "social.example"
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private var source: Source { Source(host: host, kind: .mastodon) }

    /// Every bound a load keeps, with nothing to wait out between two tries.
    private static var unpaced: LoadLimits {
        var limits = LoadLimits()
        limits.interval = 0
        limits.backoff = 0
        return limits
    }

    /// An answer as a timeline brought it: Home's by default, which only a signed-in reader has.
    private func reply(_ id: String, to parent: String, through category: FediqoCore.Category = .home) -> Note {
        Note(
            id: "https://social.example/users/ada/statuses/\(id)", source: source, author: "Ada",
            handle: "@ada@social.example", body: "an answer", postedAt: Self.origin, categories: [category],
            reply: Reply(handle: "@bob@social.example", inReplyToId: parent), statusID: id
        )
    }

    /// Bob's post `id`, as the source sends it; itself an answer to `parent` where one is given.
    private static func status(_ id: String, answering parent: String? = nil) -> String {
        let answering = parent.map { #""in_reply_to_id":"\#($0)","# } ?? ""
        return """
        {"id":"\(id)","uri":"https://social.example/users/bob/statuses/\(id)",\(answering)
         "created_at":"2023-11-01T00:00:00.000Z","content":"<p>the earlier post \(id)</p>","visibility":"public",
         "account":{"username":"bob","acct":"bob","display_name":"Bob"}}
        """
    }

    private func shell(
        unsigned: any HTTPClient = FixtureHTTP(), signed routes: [String: ActServer.Outcome]? = nil,
        limits: LoadLimits = unpaced
    ) async throws -> (ShellSession, ActServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        if routes != nil {
            try tokens.save(MastodonToken(host: host, accessToken: "tok-123", clientID: "c", clientSecret: "s", scopes: MastodonOAuth.reading))
        }
        let server = ActServer(routes ?? [:])
        let store = ItemStore()
        await store.add(source)
        let work = SourceWork()
        work.govern(sources: [host])
        let session = ShellSession(http: unsigned, store: store, mastodon: MastodonSessions(tokens: tokens, sender: server))
        session.work = work
        session.loads = LoadPacer(limits: limits, clock: StillClock())
        session.mastodon.refresh()
        await session.reloadFromStore()
        return (session, server, tokens)
    }

    /// Lands `notes` as a timeline does, and waits for every load that takes to end and land.
    private func land(_ notes: [Note], in session: ShellSession) async {
        await session.store.ingest(notes, ifSourceHere: host)
        await session.reloadFromStore()
        await session.refs.settled()
        await session.reloadFromStore()
    }

    private func row(_ id: String, in session: ShellSession) throws -> DummyItem {
        DummyItem(try #require(session.notes.first { $0.statusID == id }))
    }

    // MARK: - Acceptance

    @Test("A reply arrives whose earlier post is not held: afterwards that post is held and stands in All at its own publish time, asked of the reply's own source by that source's id for it; the post before that one is not asked for")
    func theEarlierPostIsLoaded() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text(Self.status("1", answering: "0"))])
        let (session, server, _) = try await shell(unsigned: http)
        await land([reply("2", to: "1")], in: session)

        #expect(await http.requested.map(\.absoluteString) == ["https://social.example/api/v1/statuses/1"])
        #expect(await server.requests.isEmpty)
        let parent = try #require(session.notes.first { $0.statusID == "1" })
        #expect(parent.postedAt == ISO8601DateFormatter().date(from: "2023-11-01T00:00:00Z"))
        #expect(parent.categories.isEmpty && !parent.refsDue)
        #expect(session.timelineItems(latest: nil).map(\.statusID) == ["2", "1"], "in All, each at its own time")
        #expect(session.notes.allSatisfy { !$0.refsDue })
        #expect(session.notes.count == 2, "what the loaded post answers in turn is not followed")
        // Listed where other reads are, as what it is.
        #expect(session.work.record.map(\.purpose) == [.reference])
        #expect(session.work.record.allSatisfy { $0.source == host && $0.reached == host })
    }

    @Test("While it is on its way the reply's row says so, and the timeline is there to read meanwhile; once it has come the row says only whom it answers")
    func onItsWayIsSaid() async throws {
        let http = GatedHTTP(["/api/v1/statuses/1": .text(Self.status("1"))], holding: "/api/v1/statuses/1")
        let guardTask = hangGuard(http.gate)
        defer { guardTask.cancel() }
        let (session, _, _) = try await shell(unsigned: http)
        await session.store.ingest([reply("2", to: "1")], ifSourceHere: host)
        await session.reloadFromStore()
        await session.refs.asked()

        let waiting = try row("2", in: session)
        #expect(waiting.owes == [.answers] && !waiting.owesStalled)
        #expect(DummyItemRow.replyLine(waiting, language: .english) == "Reply to @bob@social.example — that post is on its way")
        #expect(DummyItemRow.replyLine(waiting, language: .taiwanese) == "回覆 @bob@social.example——那則貼文還在路上")
        #expect(session.timelineItems(latest: nil).map(\.statusID) == ["2"], "shown at once")

        await http.gate.open()
        await session.refs.settled()
        await session.reloadFromStore()
        let after = try row("2", in: session)
        #expect(after.owes.isEmpty)
        #expect(DummyItemRow.replyLine(after, language: .english) == "Reply to @bob@social.example")
    }

    @Test("Reading the same reply again asks for nothing more; letting the loaded post go and reading again does not bring it back")
    func once() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text(Self.status("1"))])
        let (session, _, _) = try await shell(unsigned: http)
        await land([reply("2", to: "1")], in: session)
        await land([reply("2", to: "1")], in: session)
        #expect(await http.paths == ["/api/v1/statuses/1"])
        let parent = try #require(session.notes.first { $0.statusID == "1" })
        await session.store.forget(parent.key)
        await land([reply("2", to: "1")], in: session)
        #expect(await http.paths == ["/api/v1/statuses/1"])
        #expect(session.notes.map(\.statusID) == ["2"])
        #expect(try row("2", in: session).owes.isEmpty, "and the row does not say it is on its way")
    }

    @Test("A post that quotes one not held and not sent along: the quoted post is loaded, held and stands in All; meanwhile the quote says it is on its way")
    func aQuotedPostIsLoaded() async throws {
        let http = GatedHTTP(["/api/v1/statuses/1": .text(Self.status("1"))], holding: "/api/v1/statuses/1")
        let guardTask = hangGuard(http.gate)
        defer { guardTask.cancel() }
        let (session, _, _) = try await shell(unsigned: http)
        let quoting = Note(
            id: "https://social.example/users/ada/statuses/5", source: source, author: "Ada", handle: "@ada@social.example",
            body: "look at this", postedAt: Self.origin, categories: [.home], statusID: "5", quote: Quote(state: .accepted, statusID: "1")
        )
        await session.store.ingest([quoting], ifSourceHere: host)
        await session.reloadFromStore()
        await session.refs.asked()
        let waiting = try row("5", in: session)
        #expect(QuoteBand.Loading(waiting) == .onItsWay)
        #expect(QuoteBand.decorator(try #require(waiting.quote), loading: .onItsWay, language: .english) == "quoted post on its way")
        #expect(QuoteBand.decorator(try #require(waiting.quote), loading: .onItsWay, language: .taiwanese) == "引用的貼文還在路上")
        await http.gate.open()
        await session.refs.settled()
        await session.reloadFromStore()
        #expect(session.timelineItems(latest: nil).map(\.statusID) == ["5", "1"])
        #expect(QuoteBand.Loading(try row("5", in: session)) == nil)
    }

    @Test("None of what was loaded shows in a timeline whose only rule is Home; it shows in one whose rule names its author")
    func throughTheRules() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text(Self.status("1"))])
        let (session, _, _) = try await shell(unsigned: http)
        await land([reply("2", to: "1")], in: session)
        func drawn(_ rule: Rule?) -> [String?] {
            let timeline = TimelineDefinition(name: "T", rules: [rule].compactMap { $0 })
            session.written = [timeline]
            session.timelineID = .written(timeline.id)
            return session.timelineItems(latest: nil).map(\.statusID)
        }
        #expect(drawn(.category(.home, in: .every, sources: session.sources)) == ["2"])
        #expect(drawn(.author("bob@social.example", in: .every, sources: session.sources)) == ["1"])
    }

    // MARK: - Whom it is asked as, and of

    @Test("Signed in to the source, the load is asked as the reader, through that sign-in, and never unsigned beside it")
    func asTheReader() async throws {
        let http = FixtureHTTP()
        let (session, server, _) = try await shell(unsigned: http, signed: ["/api/v1/statuses/1": .json(Self.status("1"))])
        await land([reply("2", to: "1")], in: session)
        #expect(await server.paths == ["/api/v1/statuses/1"])
        #expect(await server.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(await server.requests.first?.url?.host == host)
        #expect(await http.paths.isEmpty)
        #expect(session.notes.contains { $0.statusID == "1" })
    }

    @Test("A source read as the reader whose sign-in has gone is not read unsigned in their place: nothing is asked, and the reply still owes its load")
    func noUnsignedFallback() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text(Self.status("1")), "/api/v1/statuses/3": .text(Self.status("3"))])
        let (session, server, tokens) = try await shell(unsigned: http, signed: ["/api/v1/statuses/1": .json(Self.status("1"))])
        await land([reply("2", to: "1")], in: session)
        #expect(await server.paths == ["/api/v1/statuses/1"], "the premise: read as the reader")
        try tokens.forget(host: host)
        session.mastodon.refresh()

        await land([reply("4", to: "3")], in: session)
        #expect(await http.paths.isEmpty, "nothing was asked unsigned")
        #expect(await server.paths == ["/api/v1/statuses/1"], "and nothing more as the reader who has gone")
        #expect(session.refs.count == 0, "it took no place in the line")
        // The sign-in ending dropped the source's line; nothing has been put in it since.
        #expect(await session.loads.standing(host: host) == LoadStanding(), "and no try of the run")
        #expect(session.notes.first { $0.statusID == "4" }?.refsDue == false, "what the reader's own timeline left owing went with the sign-in")
        // Even an item a public timeline brought, which still owes, takes no slot while the source is in that state.
        await land([reply("6", to: "5", through: .public)], in: session)
        await session.refs.near(session.notes.map(\.key.rowID), in: session)
        await session.refs.settled()
        #expect(session.notes.first { $0.statusID == "6" }?.refsDue == true)
        #expect(await session.loads.standing(host: host) == LoadStanding(), "nor when its row comes near, however often")
        #expect(await http.paths.isEmpty)
    }

    /// An answer as a search, a thread or a hashtag's read brings one: through no category.
    /// `signed` is whether the read was made as the reader — a source then says what the
    /// reader did to the post, here that they have not favourited it.
    private func found(_ id: String, to parent: String, signed: Bool) -> Note {
        Note(
            id: "https://social.example/users/ada/statuses/\(id)", source: source, author: "Ada",
            handle: "@ada@social.example", body: "an answer", postedAt: Self.origin, categories: [],
            reply: Reply(handle: "@bob@social.example", inReplyToId: parent), favourited: signed ? false : nil, statusID: id
        ).readNow()
    }

    @Test("On a source nobody is signed in to, what a thread or a search brought did not arrive as the reader: the posts its answers refer to are asked unsigned, the row stops saying on its way, and an unsigned 'no such post' is that source's word")
    func unsignedReadsAreNobodys() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text(Self.status("1")), "/api/v1/statuses/3": .text("{}", status: 404)])
        let (session, _, _) = try await shell(unsigned: http)
        await land([found("2", to: "1", signed: false), found("4", to: "3", signed: false)], in: session)
        #expect(Set(await http.paths) == ["/api/v1/statuses/1", "/api/v1/statuses/3"])
        #expect(session.notes.contains { $0.statusID == "1" })
        #expect(DummyItemRow.replyLine(try row("2", in: session), language: .english) == "Reply to @bob@social.example")
        #expect(DummyItemRow.replyLine(try row("4", in: session), language: .english) == "Reply to @bob@social.example — that post is gone or hidden at its source")
    }

    @Test("Signed in, what a search brought is the reader's: asked as the reader, and what it still owes goes when the sign-in ends, with nothing asked unsigned")
    func signedReadsAreTheReaders() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text(Self.status("1"))])
        let (session, server, tokens) = try await shell(unsigned: http, signed: [:])
        await land([found("2", to: "1", signed: true)], in: session)
        let asReader = await server.paths
        #expect(!asReader.isEmpty && Set(asReader) == ["/api/v1/statuses/1"], "asked as the reader")
        #expect(session.notes.first { $0.statusID == "2" }?.refsDue == true, "the premise: it did not come, and is still owed")
        try tokens.forget(host: host)
        session.mastodon.refresh()
        await land([], in: session)
        #expect(session.notes.first { $0.statusID == "2" }?.refsDue == false, "the reader's debt went with the sign-in")
        #expect(await http.paths.isEmpty)
    }

    @Test("A launch with nobody signed in: what a signed read left owing is dropped and never asked; what an unsigned read left owing is asked, unsigned")
    func aLaunchKnowsWhichReadsWereSigned() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text(Self.status("1")), "/api/v1/statuses/3": .text(Self.status("3"))])
        var signed = found("2", to: "1", signed: true), unsigned = found("4", to: "3", signed: false)
        signed.refsDue = true
        unsigned.refsDue = true
        let work = SourceWork()
        work.govern(sources: [host])
        let session = ShellSession(http: http, store: ItemStore(sources: [source], notes: [signed, unsigned]))
        session.work = work
        session.loads = LoadPacer(limits: Self.unpaced, clock: StillClock())
        await session.reloadFromStore()
        await session.refs.settled()
        await session.reloadFromStore()
        #expect(await http.paths == ["/api/v1/statuses/3"])
        #expect(session.notes.first { $0.statusID == "2" }?.refsDue == false)
        #expect(session.notes.contains { $0.statusID == "3" })
    }

    // MARK: - Gone, and failing

    @Test("A post that no longer exists is not held and not asked for again, and the reply's row says it is gone or hidden at its source — a source answers the same for a post it deleted and one it will not show", arguments: [404, 410])
    func gone(status: Int) async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text("{}", status: status)])
        let (session, _, _) = try await shell(unsigned: http)
        let before = reply("2", to: "1", through: .public)
        await land([before], in: session)
        await land([before], in: session)
        #expect(await http.paths == ["/api/v1/statuses/1"])
        let after = try #require(session.notes.first)
        #expect(session.notes.count == 1 && !after.refsDue && after.body == before.body)
        #expect(after.refs.first?.gone == true)
        let item = try row("2", in: session)
        #expect(item.owes.isEmpty && item.refsGone == [.answers])
        #expect(DummyItemRow.replyLine(item, language: .english) == "Reply to @bob@social.example — that post is gone or hidden at its source")
        #expect(DummyItemRow.replyLine(item, language: .taiwanese) == "回覆 @bob@social.example——那則貼文在來源已消失或不公開")
    }

    @Test("A post said to be gone that a timeline brings after all: the row says only whom it answers, with nothing after it")
    func goneIsTakenBack() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text("{}", status: 404)])
        let (session, _, _) = try await shell(unsigned: http)
        await land([reply("2", to: "1", through: .public)], in: session)
        #expect(try row("2", in: session).refsGone == [.answers], "the premise")
        let parent = Note(
            id: "https://social.example/users/bob/statuses/1", source: source, author: "Bob", handle: "@bob@social.example",
            body: "here after all", postedAt: Self.origin.addingTimeInterval(-60), categories: [.public], statusID: "1"
        )
        await land([parent], in: session)
        let item = try row("2", in: session)
        #expect(item.refsGone.isEmpty && item.refsUnheld.isEmpty && item.owes.isEmpty)
        #expect(DummyItemRow.replyLine(item, language: .english) == "Reply to @bob@social.example")
    }

    @Test("An item that answers one post and quotes another, where the read of the first comes back as no word on the post: the reply line says only whom it answers, the first is asked once however often the row is near, and the quoted post is loaded")
    func oneOfTwoRefused() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text("{}", status: 404), "/api/v1/statuses/4": .fail])
        let (session, _, _) = try await shell(unsigned: http)
        // Through Home, on a source not signed in to: an unsigned "no such post" is not believed.
        let both = Note(
            id: "https://social.example/users/ada/statuses/5", source: source, author: "Ada", handle: "@ada@social.example",
            body: "x", postedAt: Self.origin, categories: [.home], reply: Reply(handle: "@bob@social.example", inReplyToId: "1"),
            statusID: "5", quote: Quote(state: .accepted, statusID: "4")
        )
        await land([both], in: session)
        // The answer's read was refused; the quote's failed three times and was given up for the run.
        #expect(await http.paths.filter { $0 == "/api/v1/statuses/1" }.count == 1)
        #expect(await http.paths.filter { $0 == "/api/v1/statuses/4" }.count == 3)
        let item = try row("5", in: session)
        #expect(item.owes == [.quotes] && item.owesStalled, "only the quote is still owed")
        #expect(DummyItemRow.replyLine(item, language: .english) == "Reply to @bob@social.example")
        #expect(QuoteBand.Loading(item) == .stalled)
        #expect(session.notes.first?.refs.first { $0.kind == .answers }?.gone == false)

        await session.refs.near([item.id], in: session)
        await session.refs.settled()
        await land([both], in: session)
        #expect(await http.paths.filter { $0 == "/api/v1/statuses/1" }.count == 1, "what was refused is not asked again this run")
    }

    @Test("Read as the reader, a post its source says is gone is said to be gone; read unsigned, 'no such post' about what a reader's own timeline referred to is not the source's word, and is not written as gone")
    func whoseWordGoneIs() async throws {
        let (signed, server, _) = try await shell(signed: ["/api/v1/statuses/1": .json("{}", status: 404)])
        await land([reply("2", to: "1")], in: signed)
        #expect(await server.paths == ["/api/v1/statuses/1"])
        #expect(signed.notes.first?.refs.first?.gone == true)

        let http = FixtureHTTP(["/api/v1/statuses/1": .text("{}", status: 404)])
        let (unsigned, _, _) = try await shell(unsigned: http)
        await land([reply("2", to: "1")], in: unsigned)
        #expect(await http.paths == ["/api/v1/statuses/1"])
        let note = try #require(unsigned.notes.first)
        #expect(!note.refsDue && note.refs.first?.gone == false, "settled, and not said to be gone")
        #expect(DummyItemRow.replyLine(try row("2", in: unsigned), language: .english) == "Reply to @bob@social.example")
    }

    @Test("A loaded post let go later is said on the row to be no longer held, and so is a quoted one on the quote's mark")
    func noLongerHeldIsSaid() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text(Self.status("1"))])
        let (session, _, _) = try await shell(unsigned: http)
        let quoting = Note(
            id: "https://social.example/users/ada/statuses/5", source: source, author: "Ada", handle: "@ada@social.example",
            body: "look", postedAt: Self.origin.addingTimeInterval(1), categories: [.public], statusID: "5",
            quote: Quote(state: .accepted, statusID: "1")
        )
        await land([reply("2", to: "1", through: .public), quoting], in: session)
        #expect(await http.paths == ["/api/v1/statuses/1"], "one request for the one post both refer to")
        #expect(DummyItemRow.replyLine(try row("2", in: session), language: .english) == "Reply to @bob@social.example")
        #expect(QuoteBand.Loading(try row("5", in: session)) == nil)

        let parent = try #require(session.notes.first { $0.statusID == "1" })
        await session.store.forget(parent.key)
        await session.reloadFromStore()
        let answer = try row("2", in: session), quote = try row("5", in: session)
        #expect(answer.refsUnheld == [.answers] && answer.owes.isEmpty)
        #expect(DummyItemRow.replyLine(answer, language: .english) == "Reply to @bob@social.example — that post is no longer held")
        #expect(DummyItemRow.replyLine(answer, language: .taiwanese) == "回覆 @bob@social.example——那則貼文已不再留著")
        #expect(QuoteBand.Loading(quote) == .unheld)
        #expect(QuoteBand.decorator(try #require(quote.quote), loading: .unheld, language: .english) == "quoted post no longer held")
        #expect(QuoteBand.decorator(try #require(quote.quote), loading: .gone, language: .taiwanese) == "引用的貼文在來源已消失或不公開")
        #expect(await http.paths.count == 1, "and it is not asked for again")
        for key in ["item.reply.gone", "item.reply.unheld", "quote.short.gone", "quote.short.unheld", "item.reply.onItsWay", "item.reply.stalled", "quote.short.onItsWay", "quote.short.stalled"] {
            for language in [DummyLanguage.english, .taiwanese] { #expect(L10n.t(key, language: language) != key) }
        }
    }

    @Test("A post an item waits for that a timeline brings meanwhile settles it: the row stops saying it is on its way, and nothing is asked")
    func settledOnSight() async throws {
        let (session, _, _) = try await shell(unsigned: FixtureHTTP())
        session.startsLoads = false
        await land([reply("2", to: "1", through: .public)], in: session)
        #expect(try row("2", in: session).owes == [.answers])
        #expect(session.owingRows == [try row("2", in: session).id])
        let parent = Note(
            id: "https://social.example/users/bob/statuses/1", source: source, author: "Bob", handle: "@bob@social.example",
            body: "the earlier post", postedAt: Self.origin.addingTimeInterval(-60), categories: [.public], statusID: "1"
        )
        await land([parent], in: session)
        #expect(try row("2", in: session).owes.isEmpty)
        #expect(session.owingRows.isEmpty, "and the list has no row to tell the loader about")
    }

    @Test("A load that fails leaves the reply as it was, is tried as often as a load is, and is then given up for the run and said: the row says the post could not be read for now, and still owes it")
    func failing() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .fail])
        let (session, _, _) = try await shell(unsigned: http)
        await land([reply("2", to: "1")], in: session)
        #expect(await http.paths == ["/api/v1/statuses/1", "/api/v1/statuses/1", "/api/v1/statuses/1"])
        let item = try row("2", in: session)
        #expect(item.owes == [.answers] && item.owesStalled)
        #expect(DummyItemRow.replyLine(item, language: .english) == "Reply to @bob@social.example — that post could not be read for now")
        #expect(DummyItemRow.replyLine(item, language: .taiwanese) == "回覆 @bob@social.example——那則貼文暫時讀不到")
        #expect(session.notes.first?.refsDue == true && session.notes.first?.body == "an answer")
        await land([reply("2", to: "1")], in: session)
        #expect(await http.paths.count == 3, "given up for the run: not asked again by another landing")
    }

    // MARK: - How much

    @Test("One landing asks one source for ten at most; the rest stay owed until their rows are near the screen, and are asked then")
    func theShareOfALanding() async throws {
        var routes: [String: FixtureHTTP.Outcome] = [:]
        for parent in 100..<115 { routes["/api/v1/statuses/\(parent)"] = .text(Self.status("\(parent)")) }
        let http = FixtureHTTP(routes)
        let (session, _, _) = try await shell(unsigned: http)
        let replies = (0..<15).map { index in
            Note(
                id: "https://social.example/users/ada/statuses/\(index)", source: source, author: "Ada", handle: "@ada@social.example",
                body: "answer \(index)", postedAt: Self.origin.addingTimeInterval(Double(index)), categories: [.home],
                reply: Reply(inReplyToId: "\(100 + index)"), statusID: "\(index)"
            )
        }
        await land(replies, in: session)
        #expect(ShellRefs.eager == 10)
        #expect(await http.paths.count == 10, "the newest ten")
        #expect(Set(await http.paths) == Set((105..<115).map { "/api/v1/statuses/\($0)" }))
        let owing = session.notes.filter { $0.refsDue }
        #expect(owing.count == 5 && owing.allSatisfy { !$0.refsStalled })

        await session.refs.near(owing.prefix(2).map(\.key.rowID), in: session)
        await session.refs.settled()
        #expect(await http.paths.count == 12, "the two whose rows came near")
        await session.reloadFromStore()
        #expect(session.notes.filter { $0.refsDue }.count == 3)
    }

    @Test("Forty answers in one stretch, each to a post not held, cost the source ten requests, however the landing is read again")
    func aHostileStretch() async throws {
        var routes: [String: FixtureHTTP.Outcome] = [:]
        for parent in 100..<140 { routes["/api/v1/statuses/\(parent)"] = .text(Self.status("\(parent)", answering: "9\(parent)")) }
        let http = FixtureHTTP(routes)
        let (session, _, _) = try await shell(unsigned: http)
        let stretch = (0..<40).map { index in
            Note(
                id: "https://social.example/users/eve/statuses/\(index)", source: source, author: "Eve", handle: "@eve@social.example",
                body: "x", postedAt: Self.origin.addingTimeInterval(Double(index)), categories: [.home],
                reply: Reply(inReplyToId: "\(100 + index)"), statusID: "\(index)"
            )
        }
        await land(stretch, in: session)
        await land(stretch, in: session)
        #expect(await http.paths.count == 10)
        #expect(session.notes.count == 50, "ten loaded, and none of what they answer in turn")
        #expect(await http.requested.allSatisfy { $0.host == host })
    }

    // MARK: - Not at all

    @Test("A run that did not read its store asks for nothing")
    func aStoreNotRead() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/1": .text(Self.status("1"))])
        let (session, _, _) = try await shell(unsigned: http)
        session.startsLoads = false
        await land([reply("2", to: "1")], in: session)
        await session.refs.near(session.notes.map(\.key.rowID), in: session)
        await session.refs.settled()
        #expect(await http.paths.isEmpty)
        #expect(session.notes.first?.refsDue == true, "still owed, for a run that may ask")
    }

    @Test("A launch resumes what the last run still owed, within the same share; a store it did not read owes it nothing to ask")
    func aLaunchResumes() async throws {
        var routes: [String: FixtureHTTP.Outcome] = [:]
        for parent in 100..<112 { routes["/api/v1/statuses/\(parent)"] = .text(Self.status("\(parent)")) }
        let http = FixtureHTTP(routes)
        // What the last run wrote down: twelve replies a public timeline brought, each still
        // owing its load — and one Home brought, through a sign-in that is not here any more.
        var owing = (0..<12).map { index -> Note in
            var note = Note(
                id: "https://social.example/users/ada/statuses/\(index)", source: source, author: "Ada", handle: "@ada@social.example",
                body: "x", postedAt: Self.origin.addingTimeInterval(Double(index)), categories: [.public],
                reply: Reply(inReplyToId: "\(100 + index)"), statusID: "\(index)"
            )
            note.refsDue = true
            return note
        }
        var fromHome = reply("900", to: "901")
        fromHome.refsDue = true
        owing.append(fromHome)
        let work = SourceWork()
        work.govern(sources: [host])
        let session = ShellSession(http: http, store: ItemStore(sources: [source], notes: owing))
        session.work = work
        session.loads = LoadPacer(limits: Self.unpaced, clock: StillClock())
        await session.reloadFromStore()
        await session.refs.settled()
        #expect(await http.paths.count == ShellRefs.eager, "the launch's share, and no more")
        await session.reloadFromStore()
        #expect(session.notes.filter { $0.refsDue }.count == 2)
        #expect(session.notes.count == 23)
        #expect(session.notes.first { $0.statusID == "900" }?.refsDue == false, "with no sign-in there, what Home left owing is not asked for: it is dropped")
        #expect(await http.paths.allSatisfy { $0 != "/api/v1/statuses/901" })
    }

    @Test("A load whose item was let go while it waited its turn is taken back, and never asked")
    func takenBackWithItsItem() async throws {
        let http = GatedHTTP(
            ["/api/v1/statuses/1": .text(Self.status("1")), "/api/v1/statuses/3": .text(Self.status("3"))],
            holding: "/api/v1/statuses/3"
        )
        let guardTask = hangGuard(http.gate)
        defer { guardTask.cancel() }
        let (session, _, _) = try await shell(unsigned: http)
        // The newer reply is asked first, and held on the wire; the older waits behind it.
        var older = reply("2", to: "1"), newer = reply("4", to: "3")
        older = Note(id: older.id, source: source, author: "Ada", handle: older.handle, body: "x", postedAt: Self.origin.addingTimeInterval(-60), categories: [.home], reply: older.reply, statusID: "2")
        newer = Note(id: newer.id, source: source, author: "Ada", handle: newer.handle, body: "x", postedAt: Self.origin, categories: [.home], reply: newer.reply, statusID: "4")
        await session.store.ingest([older, newer], ifSourceHere: host)
        await session.reloadFromStore()
        await session.refs.asked()
        #expect(session.refs.count == 2)

        await session.store.forget(older.key)
        await session.reloadFromStore()
        await session.refs.asked()
        #expect(session.refs.count == 1)
        #expect(await session.loads.standing(host: host).waiting == 0)
        await http.gate.open()
        await session.refs.settled()
        #expect(await http.asks == 1, "only the load that was already on the wire was ever asked")
    }

    /// A client that answers every request with `status` and `headers`, as if from `answering`.
    private struct Answering: HTTPClient {
        let status: Int
        let headers: [String: String]
        var answering: String?
        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            let from = answering.map { URL(string: "https://\($0)\(url.path)")! } ?? url
            return (Data("[]".utf8), HTTPURLResponse(url: from, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }

    @Test("Only the source's own word about itself is heard: an answer to a read of its API from its own host — not a picture's, not one that came back from another host after a redirect")
    func whoseWordIsHeard() async throws {
        let (session, _, _) = try await shell()
        await session.refs.landed(in: session)
        let url = URL(string: "https://\(host)/api/v1/timelines/public")!
        let slow = ["Retry-After": "120"]
        func quiet() async -> TimeInterval? { await session.loads.standing(host: host).quietFor }

        _ = try await WatchedHTTP(Answering(status: 429, headers: slow), for: .picture, in: session.work).data(from: url)
        _ = try await WatchedHTTP(Answering(status: 429, headers: slow), for: .emoji, in: session.work).data(from: url)
        #expect(await quiet() == nil, "a picture's or an emoji's answer is not the source speaking of itself")
        _ = try await WatchedHTTP(Answering(status: 429, headers: slow, answering: "elsewhere.example"), for: .timeline, in: session.work).data(from: url)
        #expect(await quiet() == nil, "an answer that came back from another host is not the source's")
        _ = try await WatchedHTTP(Answering(status: 429, headers: slow), for: .timeline, in: session.work).data(from: url)
        #expect(await quiet() == 120)
        #expect(SourceWork.Purpose.allCases.filter(\.isOfTheSource) == [.timeline, .conversation, .lists, .signInCheck, .write, .search, .notices, .reference])
    }

    @Test("What any read of a source hears about how often it may be asked reaches that source's line of loads; another host's answer does not")
    func otherReadsAreHeard() async throws {
        let (session, _, _) = try await shell()
        await land([], in: session)
        await session.refs.landed(in: session)
        func response(_ status: Int, _ headers: [String: String], of host: String) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://\(host)/api/v1/timelines/home")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        await session.work.heard(response(200, [:], of: host), from: host)
        #expect(await session.loads.standing(host: host).quietFor == nil)
        await session.work.heard(response(429, ["Retry-After": "120"], of: host), from: host)
        #expect(await session.loads.standing(host: host).quietFor == 120)
        await session.work.heard(response(429, ["Retry-After": "120"], of: "cdn.example"), from: "cdn.example")
        #expect(await session.loads.standing(host: "cdn.example") == LoadStanding(), "not a source: it has no line")
    }
}
