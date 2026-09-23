import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #198: an opened post reads its thread at once, and the thread renews itself on this device's
/// one wait while it stays open — landed in the store first, drawn from what the store holds,
/// said at its own foot, and ended as the thread is left.
@MainActor
@Suite("An open thread renews itself")
struct ThreadRenewsTests {
    init() {
        L10n.language = .english
    }

    // MARK: - A forum topic

    private static let forum = "install-c.example"
    private static let tid = 70241

    private static func page(_ number: Int) -> String {
        let page = number > 1 ? "&page=\(number)" : ""
        return "https://\(forum)/forum.php?mod=viewthread&tid=\(tid)\(page)&mobile=2"
    }

    private static func post(_ pid: Int, floor: Int? = nil, words: String? = nil) -> String {
        """
        <div class="plc" id="pid\(pid)">
          <ul class="authi"><li class="mtit">\(floor ?? pid)<sup>#</sup></li><li><a href="home.php?mod=space&amp;uid=\(pid)">p\(pid)</a></li></ul>
          <div class="message">\(words ?? "第 \(pid) 帖")</div>
        </div>
        """
    }

    /// One page: the opening post and two replies, pointing nowhere.
    private static let onePage: [String: FixtureHTTP.Outcome] = [
        page(1): .text(post(1, floor: 1) + post(2) + post(3)),
    ]

    private static var ref: ForumThreadRef { ForumThreadRef(host: forum, tid: tid) }

    private func forumShell(_ http: any HTTPClient, store: ItemStore? = nil) async -> (ShellSession, DummyItem) {
        let store = store ?? ItemStore()
        await store.add(Source(host: Self.forum, kind: .discuz))
        let topic = Note(
            id: "discuz:\(Self.forum):\(Self.tid)", source: Source(host: Self.forum, kind: .discuz),
            author: "tinbox", handle: "@tinbox@\(Self.forum)", body: "", title: "一个主题",
            postedAt: Date(timeIntervalSince1970: 0), categories: [.public]
        )
        await store.ingest([topic])
        let session = ShellSession(http: http, store: store, posts: ForumPosts(http: http))
        await session.reloadFromStore()
        return (session, DummyItem(topic))
    }

    private static func pids(_ session: ShellSession) -> [Int] {
        guard case .loaded(let posts) = session.posts.standing(of: ref) else { return [] }
        return posts.map(\.pid)
    }

    private static func pageAsks(_ http: Changing) async -> Int {
        await http.requested.filter { $0.absoluteString == page(1) }.count
    }

    // MARK: - A Mastodon conversation

    private static let host = "one.example"
    private static let threadPath = "/api/v1/statuses/9/context"

