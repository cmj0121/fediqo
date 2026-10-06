import Foundation
import Testing
@testable import FediqoCore

/// #296: there is one way of holding an item. What a search found, what was read under a tag,
/// the answers read when an item was opened and a post another one quotes are items like any
/// other — each in `ItemStore.all()`, through no category of its source — and nothing is held
/// apart. What is left out of `all()` is left out by what it is: a forum topic's kept reply,
/// a part of its topic.
@Suite("One way of holding")
struct OneHoldingTests {
    private let source = Source(host: "one.example", kind: .mastodon)
    private let forum = Source(host: "forum.example", kind: .discuz)
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(
        _ id: String, by handle: String = "@ada@one.example", body: String = "", at offset: TimeInterval = 0,
        categories: Set<FediqoCore.Category> = [], counts: Counts = Counts(), language: String? = nil
    ) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: handle, body: body,
            postedAt: Self.origin.addingTimeInterval(offset), categories: categories, counts: counts,
            language: language
        )
    }

    private func reply(_ pid: Int) -> Note {
        DiscuzPost(pid: pid, tid: 5, floor: pid, author: "linlu", handle: "@linlu@forum.example", body: "a reply", page: 1)
            .asNote(host: forum.host, read: Self.origin)
    }

    @Test("A post taken in through no category is in All at once, with the time its source gave it, and moves what All draws")
    func throughNoCategoryIsInAll() async {
        let store = ItemStore(sources: [source], notes: [note("1", categories: [.home])])
        let drawn = await store.drawn, replies = await store.repliesRevision
        await store.ingest([note("found", at: -3600)], ifSourceHere: source.host)
        let held = await store.all().first { $0.id == "found" }
        #expect(held?.postedAt == Self.origin.addingTimeInterval(-3600))
        #expect(held?.categories == [])
        #expect(await store.drawn == drawn + 1)
        #expect(await store.repliesRevision == replies, "and nothing a topic's page reads moved")
    }

    @Test("A forum topic's reply its forum gave no date is a part of its topic: never in All, handed over as a reply, and it moves the replies' count and not what All draws")
    func aTopicReplyIsNoItem() async {
        let store = ItemStore(sources: [source, forum], notes: [note("1", categories: [.home])])
        let drawn = await store.drawn, replies = await store.repliesRevision
        await store.ingest([reply(71), reply(72)], ifSourceHere: forum.host)
        #expect(await store.all().map(\.id) == ["1"])
        #expect(await store.replies().count == 2)
        #expect(await store.replies().allSatisfy { $0.isTopicReply })
        #expect(await store.drawn == drawn)
        #expect(await store.repliesRevision == replies + 1)
    }

    @Test("Only a row its forum's page wrote is a topic's reply: a forum topic, and a post whose id merely begins the same way, are items")
    func whatIsAndIsNotATopicReply() {
        #expect(reply(71).isTopicReply)
        let topic = Note(
            id: "discuz:forum.example:5", source: forum, author: "a", handle: "@a@forum.example", body: "",
            postedAt: Self.origin, categories: [.home]
        )
        #expect(!topic.isTopicReply)
        #expect(!note("discuz:forum.example:5:post:71").isTopicReply, "the id's look alone, with none of a reply's facts")
        #expect(!note("https://one.example/1").isTopicReply)
    }

    @Test("A post of another kind of source whose id has a topic reply's whole shape is an item all the same: it stands in All, and is no reply")
    func anotherSourcesIdOfThatShape() async {
        let shaped = note("discuz:one.example:5:post:71", body: "sent by a microblog")
        #expect(DiscuzPost(held: shaped) != nil, "the premise: the id alone reads as a reply's")
        #expect(!shaped.isTopicReply)
        let store = ItemStore(sources: [source], notes: [])
        await store.ingest([shaped], ifSourceHere: source.host)
        #expect(await store.all().map(\.id) == [shaped.id])
        #expect(await store.replies().isEmpty)
    }

    @Test("Through the rules: a timeline made of Home alone does not show what came through no category; All does, and so does a rule on its source, its author, a word, or a field")
    func throughTheRules() throws {
        let home = note("1", body: "morning", categories: [.home], language: "en")
        let answer = note("2", by: "@stranger@two.example", body: "an answer about cats", language: "en")
        let notes = [home, answer]
        let index = TextIndex(notes)
        func shown(_ rule: Rule?) throws -> [String] {
            let rule = try #require(rule)
            return CompiledTimeline(TimelineDefinition(name: "T", rules: [rule]), sources: [source]).shown(notes, index).map(\.id)
        }
        #expect(CompiledTimeline(.all, sources: [source]).shown(notes, index).map(\.id) == ["1", "2"])
        #expect(try shown(.category(.home, in: .every, sources: [source])) == ["1"])
        #expect(try shown(.source(source.host)) == ["1", "2"])
        #expect(try shown(.author("stranger@two.example", in: .every, sources: [source])) == ["2"], "somebody the reader does not follow, named by a rule, is shown by it")
        #expect(try shown(.keyword("cats", in: .every)) == ["2"])
        #expect(try shown(.field("language", is: .option("en"), in: .every)) == ["1", "2"])
    }

    @Test("A post held whole is not cut down by the copy a quote of it carries: its counts, its language and its category stay")
    func aQuotesCopyNeverNarrowsTheItem() async {
        let whole = note("q", body: "quoted", categories: [.public], counts: Counts(replies: 3), language: "en")
        let store = ItemStore(sources: [source], notes: [whole])
        let copy = QuotedPost(
            id: "q", statusID: nil, author: "Ada", handle: "@ada@one.example", body: "quoted", postedAt: Self.origin
        )
        let quoting = Note(
            id: "9", source: source, author: "Bob", handle: "@bob@one.example", body: "look",
            postedAt: Self.origin.addingTimeInterval(60), categories: [.home],
            quote: Quote(state: .accepted, post: copy)
        )
        await store.ingest([quoting], ifSourceHere: source.host)
        let held = await store.note(whole.key)
        #expect(held?.counts == Counts(replies: 3))
        #expect(held?.language == "en")
        #expect(held?.categories == [.public])
        #expect(await store.all().count == 2)
    }

    @Test("The keep-for window lets go of what a search brought as it does of any post, and what it leaves is in All")
    func theWindowTreatsThemAlike() async {
        let now = Self.origin
        let store = ItemStore(sources: [source], notes: [
            note("old-home", at: -90 * 86400, categories: [.home]), note("old-found", at: -90 * 86400),
            note("new-home", at: -86400, categories: [.home]), note("new-found", at: -86400),
        ])
        let went = await store.letGoBeyond(months: 1, from: now)
        #expect(went.posts == 2)
        #expect(await store.all().map(\.id).sorted() == ["new-found", "new-home"])
    }

    @Test("Room lets go of the oldest whichever read brought them, a topic's reply among them")
    func roomTreatsThemAlike() async {
        let store = ItemStore(sources: [source, forum], notes: [
            note("found", at: -3 * 86400), note("home", at: -2 * 86400, categories: [.home]), note("newest", at: 86400),
        ])
        await store.ingest([reply(71)], ifSourceHere: forum.host)
        let went = await store.letGoOldest(count: 2)
        #expect(went.posts == 2)
        #expect(await store.all().map(\.id).sorted() == ["newest"], "the two oldest posted went: the find, then the Home post")
        #expect(await store.replies().count == 1)
    }
}
