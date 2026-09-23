import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #177: a thread can be read to its end, each further page asked of its source, and the end says
/// it is the end — landed in the store first, there with the network off, and never moving the
/// post being read.
@MainActor
@Suite("A thread read to its end")
struct ThreadToEndTests {
    init() {
        L10n.language = .english
    }

    // MARK: - A forum topic, a page at a time

    private static let forum = "install-c.example"
    private static let tid = 70241

    private static func page(_ number: Int) -> String {
        let page = number > 1 ? "&page=\(number)" : ""
        return "https://\(forum)/forum.php?mod=viewthread&tid=\(tid)\(page)&mobile=2"
    }

    private static func post(_ pid: Int, floor: Int? = nil) -> String {
        """
        <div class="plc" id="pid\(pid)">
          <ul class="authi"><li class="mtit">\(floor ?? pid)<sup>#</sup></li><li><a href="home.php?mod=space&amp;uid=\(pid)">p\(pid)</a></li></ul>
          <div class="message">第 \(pid) 帖</div>
        </div>
        """
    }

    private static func pager(next: Int?) -> String {
        guard let next else { return "" }
        return #"<div class="pg"><a href="forum.php?mod=viewthread&amp;tid=\#(tid)&amp;page=\#(next)&amp;mobile=2" class="nxt">下一页</a></div>"#
    }

    /// Three pages: the opening post and a reply, two replies, and a last reply that points nowhere.
    private static let threePages: [String: FixtureHTTP.Outcome] = [
        page(1): .text(post(1, floor: 1) + post(2) + pager(next: 2)),
        page(2): .text(post(3) + post(4) + pager(next: 3)),
        page(3): .text(post(5) + pager(next: nil)),
    ]

    private static var ref: ForumThreadRef { ForumThreadRef(host: forum, tid: tid) }

    /// A session holding one forum thread row, reading through `http`.
    private func forumShell(
        _ http: any HTTPClient, store: ItemStore? = nil
    ) async -> ShellSession {
        let store = store ?? ItemStore()
        await store.add(Source(host: Self.forum, kind: .discuz))
        await store.ingest([Note(
            id: "discuz:\(Self.forum):\(Self.tid)", source: Source(host: Self.forum, kind: .discuz),
            author: "tinbox", handle: "@tinbox@\(Self.forum)", body: "", title: "一个很长的主题",
            postedAt: Date(timeIntervalSince1970: 0), categories: [.public]
        )])
        let session = ShellSession(http: http, store: store, posts: ForumPosts(http: http))
        await session.reloadFromStore()
        return session
    }

    private static func pids(_ standing: ForumRepliesStanding) -> [Int] {
        guard case .loaded(let posts) = standing else { return [] }
        return posts.map(\.pid)
    }