    private static func status(_ id: String, answering parent: String, words: String? = nil) -> String {
        """
        {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)","in_reply_to_id":"\(parent)",
         "created_at":"2024-01-01T00:00:00.000Z","content":"<p>\(words ?? "answer \(id)")</p>",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static func context(_ descendants: [String]) -> FixtureHTTP.Outcome {
        .text(#"{"ancestors":[],"descendants":["# + descendants.joined(separator: ",") + "]}")
    }

    private static let twoAnswers = context([status("10", answering: "9"), status("11", answering: "9")])

    private static let root = Note(
        id: "https://\(host)/users/ada/statuses/9", source: Source(host: host, kind: .mastodon),
        author: "Ada", handle: "@ada@\(host)", body: "the post",
        postedAt: Date(timeIntervalSince1970: 0), categories: [.public], statusID: "9"
    )

    private func conversationShell(_ http: any HTTPClient, store: ItemStore? = nil) async -> (ShellSession, DummyItem) {
        let store = store ?? ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        await store.ingest([Self.root])
        let session = ShellSession(http: http, store: store, posts: ForumPosts(http: http))
        await session.reloadFromStore()
        return (session, DummyItem(Self.root))
    }

    private static func bodies(_ session: ShellSession, _ item: DummyItem) -> [String] {
        session.conversations.conversation(around: item).descendants.map(\.item.body)
    }

    private static func threadAsks(_ http: Changing) async -> Int {
        await http.requested.filter { $0.path == threadPath }.count
    }

    /// One pass of the wait: slept once, asked, and the loop let go at the next sleep.
    private func oneWait(_ session: ShellSession, before: (() async -> Void)? = nil) async {
        var waits = 0
        await session.reload.keepAsking(every: .seconds(60), in: session) { _ in
            waits += 1
            if waits == 1 { await before?() }
            if waits > 1 { throw CancellationError() }
        }
    }

    // MARK: - At once

    @Test("Opening a forum topic reads its first page of replies with no press, and a Mastodon post its conversation")
    func openingReadsAtOnce() async {
        let forumHTTP = Changing(Self.onePage)
        let (forum, topic) = await forumShell(forumHTTP)
        await forum.reload.opened(topic, in: forum)
        #expect(Self.pids(forum) == [2, 3], "the replies, with nothing pressed")
        #expect(forum.posts.further(of: Self.ref) == .end)

        let http = Changing([Self.threadPath: Self.twoAnswers])
        let (session, item) = await conversationShell(http)
        await session.reload.opened(item, in: session)
        #expect(Self.bodies(session, item) == ["answer 10", "answer 11"], "as it always was")
    }

    @Test("A topic whose replies this device kept opens with them and asks nothing to draw them")
    func aKeptTopicOpensFromTheStore() async {
        let store = ItemStore()
        let (online, topic) = await forumShell(Changing(Self.onePage), store: store)
        await online.reload.opened(topic, in: online)

        let dark = Changing([:])
        let offline = ShellSession(http: dark, store: store, posts: ForumPosts(http: dark))
        await offline.reloadFromStore()
        await offline.reload.opened(topic, in: offline)
        #expect(Self.pids(offline) == [2, 3])
        #expect(await dark.requested.isEmpty)
    }

    // MARK: - Again, on the wait

    @Test("With a conversation open and no press, an answer added at its source appears after the wait")
    func aConversationRenewsOnTheWait() async {
        let http = Changing([Self.threadPath: Self.twoAnswers])
        let (session, item) = await conversationShell(http)
        await session.reload.opened(item, in: session)
        await http.answer(Self.threadPath, with: Self.context([
            Self.status("10", answering: "9"), Self.status("12", answering: "10"), Self.status("11", answering: "9"),
        ]))

        await oneWait(session) {
            #expect(await Self.threadAsks(http) == 1, "nothing asked before the wait has passed")
        }
        #expect(await Self.threadAsks(http) == 2, "asked again once the wait passed")
        #expect(Self.bodies(session, item) == ["answer 10", "answer 12", "answer 11"],
                "the new answer under the one it answers")
        #expect(session.conversations.further(of: item.id) == .end)
    }

    @Test("With a forum topic open and no press, a reply added at its source appears after the wait")
    func aTopicRenewsOnTheWait() async {
        let http = Changing(Self.onePage)
        let (session, topic) = await forumShell(http)
        await session.reload.opened(topic, in: session)
        await http.answer(Self.page(1), with: .text(
            Self.post(1, floor: 1) + Self.post(2) + Self.post(3, words: "改过了") + Self.post(4)
        ))

        await oneWait(session)
        #expect(await Self.pageAsks(http) == 2)
        #expect(Self.pids(session) == [2, 3, 4], "below everything drawn")
        guard case .loaded(let replies) = session.posts.standing(of: Self.ref) else {
            Issue.record("the topic is drawn")
            return
        }
        #expect(replies[1].body == "改过了", "a reply edited shows its new words in its place")
        #expect(await session.keptReplies(host: Self.forum, tid: Self.tid).map(\.pid) == [2, 3, 4],
                "in the store first")
    }

    @Test("The post being read does not move and the selection stays when the thread renews")
    func nothingMovesWhenItRenews() async {
        let http = Changing([Self.threadPath: Self.twoAnswers])
        let (session, item) = await conversationShell(http)
        await session.reload.opened(item, in: session)
        let before = session.conversations.conversation(around: item)
        let selected = before.descendants[1].item.id

        await http.answer(Self.threadPath, with: Self.context([
            Self.status("10", answering: "9"), Self.status("11", answering: "9"), Self.status("13", answering: "9"),
        ]))
        await oneWait(session)
        let after = session.conversations.conversation(around: item)
        #expect(after.ancestors.map(\.id) == before.ancestors.map(\.id))
        #expect(after.post.id == item.id)
        #expect(Array(after.inOrder.map(\.id).prefix(before.inOrder.count)) == before.inOrder.map(\.id),
                "everything drawn is where it was")
        #expect(after.inOrder.count == before.inOrder.count + 1)
        #expect(DummyCommand.focused(in: after.inOrder, selected: selected) == .post(after.descendants[1].item),
                "and the lamp is on the post it was on")
    }

    // MARK: - Drawn from the store

    @Test("An answer edited, or marked gone, by another read shows in the open conversation with no key")
    func theConversationDrawsFromTheStore() async throws {
        let store = ItemStore()
        let (session, item) = await conversationShell(Changing([Self.threadPath: Self.twoAnswers]), store: store)
        await session.reload.opened(item, in: session)
        let following = Task { await session.followStore() }
        defer { following.cancel() }

        // Another window reads the same thread, and its source has since edited an answer.
        let other = Changing([Self.threadPath: Self.context([
            Self.status("10", answering: "9", words: "answer 10, edited"), Self.status("11", answering: "9"),
        ])])
        let window = ShellSession(http: other, store: store, posts: ForumPosts(http: other))
        await window.reloadFromStore()
        await window.conversations.open(item, in: window)
        #expect(await spun { Self.bodies(session, item) == ["answer 10, edited", "answer 11"] },
                "the new words, in the thread nobody read again here")

        // And a read that heard its source say an answer is gone (#179).
        let gone = NoteKey(host: Self.host, id: "https://\(Self.host)/users/ada/statuses/11")
        await window.markGone(gone)
        #expect(await spun {
            session.conversations.conversation(around: item).descendants.last?.item.goneSince != nil
        }, "marked, in its place")
        #expect(Self.bodies(session, item) == ["answer 10, edited", "answer 11"], "and nothing moved")
    }

    // MARK: - A renewal that fails

    @Test("A renewal that fails says so at the thread's foot, and what was drawn stays")
    func aFailedRenewalSaysSoAtTheFoot() async {
        let http = Changing([Self.threadPath: Self.twoAnswers])
        let (session, item) = await conversationShell(http)
        await session.reload.opened(item, in: session)
        await http.answer(Self.threadPath, with: .fail)

        await oneWait(session)
        #expect(Self.bodies(session, item) == ["answer 10", "answer 11"])
        #expect(session.conversations.further(of: item.id) == .failed(.unreachable))
        #expect(ThreadFoot.said(session.conversations.further(of: item.id)!, host: Self.host)
            == .failed(sentence: "The rest of this thread did not arrive.", again: true))
        #expect(session.reload.failures[.renew] == nil, "said at the foot, and not in the toast")

        // The next wait that reaches it puts the foot back.
        await http.answer(Self.threadPath, with: Self.twoAnswers)
        await oneWait(session)
        #expect(session.conversations.further(of: item.id) == .end)

        let forumHTTP = Changing(Self.onePage)
        let (forum, topic) = await forumShell(forumHTTP)
        await forum.reload.opened(topic, in: forum)
        await forumHTTP.answer(Self.page(1), with: .fail)
        await oneWait(forum)
        #expect(Self.pids(forum) == [2, 3], "the replies drawn stay")
        #expect(forum.posts.further(of: Self.ref) == .failed(.unreachable))
    }

    // MARK: - Leaving, and one clock

    @Test("Leaving the thread asks nothing more of its source, and ends a renewal on its way")
    func leavingEndsItsAsks() async {
        let http = Changing([Self.threadPath: Self.twoAnswers])
        let (session, item) = await conversationShell(http)
        await session.reload.opened(item, in: session)

        // A renewal caught on the wire, and the thread left under it.
        await http.hold(Self.threadPath)
        let renewing = Task { await session.reload.renew(in: session) }
        #expect(await spun { await Self.threadAsks(http) == 2 })
        #expect(!session.reload.running, "the toast is not the thread's")
        #expect(!session.reload.stop(), "Esc is not spent on a renewal nobody pressed for")
        await http.answer(Self.threadPath, with: Self.context([Self.status("14", answering: "9")]))
        // A reply's thread opened from inside it, its pane told before this one's went.
        let reply = DummyItem(Note(
            id: "https://\(Self.host)/users/ada/statuses/10", source: Source(host: Self.host, kind: .mastodon),
            author: "Ada", handle: "@ada@\(Self.host)", body: "answer 10", postedAt: .distantPast, categories: []
        ))
        session.reload.inFront = reply
        session.reload.left(item)
        #expect(session.reload.inFront?.id == reply.id, "the pane opened in its place is still in front")
        await http.release()
        await renewing.value
        #expect(Self.bodies(session, item) == ["answer 10", "answer 11"], "what it had not landed does not land")

        await oneWait(session)
        #expect(await Self.threadAsks(http) == 2, "a wait after leaving asks nothing of it")
    }

    @Test("Not beside r: a renewal coming round while the timeline is read asks nothing")
    func notBesideAPress() async {
        let http = Changing([Self.threadPath: Self.twoAnswers])
        let (session, item) = await conversationShell(http)
        await session.reload.opened(item, in: session)
        await http.hold("/api/v1/timelines/public")
        let pressed = Task { await session.reload.timeline(.all, in: session) }
        #expect(await spun { await http.parked })
        await session.reload.renew(in: session)
        #expect(await Self.threadAsks(http) == 1, "a forum is never asked twice at once, nor anything else")
        await http.release()
        await pressed.value
    }

    @Test("One clock: a thread open in a window that does not keep the wait is asked on the one that does")
    func oneClockForEveryThread() async {
        let store = ItemStore()
        let (keeper, _) = await conversationShell(Changing([:]), store: store)
        let http = Changing([Self.threadPath: Self.twoAnswers])
        let window = ShellSession(http: http, store: store, posts: ForumPosts(http: http))
        await window.reloadFromStore()
        let item = DummyItem(Self.root)
        await window.reload.opened(item, in: window)

        // The other window's loop is running, and never reaches its wait.
        let started = Counter()
        let windowLoop = Task {
            await window.reload.keepAsking(every: .seconds(60), in: window) { _ in
                started.count += 1
                try await Task.sleep(for: .seconds(3_600))
            }
        }
        await oneWait(keeper) {
            _ = await spun { started.count == 1 }
        }
        #expect(await Self.threadAsks(http) == 2, "asked on the keeper's round, through its own window")
        windowLoop.cancel()
        await windowLoop.value

        await oneWait(keeper)
        #expect(await Self.threadAsks(http) == 2, "its loop gone, its thread is off the round")
    }
}

private final class Counter {
    var count = 0
}

/// Answers from a table a test can change between two asks, and one address it can hold on the
/// wire until it lets go.
private actor Changing: HTTPClient {
    private var routes: [String: FixtureHTTP.Outcome]
    private(set) var requested: [URL] = []
    private var held: String?
    private(set) var parked = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ routes: [String: FixtureHTTP.Outcome]) {
        self.routes = routes
    }

    func answer(_ route: String, with outcome: FixtureHTTP.Outcome) {
        routes[route] = outcome
    }

    func hold(_ route: String) {
        held = route
    }

    func release() {
        held = nil
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        requested.append(url)
        if let held, url.path == held || url.absoluteString == held {
            parked = true
            await withCheckedContinuation { waiting.append($0) }
        }
        try Task.checkCancellation()
        guard let outcome = routes[url.absoluteString] ?? routes[url.path] else {
            throw FixtureHTTPError.unmapped
        }
        let ok = { (data: Data, status: Int) in
            (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        switch outcome {
        case .body(let data, let status): return ok(data, status)
        case .text(let text, let status): return ok(Data(text.utf8), status)
        case .fail: throw FixtureHTTPError.unreachable
        case .cancelled: throw URLError(.cancelled)
        }
    }
}
