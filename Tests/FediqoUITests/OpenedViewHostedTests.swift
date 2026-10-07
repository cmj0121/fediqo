#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #293, the opened view: opening an item shows what it refers to and what refers to it, from
/// what is held. Asked of the session — which rows, and what each says — and of the pane itself,
/// hosted off-screen, for where they are put: the line in the place of a post that is not here,
/// the rows under it, who reblogged, the posts that quote.
///
/// **What a hosted pane cannot say** — how it looks in light and dark, on a Mac and a phone,
/// under VoiceOver — is a running app's. Few layouts, one at a time: `FoldHostedTests`' reason.
@MainActor
@Suite("Opening an item shows what it refers to and what refers to it, hosted", .serialized)
struct OpenedViewHostedTests {
    private static let host = "social.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private static let threadPath = "/api/v1/statuses/9/context"
    /// One step of the pane's indentation.
    private static let step: CGFloat = 16

    private static func name(_ id: String) -> String { "https://\(host)/users/ada/statuses/\(id)" }

    /// A post as a public timeline brought it — so what it refers to is loaded with nobody
    /// signed in — or, through no category, as a search or a thread read brings one.
    private static func post(
        _ id: String, answering parent: String? = nil, quoting quoted: String? = nil,
        through categories: Set<FediqoCore.Category> = [.public]
    ) -> Note {
        Note(
            id: name(id), source: source, author: "Ada", handle: "@ada@\(host)", body: "post \(id)",
            postedAt: origin.addingTimeInterval(Double(id) ?? 0), categories: categories,
            reply: parent.map { Reply(handle: "@bob@\(host)", inReplyToId: $0) }, statusID: id,
            quote: quoted.map { Quote(state: .accepted, statusID: $0) }
        )
    }

    private static func reblog(of id: String, by who: String, at seconds: TimeInterval) -> Note {
        Note(
            id: "https://\(host)/users/\(who)/statuses/r\(id)-\(Int(seconds))/activity", source: source, author: who.capitalized,
            handle: "@\(who)@\(host)", body: "", postedAt: origin.addingTimeInterval(seconds), categories: [.public],
            statusID: "r\(who)", refs: [Reference(kind: .reblogs, id: name(id), statusID: id)]
        )
    }