    @Test("A topic longer than one page is read to its last reply, each page really asked, and the end is named")
    func aTopicIsReadToItsEnd() async {
        let http = FixtureHTTP(Self.threePages)
        let session = await forumShell(http)
        let posts = session.posts

        await posts.fetchReplies(Self.ref)
        #expect(Self.pids(posts.standing(of: Self.ref)) == [2])
        #expect(posts.further(of: Self.ref) == .more, "the first page points at a second")

        await posts.more(Self.ref)
        #expect(Self.pids(posts.standing(of: Self.ref)) == [2, 3, 4])
        #expect(posts.further(of: Self.ref) == .more)

        await posts.more(Self.ref)
        #expect(Self.pids(posts.standing(of: Self.ref)) == [2, 3, 4, 5])
        #expect(posts.further(of: Self.ref) == .end, "the last page said it was the last")
        #expect(ThreadFoot.said(posts.further(of: Self.ref)!, host: Self.forum) == .end)
        #expect(L10n.t("thread.more.end") == "This is the end of the thread.")

        // At the end, nothing more is asked — not by the foot, and not by the key.
        await posts.more(Self.ref)
        #expect(!posts.wantsPressing(Self.ref))
        #expect(await http.requested.map(\.absoluteString) == [Self.page(1), Self.page(2), Self.page(3)],
                "each page asked of the forum once, at its own address")
    }

    @Test("Each page lands in the store first, held aside, and no timeline grows by it")
    func eachPageLandsInTheStoreAside() async {
        let session = await forumShell(FixtureHTTP(Self.threePages))
        await session.posts.fetchReplies(Self.ref)
        await session.posts.more(Self.ref)
        await session.posts.more(Self.ref)

        let held = await session.store.held(
            host: Self.forum, idPrefix: DiscuzPost.heldPrefix(host: Self.forum, tid: Self.tid)
        )
        #expect(held.count == 4, "every reply read is written down")
        #expect(held.allSatisfy { $0.holding == .aside })
        #expect(session.notes.map(\.id) == ["discuz:\(Self.forum):\(Self.tid)"], "All holds the thread, not its replies")
        #expect(await session.keptReplies(host: Self.forum, tid: Self.tid).map(\.pid) == [2, 3, 4, 5])
    }

    @Test("A page that did not arrive says so in place, keeps what did, and can be tried again")
    func aFailedPageSaysSoInPlace() async {
        let http = Scripted(Self.threePages.merging([Self.page(2): .fail]) { _, failing in failing })
        let session = await forumShell(http)
        let posts = session.posts
        await posts.fetchReplies(Self.ref)

        await posts.more(Self.ref)
        #expect(posts.further(of: Self.ref) == .failed(.unreachable))
        #expect(Self.pids(posts.standing(of: Self.ref)) == [2], "what already arrived stays")
        #expect(
            ThreadFoot.said(posts.further(of: Self.ref)!, host: Self.forum)
                == .failed(sentence: "The rest of this thread did not arrive.", again: true)
        )
        #expect(posts.wantsPressing(Self.ref), "the key tries it again, as the button does")

        await http.answer(Self.page(2), with: Self.threePages[Self.page(2)]!)
        await posts.press(Self.ref)
        #expect(Self.pids(posts.standing(of: Self.ref)) == [2, 3, 4])
        #expect(posts.further(of: Self.ref) == .more)
    }

    @Test("A refused page is named, and not offered again")
    func aRefusedPageIsNotOfferedAgain() {
        let said = ThreadFoot.said(.failed(ForumPosts.Absence.refused), host: Self.forum)
        #expect(said == .failed(
            sentence: "\(Self.forum) would not let this app read further into this thread.", again: false
        ))
    }

    @Test("What was read stays on this device, and is drawn with the network off")
    func whatWasReadStaysOffline() async {
        let store = ItemStore()
        let online = await forumShell(FixtureHTTP(Self.threePages), store: store)
        await online.posts.fetchReplies(Self.ref)
        await online.posts.more(Self.ref)

        // Another run on the same store, with nothing answering.
        let dark = FixtureHTTP(Self.threePages.mapValues { _ in .fail })
        let offline = ShellSession(http: dark, store: store, posts: ForumPosts(http: dark))
        await offline.reloadFromStore()

        await offline.posts.recall(Self.ref)
        #expect(Self.pids(offline.posts.standing(of: Self.ref)) == [2, 3, 4], "drawn from what was kept")
        #expect(await dark.requested.isEmpty, "and nothing was asked to draw it")

        // Reading on asks the last page read again, which is where a new reply would be.
        await offline.posts.more(Self.ref)
        #expect(await dark.requested.map(\.absoluteString) == [Self.page(2)])
        #expect(offline.posts.further(of: Self.ref) == .failed(.unreachable))
        #expect(Self.pids(offline.posts.standing(of: Self.ref)) == [2, 3, 4], "and a failure takes none of it away")
    }

    @Test("A reply already drawn keeps its place when a page lands, and a reload does not send the reader back")
    func nothingDrawnMoves() async {
        // The rule itself: a held reply keeps its place and takes the words just read, one new to
        // this run follows everything held, and what only the store had comes last.
        let reply = { (pid: Int, words: String) in
            DiscuzPost(pid: pid, tid: Self.tid, author: "p", handle: "", body: words)
        }
        let merged = ForumPosts.merged(
            held: [reply(2, "a"), reply(3, "b"), reply(4, "c")],
            read: [reply(3, "b, edited"), reply(5, "d")],
            kept: [reply(2, "a"), reply(6, "e")]
        )
        #expect(merged.map(\.pid) == [2, 3, 4, 5, 6])
        #expect(merged[1].body == "b, edited")

        // And through the session: the page read at the end is asked again after a reload of the
        // first, so a new reply on it lands below everything drawn.
        let http = Scripted(Self.threePages)
        let session = await forumShell(http)
        let posts = session.posts
        await posts.fetchReplies(Self.ref)
        await posts.more(Self.ref)
        await posts.more(Self.ref)
        let before = Self.pids(posts.standing(of: Self.ref))

        await http.answer(Self.page(3), with: .text(Self.post(5) + Self.post(6)))
        _ = await posts.reload(Self.ref, within: .seconds(5))
        #expect(posts.further(of: Self.ref) == .more, "not sent back to page two")
        await posts.more(Self.ref)
        let after = Self.pids(posts.standing(of: Self.ref))
        #expect(Array(after.prefix(before.count)) == before, "nothing already drawn moved")
        #expect(after == [2, 3, 4, 5, 6])
        #expect(await http.requested.last?.absoluteString == Self.page(3))
    }

    // MARK: - A microblog conversation the source cut short

    private static let host = "one.example"
    private static let threadPath = "/api/v1/statuses/9/context"

    private static func status(_ id: String, answering parent: String, replies: Int = 0) -> String {
        """
        {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)","in_reply_to_id":"\(parent)",
         "replies_count":\(replies),
         "created_at":"2024-01-01T00:00:00.000Z","content":"<p>answer \(id)</p>",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static func context(_ descendants: [String]) -> FixtureHTTP.Outcome {
        .text(#"{"ancestors":[],"descendants":["# + descendants.joined(separator: ",") + "]}")
    }

    /// The post's thread cut after 11, which says it has two answers; 11's own thread has them.
    private static let cutShort: [String: FixtureHTTP.Outcome] = [
        threadPath: context([status("10", answering: "9"), status("11", answering: "9", replies: 2)]),
        "/api/v1/statuses/11/context": context([status("12", answering: "11"), status("13", answering: "11")]),
    ]

    private func conversationShell(
        _ http: any HTTPClient, store: ItemStore? = nil
    ) async -> (ShellSession, DummyItem) {
        let store = store ?? ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        let held = Note(
            id: "https://\(Self.host)/users/ada/statuses/9", source: Source(host: Self.host, kind: .mastodon),
            author: "Ada", handle: "@ada@\(Self.host)", body: "the post",
            postedAt: Date(timeIntervalSince1970: 0), categories: [.public], statusID: "9"
        )
        await store.ingest([held])
        let session = ShellSession(http: http, store: store, posts: ForumPosts(http: http))
        await session.reloadFromStore()
        return (session, DummyItem(held))
    }

    private static func bodies(_ session: ShellSession, _ item: DummyItem) -> [String] {
        session.conversations.conversation(around: item).descendants.map(\.item.body)
    }

    @Test("A conversation the source cut short is read on from where it stopped, below what is drawn")
    func aConversationIsReadOn() async {
        let http = FixtureHTTP(Self.cutShort)
        let (session, item) = await conversationShell(http)
        let conversations = session.conversations

        await conversations.open(item, in: session)
        #expect(Self.bodies(session, item) == ["answer 10", "answer 11"])
        #expect(conversations.further(of: item.id) == .more, "11 says it has answers not handed back")

        await conversations.more(item, in: session)
        #expect(Self.bodies(session, item) == ["answer 10", "answer 11", "answer 12", "answer 13"],
                "below everything drawn, so nothing drawn moved")
        #expect(session.conversations.conversation(around: item).descendants.map(\.depth) == [1, 1, 2, 2])
        #expect(conversations.further(of: item.id) == .end)
        #expect(await http.paths == [Self.threadPath, "/api/v1/statuses/11/context"])

        await conversations.more(item, in: session)
        #expect(await http.paths.count == 2, "the end asks nothing")
    }

    @Test("A conversation's answers land in the store aside, and All does not grow by them")
    func answersLandAside() async {
        let (session, item) = await conversationShell(FixtureHTTP(Self.cutShort))
        await session.conversations.open(item, in: session)
        await session.conversations.more(item, in: session)

        for id in ["10", "11", "12", "13"] {
            let key = NoteKey(host: Self.host, id: "https://\(Self.host)/users/ada/statuses/\(id)")
            #expect(await session.store.note(key)?.holding == .aside, "answer \(id) is held")
        }
        #expect(session.notes.count == 1, "All holds the post and nothing read around it")
    }

    @Test("A post that says it has answers beyond what one ask brings, but is the post itself, is the end")
    func thePostItselfIsNeverAskedAgain() {
        let answer = { (id: String, parent: String, replies: Int) in
            Note(
                id: id, source: Source(host: Self.host, kind: .mastodon), author: "a", handle: "",
                body: "", postedAt: .distantPast, categories: [],
                reply: Reply(inReplyToId: parent), counts: Counts(replies: replies), statusID: id
            )
        }
        // Only the post the thread is about claims more — its thread is the answer already had.
        #expect(ShellConversations.edge(below: "9", in: [answer("10", "9", 0)], asked: ["9"]) == nil)
        // The deepest place that stopped comes first, then the post it answers.
        let chain = [answer("10", "9", 3), answer("11", "10", 1)]
        #expect(ShellConversations.edge(below: "9", in: chain, asked: ["9"]) == "11")
        #expect(ShellConversations.edge(below: "9", in: chain, asked: ["9", "11"]) == "10")
        #expect(ShellConversations.edge(below: "9", in: chain, asked: ["9", "11", "10"]) == nil,
                "asked once, never again — a count of answers nobody may see does not loop")
    }

    @Test("A further ask that failed says so at the foot, keeps what arrived, and can be tried again")
    func aFailedFurtherAskKeepsWhatArrived() async {
        let http = Scripted(Self.cutShort.merging(["/api/v1/statuses/11/context": .fail]) { $1 })
        let (session, item) = await conversationShell(http)
        await session.conversations.open(item, in: session)

        await session.conversations.more(item, in: session)
        #expect(session.conversations.further(of: item.id) == .failed(.unreachable))
        #expect(Self.bodies(session, item) == ["answer 10", "answer 11"])
        #expect(
            ThreadFoot.said(session.conversations.further(of: item.id)!, host: Self.host)
                == .failed(sentence: "The rest of this thread did not arrive.", again: true)
        )

        await http.answer("/api/v1/statuses/11/context", with: Self.cutShort["/api/v1/statuses/11/context"]!)
        await session.conversations.more(item, in: session)
        #expect(Self.bodies(session, item).count == 4)
        #expect(session.conversations.further(of: item.id) == .end)
    }

    @Test("A conversation read before is drawn from this device with the network off")
    func aConversationStaysOffline() async {
        let store = ItemStore()
        let (online, item) = await conversationShell(FixtureHTTP(Self.cutShort), store: store)
        await online.conversations.open(item, in: online)
        await online.conversations.more(item, in: online)

        let dark = FixtureHTTP([Self.threadPath: .fail])
        let offline = ShellSession(http: dark, store: store, posts: ForumPosts(http: dark))
        await offline.reloadFromStore()
        await offline.conversations.open(item, in: offline)

        #expect(Self.bodies(offline, item) == ["answer 10", "answer 11", "answer 12", "answer 13"],
                "what was read, from the store")
        #expect(offline.conversations.conversation(around: item).descendants.map(\.depth) == [1, 1, 2, 2])
        #expect(offline.conversations.further(of: item.id) == .failed(.unreachable),
                "and the foot says the rest did not arrive, rather than that it ended")
    }

}

/// Answers from a table a test can change between two asks — a page that fails, then arrives.
private actor Scripted: HTTPClient {
    private var routes: [String: FixtureHTTP.Outcome]
    private(set) var requested: [URL] = []

    init(_ routes: [String: FixtureHTTP.Outcome]) {
        self.routes = routes
    }

    func answer(_ route: String, with outcome: FixtureHTTP.Outcome) {
        routes[route] = outcome
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        requested.append(url)
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
