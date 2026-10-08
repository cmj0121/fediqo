import Foundation
import Testing
@testable import FediqoCore

/// What each source says happened to the person is held by the store beside the items (#323):
/// a source's lines and how far down it was read, let go with the reader, the source and the
/// months limit, and never left carrying a post this device has let go (#282, #292).
@Suite("Notices are held beside the items")
struct NoticeHeldTests {
    private static let a = Source(host: "a.example", kind: .mastodon)
    private static let b = Source(host: "b.example", kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private static func post(_ id: String, source: Source = a, days: Double = 0, kept: Bool = false) -> Note {
        Note(
            id: "https://\(source.host)/statuses/\(id)", source: source, author: "Ada", handle: "@ada",
            body: "words of \(id)", postedAt: origin.addingTimeInterval(days * 86_400), categories: [.public],
            statusID: id, kept: kept
        )
    }

    private static func line(_ id: Int, source: Source = a, days: Double = 0, post: Note? = nil) -> Notice {
        Notice(
            source: source, handle: .one(id: "\(id)"), kind: post == nil ? .follow : .favourite,
            people: [NoticePerson(handle: "@bo@\(source.host)", name: "Bo")], post: post,
            at: origin.addingTimeInterval(days * 86_400), newestID: "\(id)", oldestID: "\(id)"
        )
    }

    private static func reach(_ lines: [Notice], host: String = a.host, before: String? = nil) -> NoticeReach {
        NoticeReach(host: host, notices: lines, before: before, reached: lines.map(\.at).min(), gathered: false)
    }

    private func held(_ store: ItemStore, _ host: String = a.host) async -> NoticeReach? {
        await store.noticesHeld().notices.first { $0.host == host }
    }

    // MARK: - Held

    @Test("A source's lines and how far down it was read are held in the place of what was held, in host order, and only of a source here")
    func heldInPlace() async {
        let store = ItemStore(sources: [Self.b, Self.a], notes: [])
        let first = Self.reach([Self.line(2), Self.line(1)], before: "1")
        await store.hold(first)
        await store.hold(Self.reach([Self.line(9, source: Self.b)], host: Self.b.host))
        await store.hold(Self.reach([Self.line(7)], host: "nobody.example"))

        #expect(await store.noticesHeld().notices.map(\.host) == [Self.a.host, Self.b.host])
        #expect(await held(store) == first, "the id asked before and the moment reached with it")

        let second = Self.reach([Self.line(3), Self.line(2)])
        await store.hold(second)
        #expect(await held(store) == second, "a stretch in the place of the last, not beside it")
    }

    @Test("Holding moves the notices' own revision and tells whoever listens, and never the revision the posts are written by; what is held already moves nothing")
    func aPartOfItsOwn() async {
        let store = ItemStore(sources: [Self.a], notes: [])
        var changes = await store.changes().makeAsyncIterator()
        let reach = Self.reach([Self.line(1)])

        let after = await store.hold(reach)

        #expect(after == 1)
        #expect(await store.revisions.notices == 1)
        #expect(await store.revisions.items == 0, "a page of notices read rewrites no post")
        _ = await changes.next()

        #expect(await store.hold(reach) == 1, "the same again is no change")
        #expect(await store.letNoticesGo(host: "b.example") == false)
        #expect(await store.noticesRevision == 1)
        #expect(await store.remove(host: "b.example") == false)
        #expect(await store.remove(host: Self.a.host), "a removal says whether notices went")
    }

    @Test("A store read back at a launch holds the notices it is handed, of the sources it has")
    func readBackAtLaunch() async {
        let mine = Self.reach([Self.line(1)])
        let store = ItemStore(
            sources: [Self.a], notes: [],
            notices: [mine, Self.reach([Self.line(2, source: Self.b)], host: Self.b.host)]
        )
        #expect(await store.noticesHeld().notices == [mine])
        #expect(await store.noticesRevision == 0, "what a launch read is what the file holds")
    }

    @Test("A source is held to the bound: the newest lines, and reading on ended for it")
    func bounded() async {
        let store = ItemStore(sources: [Self.a], notes: [])
        let lines = (0...NoticeReach.capacity).map { Self.line(10_000 - $0) }
        await store.hold(Self.reach(lines, before: "1"))

        let kept = await held(store)
        #expect(kept?.notices.count == NoticeReach.capacity)
        #expect(kept?.notices.first?.newestID == "10000", "the newest are the ones kept")
        #expect(kept?.full == true && kept?.before == kept?.notices.last?.newestID, "full, and where it stopped is kept")

        // A gathered line reaches down to its group's lowest id, which can lie below the
        // lines left out: where it stopped is its newest notice, never its oldest.
        let gathered = [("g1", "10", "9"), ("g2", "8", "7"), ("g3", "6", "2"), ("g4", "5", "4")].map { key, newest, oldest in
            Notice(
                source: Self.a, handle: .gathered(key: key), kind: .favourite, people: [], count: 2,
                at: Self.origin, newestID: newest, oldestID: oldest
            )
        }
        let cut = Self.reach(gathered, before: "1").bounded(to: 3)
        #expect(cut.notices.map(\.newestID) == ["10", "8", "6"] && cut.full)
        #expect(cut.before == "6" && cut.before != cut.notices.last?.oldestID)
        #expect(Self.reach(Array(lines.prefix(3))).bounded(to: 3).full == false, "read to its own end at the bound is not full")
    }

    @Test("A source at the bound is full no longer once lines go — dismissed, or let go by the months limit — and keeps where it stopped")
    func roomAgain() async {
        let store = ItemStore(sources: [Self.a], notes: [])
        let lines = (0..<NoticeReach.capacity).map { Self.line(10_000 - $0, days: $0 == NoticeReach.capacity - 1 ? -100 : 0) }
        await store.hold(Self.reach(lines, before: "77"))
        #expect(await held(store)?.full == true)

        _ = await store.letGoBeyond(months: 1, from: Self.origin)

        #expect(await held(store)?.notices.count == NoticeReach.capacity - 1)
        let after = await held(store)
        #expect(after?.full == false && after?.before == "77")
        #expect(Self.reach(Array(lines.prefix(3)), before: "1").bounded(to: 3).full)
        #expect(!Self.reach(Array(lines.prefix(2)), before: "1").bounded(to: 3).full)
    }

    @Test("A write of a copy from before a host's notices were let go is not taken, by whichever way they went; one with nothing from before is")
    func aStaleWriteIsNotTaken() async {
        for how in ["name", "reader", "readers but", "remove and add", "replace"] {
            let store = ItemStore(sources: [Self.a, Self.b], notes: [])
            let reach = Self.reach([Self.line(1)])
            let epoch = await store.hold(reach, fresh: nil, since: nil).epoch
            #expect(await store.noticesHeld().epochs[Self.a.host] == epoch)
            let mark = await store.noticesMark

            switch how {
            case "name": await store.letNoticesGo(host: Self.a.host)
            case "reader": await store.forgetReaderMarks(host: Self.a.host)
            case "readers but": await store.forgetReaderMarks(keeping: [Self.b.host])
            case "remove and add":
                await store.remove(host: Self.a.host)
                await store.add(Self.a)
            default: await store.replace(sources: [Self.a, Self.b], notes: [])
            }
            #expect(await store.noticesMark != mark, "\(how): whoever follows is told")

            let stale = await store.hold(reach, fresh: [], since: epoch)
            #expect(await held(store) == nil, "\(how): what a reader no longer here was told came back")
            #expect(stale.epoch != epoch)
            // A write of the epoch the host is at now is taken.
            await store.hold(reach, fresh: [], since: stale.epoch)
            #expect(await held(store) == reach, "\(how)")
        }
    }

    @Test("A post opened from its notice that its source now says is gone is struck from the line; one it now covers or has changed is carried as it now is")
    func openedAndChanged() async {
        let one = Self.post("1")
        let store = ItemStore(sources: [Self.a], notes: [])
        await store.hold(Self.reach([Self.line(5, post: one), Self.line(4, post: Self.post("2"))]))
        // Opened: it becomes an item, as carried, and nothing of the line moves for that.
        await store.ingest([one], ifSourceHere: Self.a.host)
        #expect(await carried(store) == ["1", "2"])
        let before = await store.noticesRevision

        // Its source now covers it and has changed its words.
        let covered = Note(
            id: one.id, source: Self.a, author: "Ada", handle: "@ada", body: "new words", postedAt: one.postedAt,
            categories: [.public], sensitive: true, spoiler: "a cover", statusID: "1",
            editedAt: Self.origin.addingTimeInterval(60)
        )
        #expect(await store.refresh([covered], ifSourceHere: Self.a.host))

        let line = await held(store)?.notices.first
        #expect(line?.post?.spoiler == "a cover" && line?.post?.sensitive == true && line?.post?.body == "new words")
        #expect(await store.noticesRevision == before + 1)
        #expect(await store.refresh([covered], ifSourceHere: Self.a.host) == false)
        #expect(await store.noticesRevision == before + 1, "the same again moves nothing")

        // And then says it is gone.
        #expect(await store.markGone(one.key, at: Self.origin))
        #expect(await carried(store) == [nil, "2"])
    }

    // MARK: - Let go

    @Test("A source's notices go when it is let go of by name, when it is removed — posts kept or not — and when its reader's marks are swept; another source's stand")
    func letGoByHost() async {
        for how in ["name", "remove", "remove keeping posts", "reader", "readers but"] {
            let store = ItemStore(sources: [Self.a, Self.b], notes: [Self.post("1")])
            await store.hold(Self.reach([Self.line(1)]))
            let other = Self.reach([Self.line(2, source: Self.b)], host: Self.b.host)
            await store.hold(other)
            let before = await store.noticesRevision

            switch how {
            case "name": #expect(await store.letNoticesGo(host: "A.example"))
            case "remove": await store.remove(host: Self.a.host)
            case "remove keeping posts": await store.remove(host: Self.a.host, keepingPosts: true)
            case "reader":
                #expect(await store.forgetReaderMarks(host: Self.a.host), "said, so its caller writes: no post had a mark")
            default: #expect(await store.forgetReaderMarks(keeping: [Self.b.host]))
            }

            #expect(await store.noticesHeld().notices == [other], "\(how)")
            #expect(await store.noticesRevision == before + 1, "\(how)")
        }
    }

    @Test("A sweep of readers that finds no notice and no mark says nothing changed")
    func aSweepOfNothing() async {
        let store = ItemStore(sources: [Self.a], notes: [Self.post("1")])
        #expect(await store.forgetReaderMarks(host: Self.a.host) == false)
        #expect(await store.noticesRevision == 0)
    }

    @Test("A store replaced by a read back holds no notice: they were said to whoever was signed in before")
    func replacedHoldsNone() async {
        let store = ItemStore(sources: [Self.a], notes: [])
        await store.hold(Self.reach([Self.line(1, post: Self.post("1"))]))

        await store.replace(sources: [Self.a], notes: [Self.post("2")])

        #expect(await store.noticesHeld().notices.isEmpty)
        #expect(await store.noticesRevision == 2)
    }

    @Test("The months limit lets a notice older than it go, and strikes the copy of a post that old a newer notice carries; how far down the source was read stands")
    func theMonthsLimit() async {
        let store = ItemStore(sources: [Self.a], notes: [])
        let now = Self.origin
        let old = Self.line(1, days: -100)
        let aboutOld = Self.line(3, days: -1, post: Self.post("old", days: -200))
        let aboutNew = Self.line(4, days: -1, post: Self.post("new", days: -2))
        var reach = Self.reach([aboutNew, aboutOld, old], before: "1")
        reach.reached = old.at
        await store.hold(reach)

        _ = await store.letGoBeyond(months: 1, from: now)

        let kept = await held(store)
        #expect(kept?.notices.map(\.newestID) == ["4", "3"])
        #expect(kept?.notices.map { $0.post?.statusID } == ["new", nil])
        #expect(kept?.before == "1" && kept?.reached == old.at)
        #expect(await store.noticesRevision == 2)

        _ = await store.letGoBeyond(months: 1, from: now)
        #expect(await store.noticesRevision == 2, "nothing more to let go is no change")
    }

    @Test("A line older than the months limit is not held, whenever it is written; the copy of a post that old a newer line carries is held for the run and is not in what a save writes")
    func pastTheLimitIsNeverWritten() async {
        let store = ItemStore(sources: [Self.a], notes: [])
        _ = await store.letGoBeyond(months: 1, from: Self.origin)
        let old = Self.line(1, days: -100)
        let aboutOld = Self.line(3, days: -1, post: Self.post("old", days: -200))
        await store.hold(Self.reach([aboutOld, old]))

        #expect(await held(store)?.notices == [aboutOld], "a write made before the limit acted puts no old line back")
        #expect(await store.noticesCount() == [Self.a.host: 1], "and what Usage counts is what is held")
        let written = await store.noticesSnapshot()
        #expect(written.notices.first?.notices.map(\.newestID) == ["3"])
        #expect(written.notices.first?.notices.first?.post == nil)
        #expect(written.revision == 1)
    }

    // MARK: - The post a notice is about

    /// A store holding post `1` as an item and a notice carrying it, beside a notice carrying
    /// post `2`, which is no item.
    private func carrying(kept: Bool = false, gone: Bool = false) async -> ItemStore {
        let one = Self.post("1", kept: kept)
        let store = ItemStore(sources: [Self.a], notes: [one])
        if gone { await store.markGone(one.key, at: Self.origin) }
        await store.hold(Self.reach([Self.line(5, post: one), Self.line(4, post: Self.post("2", days: 5))]))
        return store
    }

    private func carried(_ store: ItemStore) async -> [String?] {
        await held(store)?.notices.map { $0.post?.statusID } ?? []
    }

    @Test("The carried copy of a post is struck by each way that post is let go, and the line stays", arguments: [
        "room", "span", "taken back", "marked gone",
    ])
    func struckWhenLetGo(how: String) async {
        let store = await carrying(gone: how == "marked gone")
        let key = Self.post("1").key

        switch how {
        case "room": _ = await store.letGoOldest(count: 1)
        case "span": await store.letGo(span: Self.origin.addingTimeInterval(-60)..<Self.origin.addingTimeInterval(60))
        case "taken back": await store.forget(key)
        default: await store.letGoneGo()
        }

        #expect(await store.note(key) == nil, "the premise: the post went")
        #expect(await carried(store) == [nil, "2"], "the line stays, without what it was about")
        #expect(await held(store)?.notices.count == 2)
        #expect(await store.noticesRevision == 2)
    }

    @Test("A post that was never an item is struck from its line too: when its days are let go, and when its author takes it back")
    func neverAnItem() async {
        let store = await carrying()
        await store.letGo(span: Self.origin.addingTimeInterval(4 * 86_400)..<Self.origin.addingTimeInterval(6 * 86_400))
        #expect(await carried(store) == ["1", nil])

        let again = await carrying()
        await again.forget(Self.post("2").key)
        #expect(await carried(again) == ["1", nil])
    }

    @Test("A span of another host's days strikes nothing here")
    func anotherHostsDays() async {
        let store = await carrying()
        await store.letGo(span: Date.distantPast..<Date.distantFuture, host: "b.example")
        #expect(await carried(store) == ["1", "2"])
        #expect(await store.noticesRevision == 1)
    }

    @Test("A post the person keeps stays, and so does the copy a notice carries of it")
    func aKeptPostStaysCarried() async {
        let store = await carrying(kept: true)
        await store.letGo(span: Self.origin.addingTimeInterval(-60)..<Self.origin.addingTimeInterval(60))
        await store.forget(Self.post("1").key)

        #expect(await store.note(Self.post("1").key) != nil)
        #expect(await carried(store) == ["1", "2"])
    }
}
