import Foundation
import Testing
@testable import FediqoCore

/// #297: a forum topic's reply stands in the timelines where the forum says when it was written,
/// and stays a part of its topic where the forum does not.
@Suite("A forum's reply is an item where the forum dates it")
struct ForumReplyItemTests {
    private static let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 2, name: "Dev")])
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    /// When replies are read: a day after the topic was written.
    private static let read = origin.addingTimeInterval(86_400)
    private static let topicID = "discuz:forum.example:5"

    private static func topic(_ categories: Set<FediqoCore.Category> = [.board(id: "2")], at moment: Date = origin) -> Note {
        Note(
            id: topicID, source: forum, author: "Ada", handle: "ada@forum.example", body: "", title: "A topic",
            postedAt: moment, categories: categories
        )
    }

    /// Reply `pid`, written `minutes` after the topic where the forum's page says when.
    private static func post(_ pid: Int, dated minutes: Double?, body: String? = nil, withheld: Bool = false) -> DiscuzPost {
        DiscuzPost(
            pid: pid, tid: 5, floor: pid, author: "linlu", handle: "linlu@forum.example",
            postedAt: minutes.map { origin.addingTimeInterval($0 * 60) }, body: body ?? "reply \(pid)",
            isWithheld: withheld, page: 1
        )
    }

    private static func reply(_ pid: Int, dated minutes: Double?, body: String? = nil, withheld: Bool = false) -> Note {
        post(pid, dated: minutes, body: body, withheld: withheld).asNote(host: forum.host, read: read)
    }

    private static func key(_ pid: Int) -> NoteKey {
        NoteKey(host: forum.host, id: "\(topicID):post:\(pid)")
    }

    private func store(_ notes: [Note]) async -> ItemStore {
        let store = ItemStore(sources: [Self.forum], notes: [])
        await store.ingest(notes, ifSourceHere: Self.forum.host)
        return store
    }

    @Test("A reply the forum dates is an item: in All at the forum's time and never the time it was read, with its own ID and source, answering its topic, through its topic's board; one the forum gives no date is in no timeline and is handed over as its topic's")
    func datedAndUndated() async throws {
        let store = await store([Self.topic()])
        let drawn = await store.drawn, parts = await store.repliesRevision
        await store.ingest([Self.reply(71, dated: 10), Self.reply(72, dated: nil)], ifSourceHere: Self.forum.host)

        let all = await store.all()
        #expect(Set(all.map(\.id)) == [Self.topicID, Self.key(71).id])
        let dated = try #require(all.first { $0.key == Self.key(71) })
        #expect(dated.postedAt == Self.origin.addingTimeInterval(600) && dated.postedAt != Self.read)
        #expect(dated.source == Source(host: "forum.example", kind: .discuz) && dated.body == "reply 71")
        #expect(dated.refs == [Reference(kind: .answers, id: Self.topicID)] && dated.topicKey == Self.topic().key)
        #expect(dated.categories == [.board(id: "2")], "it was read off its topic's page, and the topic is in that board")
        #expect(dated.isTopicReply && !dated.isPartOfTopic)

        let replies = await store.replies()
        #expect(replies.map(\.key) == [Self.key(72)])
        let undated = try #require(replies.first)
        #expect(undated.isPartOfTopic && undated.categories.isEmpty && undated.postedAt == Self.read)
        #expect(undated.refs == dated.refs, "it answers its topic all the same")
        #expect(all.count + replies.count == 3, "each held row once")
        #expect(await store.drawn == drawn + 1, "one moved what All draws")
        #expect(await store.repliesRevision == parts + 1, "the other what a topic's page reads")
        // Both are read back where the topic is opened.
        let ofTopic = await store.held(host: Self.forum.host, idPrefix: DiscuzPost.heldPrefix(host: Self.forum.host, tid: 5))
        #expect(ofTopic.compactMap(DiscuzPost.init(held:)).map(\.pid) == [71, 72])
        #expect(ofTopic.compactMap(DiscuzPost.init(held:)).map(\.postedAt) == [Self.origin.addingTimeInterval(600), nil])
    }

    @Test("Whether the forum said when is what the row carries of the forum's word, never its time: a reply read at the very moment a dated one was written is still no item; a reply the forum withheld carries no word of it and is no item; and no other source's row is ever a part of a topic")
    func toldByTheForumsWord() {
        let sameMoment = Self.post(73, dated: nil).asNote(host: Self.forum.host, read: Self.origin.addingTimeInterval(600))
        #expect(sameMoment.postedAt == Self.reply(71, dated: 10).postedAt && sameMoment.isPartOfTopic)
        #expect(Self.reply(74, dated: 10, withheld: true).isPartOfTopic, "nothing on it says the time was the forum's")
        #expect(!Self.topic().isPartOfTopic && Self.topic().topicKey == nil && Self.topic().refs.isEmpty)
        let elsewhere = Note(
            id: Self.key(71).id, source: Source(host: "forum.example", kind: .mastodon), author: "a", handle: "@a@forum.example",
            body: "x", postedAt: Self.origin, categories: []
        )
        #expect(!elsewhere.isTopicReply && !elsewhere.isPartOfTopic && elsewhere.refs.isEmpty)
        // The reference is the id's to say: nothing handed in replaces it, and a copy made anew keeps it.
        let handed = Note(
            id: Self.key(71).id, source: Self.forum, author: "a", handle: "a@forum.example", body: "x", postedAt: Self.origin,
            categories: [], refs: [Reference(kind: .answers, id: "discuz:forum.example:9")]
        )
        #expect(handed.refs == [Reference(kind: .answers, id: Self.topicID)])
        #expect(DiscuzPost.topicID(ofReply: "discuz:forum.example:5:post:0", from: Self.forum) == nil)
        #expect(DiscuzPost.topicID(ofReply: "discuz:other.example:5:post:7", from: Self.forum) == nil, "another forum's name is not this row's topic")
    }

    @Test("A reply first read with no date and later dated becomes an item, at the forum's time; one the forum dated keeps that date when a later page leaves it out")
    func theDateArrivesLaterAndStays() async throws {
        let store = await store([Self.topic(), Self.reply(71, dated: nil)])
        #expect(await store.all().map(\.id) == [Self.topicID])
        let drawn = await store.drawn, parts = await store.repliesRevision
        let dated = Self.reply(71, dated: 10)
        await store.ingest([dated], ifSourceHere: Self.forum.host)
        _ = await store.refresh([dated], ifSourceHere: Self.forum.host)
        let now = try #require(await store.all().first { $0.key == Self.key(71) })
        #expect(now.opening?.postedAt == Self.origin.addingTimeInterval(600) && now.postedAt == Self.origin.addingTimeInterval(600))
        #expect(await store.replies().isEmpty)
        #expect(await store.drawn > drawn, "it left one list for the other: both moved")
        #expect(await store.repliesRevision > parts)

        // Read again alone — which is what lays a later read over a held row — both lists move.
        let other = await self.store([Self.topic(), Self.reply(71, dated: nil)])
        let before = await other.drawn, partsBefore = await other.repliesRevision
        _ = await other.refresh([dated], ifSourceHere: Self.forum.host)
        #expect(await other.replies().isEmpty)
        #expect(await other.drawn > before)
        #expect(await other.repliesRevision > partsBefore)

        // The forum's word, once said, is carried onto a later read whose page gave none.
        let later = Self.post(71, dated: nil).dated(now.opening?.postedAt)
        #expect(later.postedAt == Self.origin.addingTimeInterval(600))
        #expect(Self.post(71, dated: 20).dated(Self.origin).postedAt == Self.origin, "a publish time, once kept, does not move")
        #expect(Self.post(71, dated: 20).dated(nil).postedAt == Self.origin.addingTimeInterval(1200), "with none kept, this read's")
        #expect(Self.post(71, dated: nil).dated(nil).postedAt == nil)
    }

    @Test("A forum's date is never later than the read that brought it: a reply and a topic dated after the moment they were read stand at that moment; an ordinary date is untouched; read again later, neither moves")
    func neverLaterThanTheRead() async throws {
        // A forum eight hours ahead of UTC: a reply written five minutes before the read reads eight hours on.
        let read = Self.origin.addingTimeInterval(86_400)
        let ahead = read.addingTimeInterval(8 * 3600 - 300)
        let reply = DiscuzPost(pid: 71, tid: 5, author: "p", handle: "p@forum.example", postedAt: ahead, body: "r")
        let note = reply.asNote(host: Self.forum.host, read: read)
        #expect(note.postedAt == read && note.opening?.postedAt == read, "the row's time and the reply's own date alike")
        #expect(!note.isPartOfTopic, "it is dated: the forum said when, as near as can be read")
        let ordinary = Self.reply(72, dated: 10)
        #expect(ordinary.postedAt == Self.origin.addingTimeInterval(600) && ordinary.opening?.postedAt == ordinary.postedAt)
        #expect(DiscuzDate.bounded(nil, by: read) == nil && DiscuzDate.bounded(read, by: read) == read)

        let row = DiscuzThread(tid: 5, title: "t", board: nil, author: "a", postedAt: ahead, replies: nil)
        let source = Source(host: Self.forum.host, kind: .discuz)
        let topic = row.asNote(source: source, host: Self.forum.host, board: nil, boardID: "2", read: read)
        #expect(topic.postedAt == read)
        #expect(row.asNote(source: source, host: Self.forum.host, board: nil, read: ahead.addingTimeInterval(1)).postedAt == ahead)
        let ranked = DiscuzRankedBlog(rank: 1, id: 3, uid: 4, title: "b", author: "a", postedAt: ahead, excerpt: "x")
        #expect(ranked.asNote(source: source, host: Self.forum.host, read: read).postedAt == read)

        // Read again an hour later: the page still says the later time, and neither row moves.
        let store = await store([topic, note])
        let later = read.addingTimeInterval(3600)
        let kept = try #require(await store.all().first { $0.key == Self.key(71) })
        let again = reply.dated(kept.opening?.postedAt).asNote(host: Self.forum.host, read: kept.postedAt)
        #expect(again.postedAt == read && again.opening?.postedAt == read)
        #expect(reply.asNote(host: Self.forum.host, read: later).postedAt == later, "the premise: without what was kept, it would have moved")
        await store.ingest([row.asNote(source: source, host: Self.forum.host, board: nil, boardID: "2", read: later), again], ifSourceHere: Self.forum.host)
        _ = await store.refresh([again], ifSourceHere: Self.forum.host)
        let times = await store.all().map { $0.postedAt }
        #expect(times == [read, read])
    }

    /// A reply whose words begin with the forum's own edit notice — which carries a date — in
    /// each of the three templates a page is read as, with `header` where its own date goes.
    private static func edited(_ template: String, header: String) -> String {
        let notice = #"<i class="pstatus"> 本帖最后由 p2 于 2031-1-2 03:04 编辑 </i><br />改过的字"#
        switch template {
        case "touch":
            return """
            <div class="plc" id="pid2">
              <ul class="authi"><li class="mtit">2<sup>#</sup></li><li><a href="home.php?mod=space&amp;uid=2">p2</a></li>\(header)</ul>
              <div class="message">\(notice)</div>
            </div>
            """
        case "desktop":
            return """
            <div id="post_2"><table><tr>
            <td class="pls" id="userinfo_2"><div class="authi"><a href="home.php?mod=space&amp;uid=2" class="xw1">p2</a></div></td>
            <td class="plc">
              <div class="authi">\(header)</div>
              <div class="pi"><strong><a href="forum.php?mod=viewthread&amp;tid=5#pid2" id="postnum2">2<sup>#</sup></a></strong></div>
              <table><tr><td class="t_f" id="postmessage_2">\(notice)</td></tr></table>
            </td></tr></table></div>
            """
        default:
            return """
            <div class="comiis_postli" id="pid2">
              <div class="comiis_postli_top"><h2>2楼</h2><a href="home.php?mod=space&amp;uid=2" class="comiis_nick">p2</a></div>
              \(header)
              <div class="comiis_message_table">\(notice)</div>
            </div>
            """
        }
    }

    @Test("A reply's date is its own header's and never a date in its words: one that carries the forum's edit notice and no date of its own has no date, and stays a part of its topic; with a date of its own, that is the one read", arguments: [
        ("touch", #"<li class="mtime">2026-9-15 10:00</li>"#),
        ("desktop", #"<em id="authorposton2"><span title="2026-9-15 10:00">昨天</span></em>"#),
        ("comiis", #"<div class="comiis_postli_time">2026-9-15 10:00</div>"#),
    ])
    func neverADateFromItsWords(template: String, header: String) throws {
        let undated = DiscuzThreadPage.posts(in: Self.edited(template, header: template == "comiis" ? #"<div class="comiis_postli_time">3 天前</div>"# : ""), tid: 5, host: Self.forum.host)
        let reply = try #require(undated.first { $0.pid == 2 }, "\(template): the reply is read")
        #expect(reply.author == "p2" && reply.postedAt == nil, "\(template): the notice's date is no date of the reply's")
        #expect(reply.asNote(host: Self.forum.host, read: Self.read).isPartOfTopic)

        let dated = DiscuzThreadPage.posts(in: Self.edited(template, header: header), tid: 5, host: Self.forum.host)
        let own = try #require(dated.first { $0.pid == 2 }?.postedAt, "\(template): its own date is read")
        #expect(Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: own).year == 2026, "\(template): and not the notice's 2031")
    }

    @Test("A topic found in a board after its replies were read passes the board to the dated ones held, and to no reply with no date; a timeline of that board then shows them")
    func aBoardGainedLater() async throws {
        let store = await store([Self.topic([.trends]), Self.reply(71, dated: 10), Self.reply(72, dated: nil)])
        #expect(await store.all().first { $0.key == Self.key(71) }?.categories == [])
        let drawn = await store.drawn
        await store.ingest([Self.topic([.board(id: "2")])], ifSourceHere: Self.forum.host)
        let all = await store.all()
        #expect(all.first { $0.key == Self.topic().key }?.categories == [.board(id: "2"), .trends])
        #expect(all.first { $0.key == Self.key(71) }?.categories == [.board(id: "2")])
        #expect(await store.replies().first?.categories == [])
        #expect(await store.drawn > drawn)
        let board = try #require(Rule.category(.board(id: "2"), in: .source(host: Self.forum.host), sources: [Self.forum]))
        let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: [board]), sources: [Self.forum])
        #expect(Set(timeline.shown(all, TextIndex(all)).map(\.id)) == [Self.topicID, Self.key(71).id])
        // The same topic read again changes nothing more.
        let after = await store.drawn
        await store.ingest([Self.topic([.board(id: "2")])], ifSourceHere: Self.forum.host)
        #expect(await store.drawn == after)
    }

    @Test("A rule on its topic's board shows a dated reply, and so does one on its source, its author or its words; none shows a reply with no date; a topic the ranking lists named gives its replies no Trends")
    func rulesReachIt() async throws {
        let store = await store([Self.topic([.board(id: "2"), .trends]), Self.reply(71, dated: 10, body: "about cats"), Self.reply(72, dated: nil, body: "about cats")])
        let all = await store.all()
        func shown(_ rule: Rule?) throws -> Set<String> {
            let timeline = CompiledTimeline(TimelineDefinition(name: "t", rules: [try #require(rule)]), sources: [Self.forum])
            return Set(timeline.shown(all, TextIndex(all)).map(\.id))
        }
        let reply = Self.key(71).id
        #expect(try shown(.category(.board(id: "2"), in: .source(host: Self.forum.host), sources: [Self.forum])) == [Self.topicID, reply])
        #expect(try shown(.source(Self.forum.host)) == [Self.topicID, reply])
        #expect(try shown(.author("linlu@forum.example", in: .every, sources: [Self.forum])) == [reply])
        #expect(try shown(.keyword("cats", in: .every)) == [reply])
        #expect(try shown(.category(.trends, in: .every, sources: [Self.forum])) == [Self.topicID])
        #expect(try shown(.keyword("cats", in: .every, effect: .exclude)) == [Self.topicID])
    }

    @Test("A store from before, whose dated replies say no board, opens with each through its topic's board; a reply whose topic is not held says none")
    func rowsFromBeforeTakeTheirBoard() async {
        let orphan = DiscuzPost(pid: 9, tid: 6, author: "p", handle: "p@forum.example", postedAt: Self.origin, body: "r")
            .asNote(host: Self.forum.host, read: Self.read)
        let store = ItemStore(sources: [Self.forum], notes: [Self.reply(71, dated: 10), Self.reply(72, dated: nil), Self.topic(), orphan])
        let all = await store.all()
        #expect(all.first { $0.key == Self.key(71) }?.categories == [.board(id: "2")])
        #expect(all.first { $0.key == orphan.key }?.categories == [])
        #expect(all.first { $0.key == orphan.key }?.refsUnheld == [.answers], "and says the topic it answers is not held")
        #expect(await store.replies().first?.categories == [])
    }

    @Test("Nothing a forum's reply refers to is ever something to load: it names its topic and no id to ask by, its kind of source loads nothing, and a row that says it owes is settled as owing nothing")
    func neverLoaded() async {
        var owing = Self.reply(71, dated: 10)
        owing.refsDue = true
        #expect(owing.askable.isEmpty && !ProtocolKind.discuz.loadsReferences)
        let store = ItemStore(sources: [Self.forum], notes: [owing])
        #expect(await store.owed(host: Self.forum.host).isEmpty)
        #expect(await store.all().first?.refsDue == false)
        await store.ingest([Self.reply(75, dated: 10)], ifSourceHere: Self.forum.host)
        #expect(await store.owed(host: Self.forum.host).isEmpty)
        #expect(await store.all().allSatisfy { !$0.refsDue })
    }

    @Test("A dated reply is kept, marked gone and let go as any item is — by the forum's date, not the day it was read — and its topic stays for as long as a reply of it is held")
    func keptGoneAndLimits() async throws {
        let now = Self.origin.addingTimeInterval(365 * 2 * 86_400 + 3600)
        // An old topic with a reply written two years on, and an old reply.
        let recent = Self.post(71, dated: 365 * 2 * 24 * 60).asNote(host: Self.forum.host, read: now)
        let store = ItemStore(sources: [Self.forum], notes: [Self.topic(), Self.reply(70, dated: 10), recent, Self.reply(72, dated: nil)])
        #expect(await store.setKept(true, for: Self.key(70)))
        #expect(await store.all().first { $0.key == Self.key(70) }?.kept == true)
        #expect(await store.markGone(Self.key(70)))
        #expect(await store.all().first { $0.key == Self.key(70) }?.goneSince != nil)
        #expect(await store.setKept(false, for: Self.key(70)))

        let went = await store.letGoBeyond(months: 6, from: Self.origin.addingTimeInterval(365 * 2 * 86_400 + 86_400))
        #expect(went.posts == 2, "the old dated reply, by the forum's date, and the one with no date, by the day it was read")
        #expect(Set(await store.all().map(\.key)) == [Self.topic().key, Self.key(71)], "the topic is older than the window, and stays under its reply")
        #expect(await store.replies().isEmpty)
        await store.forget(Self.key(71))
        _ = await store.letGoBeyond(months: 6, from: Self.origin.addingTimeInterval(365 * 2 * 86_400 + 86_400))
        #expect(await store.all().isEmpty, "with no reply left, the topic goes by its own age")
    }
}
