import Foundation
import Testing
@testable import FediqoCore

/// #177: a forum topic read past its first page, each page asked of the forum, and the last page
/// saying it is the last.
@Suite("A topic read a page at a time")
struct ThreadPageTests {
    private static let host = "install-c.example"
    private static let tid = 5601

    private static func address(page: Int? = nil, tid: Int = tid) -> String {
        let page = page.map { "&page=\($0)" } ?? ""
        return "https://\(host)/forum.php?mod=viewthread&tid=\(tid)\(page)&mobile=2"
    }

    /// One post in Discuz!'s own touch template, at `floor`.
    private static func post(_ pid: Int, floor: Int, _ words: String) -> String {
        """
        <div class="plc" id="pid\(pid)">
          <ul class="authi"><li class="mtit">\(floor)<sup>#</sup></li><li><a href="home.php?mod=space&amp;uid=\(pid)">p\(pid)</a></li></ul>
          <div class="message">\(words)</div>
        </div>
        """
    }

    /// The touch template's pager, pointing at `next` where there is one.
    private static func pager(next: Int?, tid: Int = tid) -> String {
        guard let next else { return #"<div class="pg"><strong>1</strong></div>"# }
        return """
        <div class="pg"><a href="forum.php?mod=viewthread&amp;tid=\(tid)&amp;page=\(next)&amp;mobile=2" class="nxt">下一页</a></div>
        """
    }

    @Test("A later page is asked at its own address, and each reply knows the page it came off")
    func aLaterPageIsAskedForItself() async throws {
        let http = FixtureHTTP([
            Self.address(): .text(Self.post(1, floor: 1, "开帖") + Self.post(2, floor: 2, "二楼") + Self.pager(next: 2)),
            Self.address(page: 2): .text(Self.post(3, floor: 3, "三楼") + Self.pager(next: nil)),
        ])
        let client = DiscuzClient(http: http, host: Self.host)

        let first = try await client.replies(tid: Self.tid, page: 1)
        #expect(first.posts.map(\.pid) == [2], "the opening post is not a reply")
        #expect(first.continues, "the first page points at a second")
        let second = try await client.replies(tid: Self.tid, page: 2)
        #expect(second.posts.map(\.pid) == [3])
        #expect(second.posts.allSatisfy { $0.page == 2 })
        #expect(!second.continues, "the last page points nowhere, and says it is the last")
        #expect(await http.requested.map(\.absoluteString) == [Self.address(), Self.address(page: 2)],
                "the first page's address is the one it always was")

        // The permalink opens the page the reply is on, where its anchor is.
        #expect(second.posts[0].url(onHost: Self.host)?.absoluteString
            == "https://\(Self.host)/forum.php?mod=viewthread&tid=\(Self.tid)&page=2#pid3")
        #expect(first.posts[0].url(onHost: Self.host)?.absoluteString
            == "https://\(Self.host)/forum.php?mod=viewthread&tid=\(Self.tid)#pid2")
    }

    @Test("Only a link to the next page of this thread says it goes on")
    func onlyTheNextPageOfThisThreadCounts() {
        let tid = Self.tid
        #expect(DiscuzThreadPage.continues(in: Self.pager(next: 3), tid: tid, after: 2))
        #expect(DiscuzThreadPage.continues(
            in: #"<a href="thread-\#(tid)-4-1.html">下一页</a>"#, tid: tid, after: 3
        ), "the rewritten spelling")
        #expect(DiscuzThreadPage.continues(
            in: #"<a href='forum.php?page=2&tid=\#(tid)&mod=viewthread'>2</a>"#, tid: tid, after: 1
        ), "in any order, in either quote")
        #expect(!DiscuzThreadPage.continues(in: Self.pager(next: nil), tid: tid, after: 1))
        #expect(!DiscuzThreadPage.continues(in: Self.pager(next: 2, tid: tid + 1), tid: tid, after: 1),
                "another thread's page two")
        #expect(!DiscuzThreadPage.continues(in: Self.pager(next: 21), tid: tid, after: 1),
                "page twenty-one is not page two")
        #expect(!DiscuzThreadPage.continues(in: Self.pager(next: 2, tid: tid * 10), tid: tid, after: 1),
                "tid 56010 is not tid 5601")
        #expect(!DiscuzThreadPage.continues(in: Self.pager(next: 1), tid: tid, after: 1),
                "the page this already is")
    }

    /// A forum answers a page past its last with its last, so a later page with no post on it is
    /// a page this device could not read — never the end, which would say a thread ended that was
    /// simply not read.
    @Test("A later page with nothing readable on it is a failure, not the end")
    func anUnreadableLaterPageIsNotTheEnd() async throws {
        let http = FixtureHTTP([Self.address(page: 4): .text("<html><body></body></html>")])
        await #expect(throws: DiscuzRequestError.noPosts) {
            try await DiscuzClient(http: http, host: Self.host).replies(tid: Self.tid, page: 4)
        }
    }

    @Test("A reply kept in the store reads back as the reply it was, and never as a thread")
    func aKeptReplyReadsBack() throws {
        let read = Date(timeIntervalSince1970: 1_800_000_000)
        let words = DiscuzPost(
            pid: 71, tid: Self.tid, floor: 21, author: "linlu", handle: "@linlu@\(Self.host)",
            body: "第三页", quoted: [DiscuzQuotation(words: "上面")], page: 3
        )
        let withheld = DiscuzPost(
            pid: 72, tid: Self.tid, floor: 22, author: "muyu", handle: "@muyu@\(Self.host)",
            body: "", isWithheld: true, page: 3
        )
        let note = words.asNote(host: Self.host.uppercased(), read: read)
        #expect(note.id == "discuz:\(Self.host):\(Self.tid):post:71")
        #expect(note.id.hasPrefix(DiscuzPost.heldPrefix(host: Self.host, tid: Self.tid)))
        #expect(note.postedAt == read, "a note must have a date; the reply's own is kept apart")
        #expect(DiscuzPost(held: note) == words)
        // Withheld comes back withheld, with no words kept — and so no floor either, which is
        // carried with the words: the forum's notice is the one thing never kept as a post's.
        let locked = try #require(DiscuzPost(held: withheld.asNote(host: Self.host, read: read)))
        #expect(locked.isWithheld && locked.body.isEmpty && locked.pid == 72 && locked.page == 3)
        #expect(withheld.asNote(host: Self.host, read: read).opening == nil)

        // A thread row, a blog row and a microblog post are none of them a kept reply.
        let thread = Note(
            id: "discuz:\(Self.host):\(Self.tid)", source: Source(host: Self.host, kind: .discuz),
            author: "a", handle: "", body: "", postedAt: read, categories: []
        )
        #expect(DiscuzPost(held: thread) == nil)
    }

    @Test("The store hands back what it holds aside, by host and prefix, where All does not")
    func theStoreHandsBackWhatItHoldsAside() async {
        let store = ItemStore()
        let forum = Source(host: Self.host, kind: .discuz)
        await store.add(forum)
        let read = Date(timeIntervalSince1970: 1_800_000_000)
        let replies = (2...4).map {
            DiscuzPost(pid: $0, tid: Self.tid, author: "p", handle: "", body: "r\($0)").asNote(host: Self.host, read: read)
        }
        let elsewhere = DiscuzPost(pid: 9, tid: Self.tid + 1, author: "p", handle: "", body: "x")
            .asNote(host: Self.host, read: read)
        await store.hold(replies + [elsewhere], ifSourceHere: Self.host)

        let held = await store.held(host: Self.host, idPrefix: DiscuzPost.heldPrefix(host: Self.host, tid: Self.tid))
        #expect(held.map(\.id) == replies.map(\.id), "this topic's, in the order they arrived")
        #expect(held.allSatisfy { $0.holding == .aside })
        #expect(await store.all().isEmpty, "a reply read in a thread is not a row All grew by")
    }
}
