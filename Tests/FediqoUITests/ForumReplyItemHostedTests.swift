#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #297 through the session and the pane: a forum topic's replies, read when the topic is opened,
/// stand in the timelines where the forum dated them; pressing one there opens its topic with
/// that reply in view.
///
/// Hosted for where the pane draws a reply and under which id. **What a hosted pane cannot say**
/// — that the scroll came to rest on it, how the lit reply looks in light and dark, on a Mac and
/// a phone — is a running app's.
@MainActor
@Suite("A forum's replies stand in the timelines where the forum dates them, hosted", .serialized)
struct ForumReplyItemHostedTests {
    private static let host = "forum.test"
    private static let forum = Source(host: host, kind: .discuz, boards: [BoardSubscription(fid: 2, name: "Dev")])
    private static let tid = 7
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private static let topicID = "discuz:\(host):\(tid)"

    private static let topic = Note(
        id: topicID, source: forum, author: "tinbox", handle: "tinbox@\(host)", body: "", title: "A topic",
        postedAt: origin, categories: [.board(id: "2")]
    )

    private static func post(_ pid: Int, dated minutes: Double?, words: String? = nil) -> DiscuzPost {
        DiscuzPost(
            pid: pid, tid: tid, floor: pid, author: "p\(pid)", handle: "p\(pid)@\(host)",
            postedAt: minutes.map { origin.addingTimeInterval($0 * 60) }, body: words ?? "reply \(pid)", page: 1
        )
    }

    private static func rowID(_ pid: Int) -> String {
        NoteKey(host: host, id: "\(topicID):post:\(pid)").rowID
    }

    /// A session holding the topic, with its replies read as opening the topic reads them.
    private static func shell(_ replies: [DiscuzPost], holdingTopic: Bool = true) async -> ShellSession {
        let store = ItemStore(sources: [forum], notes: holdingTopic ? [topic] : [])
        let http = FixtureHTTP()
        let session = ShellSession(http: http, store: store, posts: ForumPosts(http: http))
        await session.reloadFromStore()
        _ = await session.land(replies, host: host, tid: tid)
        await session.reloadFromStore()
        return session
    }

    @Test("Opening a topic and reading its replies: each dated reply stands in All at the time the forum gave it and none at the time it was read; one with no date is in no timeline and no search, and is still there when the topic is opened; what the device holds counts each once")
    func readAndCounted() async throws {
        let before = Date()
        let session = await Self.shell([Self.post(2, dated: 10), Self.post(3, dated: nil), Self.post(4, dated: 5, words: "about cats")])
        #expect(session.timelineItems(latest: nil).map(\.id) == [Self.rowID(2), Self.rowID(4), Self.topic.key.rowID], "newest first, each at the forum's time")
        let dated = try #require(session.heldNote(Self.rowID(2)))
        #expect(dated.postedAt == Self.origin.addingTimeInterval(600) && dated.postedAt < before)
        #expect(dated.categories == [.board(id: "2")])
        #expect(session.heldNote(Self.rowID(3)) == nil)
        #expect(session.heldReplies.map(\.key.rowID) == [Self.rowID(3)])
        #expect(session.holdings.posts == 4 && session.holdings.posts(host: Self.host) == 4, "the topic and three replies, each once")
        #expect(session.notes.count + session.heldReplies.count == 4)

        let cats = try #require(NoteSearch("cats", sources: session.sources))
        #expect(cats.found(session.notes, SearchIndex(session.notes)).map(\.key.rowID) == [Self.rowID(4)], "a dated reply is found by its words")
        let none = try #require(NoteSearch("reply 3", sources: session.sources))
        #expect(none.found(session.notes, SearchIndex(session.notes)).isEmpty)

        // Where the topic is opened, every reply is there, dated or not, in the page's order.
        #expect(await session.keptReplies(host: Self.host, tid: Self.tid).map(\.pid) == [2, 3, 4])

        // A rule on the topic's board shows the dated replies with the topic.
        let board = try #require(Rule.category(.board(id: "2"), in: .source(host: Self.host), sources: session.sources))
        let timeline = TimelineDefinition(name: "Dev", rules: [board])
        session.written = [timeline]
        session.timelineID = .written(timeline.id)
        #expect(Set(session.timelineItems(latest: nil).map(\.id)) == [Self.rowID(2), Self.rowID(4), Self.topic.key.rowID])
    }