    /// Post `id` as its source sends it when it is asked for by itself.
    private static func status(_ id: String, answering parent: String? = nil, in year: Int = 2023) -> String {
        let answering = parent.map { #""in_reply_to_id":"\#($0)","# } ?? ""
        return """
        {"id":"\(id)","uri":"\(name(id))",\(answering)
         "created_at":"\(year)-11-01T00:00:00.000Z","content":"<p>post \(id)</p>","visibility":"public",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static func context(ancestors: [String] = [], descendants: [String] = []) -> FixtureHTTP.Outcome {
        .text(#"{"ancestors":["# + ancestors.joined(separator: ",") + #"],"descendants":["#
            + descendants.joined(separator: ",") + "]}")
    }

    /// A session on one Mastodon with nobody signed in, whose loads wait on nothing but the wire.
    private static func shell(_ http: any HTTPClient) async -> ShellSession {
        let store = ItemStore()
        await store.add(source)
        let work = SourceWork()
        work.govern(sources: [host])
        let session = ShellSession(http: http, store: store, posts: ForumPosts(http: FixtureHTTP()))
        session.work = work
        var limits = LoadLimits()
        limits.interval = 0
        limits.backoff = 0
        session.loads = LoadPacer(limits: limits, clock: StillClock())
        await session.reloadFromStore()
        return session
    }

    /// Lands `notes` as a read does, and waits for every load that takes to end and land.
    private static func land(_ notes: [Note], in session: ShellSession) async {
        await session.store.ingest(notes, ifSourceHere: host)
        await session.reloadFromStore()
        await session.refs.settled()
        await session.reloadFromStore()
    }

    /// The row of post `id` as the timeline holds it, and its pane opened as the app opens it.
    private static func open(_ id: String, in session: ShellSession) async throws -> DummyItem {
        let item = try #require(session.held(NoteKey(host: host, id: name(id)).rowID))
        await session.reload.opened(item, in: session)
        return item
    }

    private static func drawn(_ id: String, in session: ShellSession) throws -> DummyConversation {
        session.conversations.conversation(around: try #require(session.held(NoteKey(host: host, id: name(id)).rowID)))
    }

    private struct Host: View {
        let session: ShellSession
        let root: DummyItem
        let probe: ThreadPaneProbe
        @State private var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()

        var body: some View {
            DummyThreadPane(
                root: root, catalogues: session.emoji, posts: session.posts, conversations: session.conversations,
                selectedID: $selected, decks: $decks, playback: playback,
                onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { _ in },
                onOpenPerson: { _ in }, jumpToTop: 0, onBack: {}, probe: probe
            )
        }
    }

    /// The pane of post `id` laid out afresh, tall enough that every row is drawn: where each
    /// part of it was put, by the post's number.
    private static func laid(_ id: String, in session: ShellSession) async throws -> (ThreadPaneProbe, (String) -> CGRect?) {
        let root = try #require(session.held(NoteKey(host: host, id: name(id)).rowID))
        let probe = ThreadPaneProbe()
        let view = NSHostingView(rootView: Host(session: session, root: root, probe: probe))
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 2_400)
        for _ in 0..<3 {
            pump(view)
            await Task.yield()
        }
        return (probe, { probe.frames[.row(NoteKey(host: host, id: name($0)).rowID)] })
    }

    /// A layout and one turn of the run loop that does not wait — a synchronous hop, since the
    /// run loop may not be turned from an async context.
    private static func pump(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date())
    }

    private static func said(_ missing: QuoteBand.Loading?, _ language: DummyLanguage = .english) -> String? {
        missing.map { L10n.t($0.aboveKey, language: language) }
    }

    // MARK: - What it refers to

    @Test("A chain of answers partly held: what it answers and what that answers stand above it, as far as held items go, and where the next is on its way a line says so in its place; when it arrives its row takes the line's place and no row under it moves")
    func aChainPartlyHeldThenArriving() async throws {
        let http = GatedHTTP([
            "/api/v1/statuses/6": .text(Self.status("6", answering: "5")), Self.threadPath: .fail,
        ], holding: "/api/v1/statuses/6")
        let guardTask = hangGuard(http.gate)
        defer { guardTask.cancel() }
        let session = await Self.shell(http)
        await session.store.ingest(
            [Self.post("7", answering: "6"), Self.post("8", answering: "7"), Self.post("9", answering: "8")],
            ifSourceHere: Self.host
        )
        await session.reloadFromStore()
        await session.refs.asked()
        _ = try await Self.open("9", in: session)

        let waiting = try Self.drawn("9", in: session)
        #expect(waiting.ancestors.map(\.statusID) == ["7", "8"], "the start first; nothing above 7 is held")
        #expect(waiting.missing == .onItsWay)
        #expect(Self.said(waiting.missing) == "The post this answers is on its way")
        #expect(Self.said(waiting.missing, .taiwanese) == "這則回覆的那則貼文還在路上")
        // Said once: above the row, and the row says only whom it answers. In a timeline the
        // same post's row still says it, there being no place above it there.
        let first = try #require(waiting.ancestors.first)
        #expect(DummyItemRow.replyLine(first, language: .english) == "Reply to @bob@\(Self.host)")
        let inTimeline = try #require(session.held(first.id))
        #expect(DummyItemRow.replyLine(inTimeline, language: .english) == "Reply to @bob@\(Self.host) — that post is on its way")
        #expect(waiting.inOrder.map(\.statusID) == ["7", "8", "9"], "the keys walk the rows, and the line is no row")
        #expect(await http.requested().allSatisfy { !$0.hasSuffix("/statuses/5") }, "nothing is asked for by walking up")

        let (probe, row) = try await Self.laid("9", in: session)
        let line = try #require(probe.frames[.above]), seven = try #require(row("7"))
        #expect(line.maxY <= seven.minY + 0.5, "the line is where the post would stand: above the first row")
        #expect(line.minX < Self.step, "at the first step")
        #expect(seven.minX == Self.step && row("8")?.minX == 2 * Self.step && row("9")?.minX == 3 * Self.step)

        await http.gate.open()
        await session.refs.settled()
        await session.reloadFromStore()
        let arrived = try Self.drawn("9", in: session)
        #expect(arrived.ancestors.map(\.statusID) == ["6", "7", "8"])
        #expect(arrived.missing == nil, "what 6 answers in turn was never asked for, and nothing is said of it")
        #expect(await http.requested().allSatisfy { !$0.hasSuffix("/statuses/5") })
        let (after, placed) = try await Self.laid("9", in: session)
        #expect(after.frames[.above] == nil)
        #expect(placed("6")?.minX == 0, "the post, where the line was")
        #expect(placed("7")?.minX == seven.minX && placed("9")?.minX == 3 * Self.step, "and no row under it moved in or out")
    }

    @Test("A post that was loaded for it and since let go: the line in its place says it is no longer held, and the post under it stands one step in")
    func aParentNoLongerHeld() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/8": .text(Self.status("8")), Self.threadPath: .fail])
        let session = await Self.shell(http)
        await Self.land([Self.post("9", answering: "8")], in: session)
        _ = try await Self.open("9", in: session)
        let held = try Self.drawn("9", in: session)
        #expect(held.ancestors.map(\.statusID) == ["8"] && held.missing == nil)

        let parent = try #require(session.notes.first { $0.statusID == "8" })
        await session.store.forget(parent.key)
        await session.reloadFromStore()
        let after = try Self.drawn("9", in: session)
        #expect(after.ancestors.isEmpty && after.missing == .unheld)
        #expect(Self.said(after.missing) == "The post this answers is no longer held")
        #expect(Self.said(after.missing, .taiwanese) == "這則回覆的那則貼文已不再留著")
        #expect(DummyItemRow.replyLine(after.post, language: .english) == "Reply to @bob@\(Self.host)")
        #expect(await http.paths.filter { $0 == "/api/v1/statuses/8" }.count == 1, "and it is not asked for again")

        let (probe, row) = try await Self.laid("9", in: session)
        let line = try #require(probe.frames[.above]), nine = try #require(row("9"))
        #expect(line.maxY <= nine.minY + 0.5 && nine.minX == Self.step)
    }

    @Test("A post its source says is gone, and one that could not be read this run: the line in its place says which", arguments: [
        (FixtureHTTP.Outcome.text("{}", status: 404), "The post this answers is gone or hidden at its source", "這則回覆的那則貼文在來源已消失或不公開"),
        (FixtureHTTP.Outcome.fail, "The post this answers could not be read for now", "這則回覆的那則貼文暫時讀不到"),
    ])
    func goneAndNotReadForNow(answer: FixtureHTTP.Outcome, english: String, taiwanese: String) async throws {
        let session = await Self.shell(FixtureHTTP(["/api/v1/statuses/8": answer, Self.threadPath: .fail]))
        await Self.land([Self.post("9", answering: "8")], in: session)
        _ = try await Self.open("9", in: session)
        let drawn = try Self.drawn("9", in: session)
        #expect(drawn.ancestors.isEmpty && drawn.inOrder.map(\.statusID) == ["9"])
        #expect(Self.said(drawn.missing) == english)
        #expect(Self.said(drawn.missing, .taiwanese) == taiwanese)
        #expect(DummyItemRow.replyLine(drawn.post, language: .english) == "Reply to @bob@\(Self.host)")
    }

    @Test("A post that answers nothing has no line above it, and stands at the first step")
    func nothingToSayAbove() async throws {
        let session = await Self.shell(FixtureHTTP([Self.threadPath: .fail]))
        await Self.land([Self.post("9")], in: session)
        _ = try await Self.open("9", in: session)
        #expect(try Self.drawn("9", in: session).missing == nil)
        let (probe, row) = try await Self.laid("9", in: session)
        #expect(probe.frames[.above] == nil && row("9")?.minX == 0)
    }

    // MARK: - What refers to it

    @Test("A quote: the post it quotes is read off its reference into the row itself, and the held posts that quote the opened one stand after its answers under their own title; who reblogged it is one line under it, the latest first, and no row")
    func quotesAndReblogs() async throws {
        let http = FixtureHTTP(["/api/v1/statuses/5": .text(Self.status("5")), Self.threadPath: .fail])
        let session = await Self.shell(http)
        await Self.land([
            Self.post("9", quoting: "5"), Self.post("10", answering: "9"), Self.post("20", quoting: "9"),
            Self.reblog(of: "9", by: "bob", at: 50), Self.reblog(of: "9", by: "cyd", at: 90),
            Self.reblog(of: "9", by: "bob", at: 95), Self.reblog(of: "10", by: "dee", at: 60),
        ], in: session)
        _ = try await Self.open("9", in: session)

        let drawn = try Self.drawn("9", in: session)
        #expect(QuoteBand.Loading(drawn.post) == nil, "the quoted post was loaded, and its place in the row says nothing else")
        #expect(session.notes.contains { $0.statusID == "5" }, "held, an item like any other")
        #expect(drawn.ancestors.isEmpty, "a quote is not what a post answers: it is drawn in the post, not above it")
        #expect(drawn.descendants.map(\.item.statusID) == ["10"])
        #expect(drawn.quoting.map(\.statusID) == ["20"])
        #expect(drawn.inOrder.map(\.statusID) == ["9", "10", "20"], "a post that quotes it is a row the keys reach")
        #expect(drawn.rebloggers == ["Bob", "Cyd"], "each person once, by their latest reblog; a reblog of another post is not of this one")
        #expect(DummyThreadPane.rebloggedLine(drawn.rebloggers, language: .english) == "Reblogged by Bob, Cyd")
        #expect(DummyThreadPane.rebloggedLine(["A", "B", "C", "D", "E"], language: .english) == "Reblogged by A, B, C and 2 more")
        #expect(DummyThreadPane.rebloggedLine(["A", "B", "C", "D"], language: .taiwanese) == "由 A、B、C 和另外 1 人轉發")
        #expect(DummyThreadPane.rebloggedLine([], language: .english) == nil)
        #expect(L10n.t("thread.quoting.title", language: .english) == "Posts that quote this one")
        #expect(L10n.t("thread.quoting.title", language: .taiwanese) == "引用這則的貼文")

        let (probe, row) = try await Self.laid("9", in: session)
        let nine = try #require(row("9")), ten = try #require(row("10")), twenty = try #require(row("20"))
        let reblogged = try #require(probe.frames[.reblogged]), title = try #require(probe.frames[.quoting])
        #expect(nine.maxY <= reblogged.minY + 0.5 && reblogged.maxY <= ten.minY + 0.5, "under the post, over its answers")
        #expect(ten.maxY <= title.minY + 0.5 && title.maxY <= twenty.minY + 0.5, "after the answers, under their title")
        #expect(ten.minX == Self.step && twenty.minX == Self.step)
        let rows = probe.frames.keys.filter { part in
            if case .row = part { return true }
            return false
        }
        #expect(rows.count == 3, "no reblog is drawn as a row")
    }

    @Test("Answers held from a search and from a timeline, with no thread read: they stand under what they answer, each one deeper, though the source's own answer was that the post is alone; one a search brings while the pane is up takes its place")
    func answersHeldWithoutAThreadRead() async throws {
        let http = FixtureHTTP([Self.threadPath: Self.context()])
        let session = await Self.shell(http)
        await Self.land([
            Self.post("9"), Self.post("10", answering: "9", through: []), Self.post("12", answering: "10", through: []),
        ], in: session)
        _ = try await Self.open("9", in: session)
        #expect(session.conversations.standing(of: try Self.drawn("9", in: session).post.id) == ShellConversationStanding.none)
        #expect(try Self.drawn("9", in: session).descendants.map(\.item.statusID) == ["10", "12"])
        #expect(try Self.drawn("9", in: session).descendants.map(\.depth) == [1, 2])

        await Self.land([Self.post("11", answering: "9", through: [])], in: session)
        #expect(try Self.drawn("9", in: session).descendants.map(\.item.statusID) == ["10", "12", "11"])
        let (_, row) = try await Self.laid("9", in: session)
        #expect(row("10")?.minX == Self.step && row("12")?.minX == 2 * Self.step && row("11")?.minX == Self.step)
        #expect(await http.paths == [Self.threadPath], "one read of the thread, by the reader opening it, and nothing else")
    }

    @Test("An answer the thread's read brought whose own parent the source did not hand over stands at the first step under the post, with a line above it saying it answers a post not held here; its own answer stands under it; the thread is not said to be cut; and with the read forgotten it has no place, and is held all the same")
    func anAnswerToAPostNotHandedOver() async throws {
        let http = FixtureHTTP([Self.threadPath: Self.context(descendants: [
            Self.status("10", answering: "9"), Self.status("12", answering: "5"), Self.status("13", answering: "12"),
        ])])
        let session = await Self.shell(http)
        await Self.land([Self.post("9", through: [])], in: session)
        let item = try await Self.open("9", in: session)
        let drawn = try Self.drawn("9", in: session)
        #expect(drawn.descendants.map(\.item.statusID) == ["10", "12", "13"])
        #expect(drawn.descendants.map(\.depth) == [1, 1, 2])
        // It arrived owing the post it answers (#293), so that is what the line says of it; one
        // that owes nothing says only that the post is not here.
        #expect(drawn.descendants.map(\.aboveKey) == [nil, "thread.above.onItsWay", nil])
        var settled = Opened()
        settled.below = [Self.post("12", answering: "5", through: [])]
        settled.loose = [settled.below[0].key]
        #expect(DummyConversation.opened(item, settled).descendants.map(\.aboveKey) == ["thread.above.notHere"])
        settled.below = [Self.post("12", through: [])]
        #expect(DummyConversation.opened(item, settled).descendants.map(\.aboveKey) == [nil], "one that answers nothing has no line")
        #expect(DummyItemRow.replyLine(drawn.descendants[1].item, language: .english) == "A reply")
        #expect(L10n.t("thread.above.notHere", language: .english) == "Answers a post not held here")
        #expect(L10n.t("thread.above.notHere", language: .taiwanese) == "回覆的那則貼文不在這裡")
        #expect(session.conversations.further(of: item.id) == .end, "everything the source handed over is drawn")
        #expect(await http.paths == [Self.threadPath], "the thread, and nothing by walking")

        let (probe, row) = try await Self.laid("9", in: session)
        let twelve = try #require(row("12")), ten = try #require(row("10"))
        let line = try #require(probe.frames[.aboveRow(drawn.descendants[1].item.id)])
        #expect(ten.maxY <= line.minY + 0.5 && line.maxY <= twelve.minY + 0.5, "the line is over the answer, under the row before it")
        #expect(twelve.minX == Self.step && row("13")?.minX == 2 * Self.step)
        let lines = probe.frames.keys.filter { part in
            if case .aboveRow = part { return true }
            return false
        }
        #expect(lines.count == 1)

        // What a source handed over as one thread is this run's to know: forgotten, as at a
        // relaunch with the network off, the answer has no place here. It is held all the same.
        session.conversations.clear()
        await session.conversations.redraw(item, in: session)
        #expect(try Self.drawn("9", in: session).descendants.map(\.item.statusID) == ["10"])
        let held = await session.store.all().map(\.statusID)
        #expect(held.contains("12"))
    }

    @Test("A post only a thread's read brought, older than the reader keeps, opened from there: what belongs with it is laid around the copy the thread drew; and two people who reblogged with no handle are two")
    func aRootNotHeldAndRebloggersWithNoHandle() async throws {
        let http = FixtureHTTP([Self.threadPath: Self.context(
            ancestors: [Self.status("8", in: 2021)], descendants: [Self.status("10", answering: "9", in: 2021)]
        ), "/api/v1/statuses/8/context": .fail])
        let session = await Self.shell(http)
        await Self.land([Self.post("9", answering: "8", through: [])], in: session)
        _ = await session.store.setRetention(months: 1, from: Self.origin.addingTimeInterval(86_400))
        await session.reloadFromStore()
        _ = try await Self.open("9", in: session)
        let eight = try #require(try Self.drawn("9", in: session).ancestors.first)
        #expect(session.heldNote(eight.id) == nil)
        await session.reload.opened(eight, in: session)
        #expect(session.conversations.conversation(around: eight).inOrder.map(\.statusID) == ["8", "9", "10"])

        func nameless(_ author: String, _ seconds: TimeInterval) -> Note {
            Note(
                id: "https://\(Self.host)/users/x/statuses/r\(Int(seconds))/activity", source: Self.source, author: author,
                handle: "", body: "", postedAt: Self.origin.addingTimeInterval(seconds), categories: [],
                statusID: "r\(Int(seconds))", refs: [Reference(kind: .reblogs, id: Self.name("9"), statusID: "9")]
            )
        }
        var opened = Opened()
        opened.reblogs = [nameless("Bob", 3), nameless("Cyd", 2), nameless("Bob", 1)]
        let root = try #require(session.held(NoteKey(host: Self.host, id: Self.name("9")).rowID))
        #expect(DummyConversation.opened(root, opened).rebloggers == ["Bob", "Cyd"])
    }

    @Test("Opened from an answer to a post the source will not show: the posts the read said stand above are drawn first, then a line in the withheld post's place, then the answer one step in from it; the keys walk them; and with the read forgotten only what references reach is drawn")
    func aboveAPostNotHandedOver() async throws {
        // The start (8), a post withheld (5), the answer to it (9), and an answer to that (10).
        // Asked for by itself, the withheld post answers as a post that is not there does.
        let http = FixtureHTTP([Self.threadPath: Self.context(
            ancestors: [Self.status("8")], descendants: [Self.status("10", answering: "9")]
        ), "/api/v1/statuses/5": .text(#"{"error":"Not Found"}"#, status: 404)])
        let session = await Self.shell(http)
        await Self.land([Self.post("9", answering: "5", through: [])], in: session)
        let item = try await Self.open("9", in: session)
        let drawn = try Self.drawn("9", in: session)
        #expect(drawn.gapKey == "thread.above.gone", "what is known of the post in between: gone or hidden at its source")
        // Where nothing is known of it, the line says only that it is not here.
        var plain = Opened()
        plain.beyond = [Self.post("8")]
        #expect(DummyConversation.opened(DummyItem(Self.post("9", answering: "5")), plain).gapKey == "thread.above.notHere")
        #expect(DummyConversation.opened(DummyItem(Self.post("9", answering: "5")), Opened()).gapKey == nil)
        #expect(drawn.beyond.map(\.statusID) == ["8"] && drawn.ancestors.isEmpty)
        #expect(drawn.inOrder.map(\.statusID) == ["8", "9", "10"])
        #expect(drawn.gapKey != nil && drawn.lead == 2)
        #expect(drawn.depth(of: drawn.beyond[0].id) == 0 && drawn.depth(of: item.id) == 2)
        #expect(DummyItemRow.replyLine(drawn.post, language: .english) == "Reply to @bob@\(Self.host)", "said once, in the line")
        #expect(await http.paths.sorted() == ["/api/v1/statuses/5", Self.threadPath], "the one post it answers, once; nothing is asked by walking")

        let (probe, row) = try await Self.laid("9", in: session)
        let start = try #require(row("8")), line = try #require(probe.frames[.above]), answer = try #require(row("9"))
        #expect(start.minX == 0 && start.maxY <= line.minY + 0.5 && line.maxY <= answer.minY + 0.5, "the start, the line, the answer")
        #expect(line.minX == Self.step, "the line where the withheld post would stand")
        #expect(answer.minX == 2 * Self.step && row("10")?.minX == 3 * Self.step)

        // What a source handed over as one thread is this run's to know: forgotten, as at a
        // relaunch with the network off, the start has no place above. It is held all the same.
        session.conversations.clear()
        await session.conversations.redraw(item, in: session)
        let after = try Self.drawn("9", in: session)
        #expect(after.beyond.isEmpty && after.inOrder.map(\.statusID) == ["9", "10"])
        let held = await session.store.all().map(\.statusID)
        #expect(held.contains("8"))
    }

    @Test("Offline: the view is exactly what references and held items give — above, below, each in its place — and the foot says the rest did not arrive; a post with nothing held around it says the thread could not be had")
    func offline() async throws {
        let http = FixtureHTTP([Self.threadPath: .fail, "/api/v1/statuses/30/context": .fail])
        let session = await Self.shell(http)
        await Self.land([
            Self.post("8"), Self.post("9", answering: "8"), Self.post("10", answering: "9"),
            Self.post("11", answering: "10"), Self.post("30"),
        ], in: session)
        let item = try await Self.open("9", in: session)
        let drawn = try Self.drawn("9", in: session)
        #expect(drawn.inOrder.map(\.statusID) == ["8", "9", "10", "11"])
        #expect(drawn.descendants.map(\.depth) == [1, 2] && drawn.missing == nil)
        #expect(session.conversations.standing(of: item.id) == .loaded(rootID: "9"))
        #expect(session.conversations.further(of: item.id) == .failed(.unreachable))
        #expect(await http.paths == [Self.threadPath], "the reader's own ask, once, and no load: nothing here refers to a post not held")
        let (_, row) = try await Self.laid("9", in: session)
        #expect(row("8")?.minX == 0 && row("9")?.minX == Self.step && row("11")?.minX == 3 * Self.step)

        let alone = try await Self.open("30", in: session)
        #expect(session.conversations.standing(of: alone.id) == .absent(.unreachable))
        #expect(try Self.drawn("30", in: session).inOrder.map(\.statusID) == ["30"])
    }

    @Test("A thread read brings posts older than the reader keeps: they are drawn for this run by what they answer, and are not held")
    func olderThanIsKept() async throws {
        let http = FixtureHTTP([Self.threadPath: Self.context(
            ancestors: [Self.status("8", in: 2021)], descendants: [Self.status("10", answering: "9", in: 2021)]
        )])
        let session = await Self.shell(http)
        await Self.land([Self.post("9", answering: "8", through: [])], in: session)
        // Kept from a month before the post on: what the thread read brings is from 2021, older
        // than that, and the store refuses it.
        _ = await session.store.setRetention(months: 1, from: Self.origin.addingTimeInterval(86_400))
        await session.reloadFromStore()
        _ = try await Self.open("9", in: session)
        #expect(try Self.drawn("9", in: session).inOrder.map(\.statusID) == ["8", "9", "10"])
        #expect(session.notes.map(\.statusID) == ["9"], "only the post the reader keeps is held")
        await session.reloadFromStore()
        #expect(try Self.drawn("9", in: session).inOrder.map(\.statusID) == ["8", "9", "10"], "and they stay drawn as the store is read again")
    }
}
#endif