    @Test("A reply read again, on a page that gives no date this time, is still the item the forum dated; one dated only on a later read becomes an item then")
    func readAgain() async throws {
        let session = await Self.shell([Self.post(2, dated: 10), Self.post(3, dated: nil)])
        _ = await session.land([Self.post(2, dated: nil, words: "reply 2, edited"), Self.post(3, dated: 20)], host: Self.host, tid: Self.tid)
        await session.reloadFromStore()
        let two = try #require(session.heldNote(Self.rowID(2)))
        #expect(two.postedAt == Self.origin.addingTimeInterval(600) && two.opening?.words == "reply 2, edited")
        #expect(session.heldNote(Self.rowID(3))?.postedAt == Self.origin.addingTimeInterval(1200))
        #expect(session.heldReplies.isEmpty)
        #expect(session.holdings.posts == 3)
    }

    @Test("A reply's row in a timeline says it is a reply, and a press to open it opens its topic; with the topic not held it opens nothing; the topic's own row opens itself")
    func theRowOpensItsTopic() async throws {
        let session = await Self.shell([Self.post(2, dated: 10)])
        let row = try #require(session.held(Self.rowID(2)))
        #expect(row.answering == .somebody && row.body == "reply 2")
        #expect(DummyItemRow.replyLine(row, language: .english) == "A reply")
        #expect(session.rowOpened(by: Self.rowID(2)) == Self.topic.key.rowID)
        #expect(session.rowOpened(by: Self.topic.key.rowID) == Self.topic.key.rowID)
        #expect(ForumThreadRef(row) == nil, "its row is no topic: nothing is fetched for it as one")

        let orphaned = await Self.shell([Self.post(2, dated: 10)], holdingTopic: false)
        #expect(orphaned.heldNote(Self.rowID(2)) != nil)
        #expect(orphaned.rowOpened(by: Self.rowID(2)) == nil)
        let line = DummyItemRow.replyLine(try #require(orphaned.held(Self.rowID(2))), language: .english)
        #expect(line == "A reply — that post is no longer held")
    }

    private struct Host: View {
        let session: ShellSession
        let root: DummyItem
        let probe: ThreadPaneProbe
        @State var selected: String?
        @State private var decks = ShellDecks()
        @State private var playback = ShellPlayback()

        var body: some View {
            DummyThreadPane(
                root: root, catalogues: session.emoji, posts: session.posts, conversations: session.conversations,
                selectedID: $selected, decks: $decks, playback: playback,
                onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { _ in },
                onOpenPerson: { _ in }, jumpToTop: 0, onToast: { _ in }, onBack: {}, probe: probe
            )
        }
    }

    private static func pump(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date())
    }

    @Test("The topic opened from a reply's row draws that reply under the id its timeline row has, so it is the one found and brought into view — once the replies are drawn, and not before")
    func theReplyIsInTheTopic() async throws {
        let session = await Self.shell([Self.post(2, dated: 10), Self.post(3, dated: nil), Self.post(4, dated: 5)])
        let opened = try #require(session.rowOpened(by: Self.rowID(4)))
        let root = try #require(session.held(opened))
        let thread = try #require(ForumThreadRef(root))
        #expect(DummyThreadPane.replyInView(selected: Self.rowID(4), of: thread, among: []) == nil, "not drawn yet")

        await session.reload.opened(root, in: session)
        guard case .loaded(let replies) = session.posts.standing(of: thread) else {
            Issue.record("the kept replies are drawn as the topic opens")
            return
        }
        #expect(replies.map(\.pid) == [2, 3, 4])
        #expect(DummyThreadPane.replyInView(selected: Self.rowID(4), of: thread, among: replies) == Self.rowID(4))
        #expect(DummyThreadPane.replyInView(selected: root.id, of: thread, among: replies) == nil, "the topic's own row is not a reply to bring into view")
        #expect(DummyThreadPane.replyInView(selected: Self.rowID(9), of: thread, among: replies) == nil)
        #expect(DummyThreadPane.replyInView(selected: Self.rowID(4), of: nil, among: replies) == nil)
        #expect(replies.map { DummyThreadPane.rowID(of: $0, in: thread) } == [Self.rowID(2), Self.rowID(3), Self.rowID(4)])

        let probe = ThreadPaneProbe()
        let view = NSHostingView(rootView: Host(session: session, root: root, probe: probe, selected: Self.rowID(4)))
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 2_400)
        for _ in 0..<3 {
            Self.pump(view)
            await Task.yield()
        }
        let topic = try #require(probe.frames[.row(root.id)])
        let frames = try [2, 3, 4].map { try #require(probe.frames[.row(Self.rowID($0))], "reply \($0) is drawn under its own row's id") }
        #expect(topic.maxY <= frames[0].minY + 0.5)
        #expect(frames[0].maxY <= frames[1].minY + 0.5 && frames[1].maxY <= frames[2].minY + 0.5, "in the page's order, dated or not")
    }
}
#endif
