import Foundation
import Testing
@testable import FediqoCore

/// An item the person keeps is never let go (#284), at the store's own door: every way a row
/// goes, asked of a kept row beside one that is not.
@Suite("An item the person keeps")
struct KeepTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let alpha = Source(host: "alpha.test", kind: .mastodon)
    private let beta = Source(host: "beta.test", kind: .mastodon)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func note(
        _ id: String, daysAgo: Double = 1, from source: Source? = nil, holding: Holding = .arrived,
        kept: Bool = false, quote: Quote? = nil
    ) -> Note {
        Note(
            id: id, source: source ?? alpha, author: "Ada", handle: "@ada@alpha.test", body: "hello \(id)",
            postedAt: origin.addingTimeInterval(-daysAgo * 86_400), categories: [.public],
            statusID: id, holding: holding, quote: quote, kept: kept
        )
    }

    private func key(_ id: String, _ source: Source? = nil) -> NoteKey {
        NoteKey(host: (source ?? alpha).host, id: id)
    }

    private func ids(_ store: ItemStore) async -> [String] {
        await store.snapshot().notes.map(\.id).sorted()
    }

    // MARK: - The mark

    @Test("Keeping a held post marks it and moves what is drawn; a second keep changes nothing")
    func keeps() async {
        let store = ItemStore(sources: [alpha], notes: [note("1"), note("2")])
        let before = (await store.revision, await store.drawn)
        #expect(await store.setKept(true, for: key("1")))
        #expect(await store.note(key("1"))?.kept == true)
        #expect(await store.note(key("2"))?.kept == false, "nothing else moved")
        #expect(await store.revision == before.0 + 1, "a save writes it")
        #expect(await store.drawn == before.1 + 1, "and the row draws it")
        #expect(await !store.setKept(true, for: key("1")))
        #expect(await store.revision == before.0 + 1)
    }

    @Test("A post not held is not kept into being; one held aside is kept without moving All")
    func keepsOnlyWhatIsHeld() async {
        let store = ItemStore(sources: [alpha], notes: [note("aside", holding: .aside)])
        #expect(await !store.setKept(true, for: key("9")))
        #expect(await store.note(key("9")) == nil)
        let counts = (await store.drawn, await store.asideRevision)
        #expect(await store.setKept(true, for: key("aside")))
        #expect(await store.drawn == counts.0)
        #expect(await store.asideRevision == counts.1 + 1)
    }

    @Test("No read takes the mark off: the same post landing again, and the post read again, leave it kept")
    func readsLeaveItKept() async {
        let store = ItemStore(sources: [alpha], notes: [note("1")])
        await store.setKept(true, for: key("1"))
        var again = note("1")
        again.categories = [.trends]
        await store.ingest([again], ifSourceHere: alpha.host)
        #expect(await store.note(key("1"))?.kept == true)
        #expect(await store.note(key("1"))?.categories == [.public, .trends])
        await store.refresh([note("1")], ifSourceHere: alpha.host)
        #expect(await store.note(key("1"))?.kept == true)
    }

    @Test("An opening post kept with a row, and the row found again by a search and held aside, leave it kept")
    func openingAndHoldLeaveItKept() async {
        let store = ItemStore(sources: [alpha], notes: [note("1")])
        await store.setKept(true, for: key("1"))

        #expect(await store.keep([key("1"): ForumOpening(words: "the opening")]))
        #expect(await store.note(key("1"))?.kept == true)
        #expect(await store.note(key("1"))?.opening?.words == "the opening")
        #expect(note("1", kept: true).with(opening: ForumOpening(words: "x")).kept)

        await store.hold([note("1")], ifSourceHere: alpha.host)
        #expect(await store.note(key("1"))?.kept == true)
        #expect(await store.note(key("1"))?.holding == .arrived, "and holding only ever widens")
    }

    @Test("A kept row held aside that a timeline then brings is drawn, still kept")
    func keptAsideWidens() async {
        let store = ItemStore(sources: [alpha], notes: [])
        await store.hold([note("1")], ifSourceHere: alpha.host)
        await store.setKept(true, for: key("1"))
        await store.ingest([note("1")], ifSourceHere: alpha.host)
        #expect(await store.all().map(\.kept) == [true])
    }

    @Test("The rows held among some keys are handed over as the store holds them, and a key not held is left out")
    func notesByKey() async {
        let store = ItemStore(sources: [alpha], notes: [note("1"), note("2")])
        await store.setKept(true, for: key("1"))
        let found = await store.notes([key("1"), key("9")])
        #expect(found.keys.map(\.id) == ["1"])
        #expect(found[key("1")]?.kept == true)
    }

    // MARK: - Letting go by dates

    @Test("Letting go by dates across the day a kept post was posted leaves it and takes the others, and the count beforehand is the others")
    func spanLeavesKept() async {
        let store = ItemStore(sources: [alpha, beta], notes: [
            note("kept"), note("other"), note("aside", holding: .aside), note("beta", from: beta),
            note("outside", daysAgo: 9),
        ])
        await store.setKept(true, for: key("kept"))
        let day = origin.addingTimeInterval(-1.5 * 86_400)..<origin.addingTimeInterval(-0.5 * 86_400)

        #expect(await store.count(span: day) == 3, "the question names the three that would go")
        #expect(await store.count(span: day, host: alpha.host) == 2)
        #expect(await store.letGo(span: day) == 3)
        #expect(await ids(store) == ["kept", "outside"])
        #expect(await store.count(span: day) == 0, "nothing more to ask about")
        #expect(await store.letGo(span: day) == 0)
    }

    // MARK: - The two limits

    @Test("The months limit leaves a kept post older than the window where it was, and counts only what went")
    func monthsLeavesKept() async {
        let store = ItemStore(sources: [alpha, beta], notes: [
            note("kept", daysAgo: 400), note("old", daysAgo: 400, from: beta),
            note("kept-aside", daysAgo: 500, holding: .aside), note("new", daysAgo: 1),
        ])
        await store.setKept(true, for: key("kept"))
        await store.setKept(true, for: key("kept-aside"))

        let went = await store.letGoBeyond(months: 1, from: origin, calendar: utc)

        #expect(went == WentByLimit(posts: 1, sources: ["beta.test"]), "the account names the one that went")
        #expect(await ids(store) == ["kept", "kept-aside", "new"])
        #expect(await store.all().map(\.id) == ["new", "kept"], "still in its timelines")
        #expect(await store.aside().map(\.id) == ["kept-aside"], "and one held aside is still aside")
    }

    @Test("A kept post older than the window still takes what its source says of it, and nothing old comes in beside it")
    func keptOldStillHears() async {
        let store = ItemStore(sources: [alpha], notes: [note("kept", daysAgo: 400)])
        await store.setKept(true, for: key("kept"))
        await store.setRetention(months: 1, from: origin, calendar: utc)
        var again = note("kept", daysAgo: 400)
        again.categories = [.trends]

        await store.ingest([again, note("stranger", daysAgo: 400)], ifSourceHere: alpha.host)

        #expect(await ids(store) == ["kept"])
        #expect(await store.note(key("kept"))?.categories == [.public, .trends])
    }

    @Test("What a kept post quotes stays past the window with it")
    func keptKeepsItsQuote() async {
        let quoted = QuotedPost(
            id: "quoted", author: "Bob", handle: "@bob", body: "old",
            postedAt: origin.addingTimeInterval(-500 * 86_400)
        )
        let store = ItemStore(sources: [alpha], notes: [])
        await store.ingest([note("kept", daysAgo: 400, quote: Quote(state: .accepted, post: quoted))])
        await store.setKept(true, for: key("kept"))

        #expect(await store.letGoBeyond(months: 1, from: origin, calendar: utc).posts == 0)
        #expect(await ids(store) == ["kept", "quoted"])
    }

    @Test("The room limit lets the oldest that are not kept go, and nothing at all where only kept posts are left")
    func roomLeavesKept() async {
        let store = ItemStore(sources: [alpha, beta], notes: [
            note("kept-oldest", daysAgo: 90), note("old", daysAgo: 30, from: beta),
            note("mid", daysAgo: 10), note("new", daysAgo: 1),
        ])
        await store.setKept(true, for: key("kept-oldest"))

        let went = await store.letGoOldest(count: 2)

        #expect(went == WentByLimit(posts: 2, sources: ["alpha.test", "beta.test"]))
        #expect(await ids(store) == ["kept-oldest", "new"])
        #expect(await store.letGoOldest(count: 5) == WentByLimit(posts: 1, sources: ["alpha.test"]))
        let revision = await store.revision
        #expect(await store.letGoOldest(count: 5) == .none, "a limit that can reach nothing lets nothing go")
        #expect(await ids(store) == ["kept-oldest"])
        #expect(await store.revision == revision, "and says nothing changed")
    }

    // MARK: - Its source removed

    @Test("A kept post whose source is removed with its posts stays, still naming that source; the rest of the host goes")
    func removalLeavesKept() async {
        let store = ItemStore(sources: [alpha, beta], notes: [
            note("kept"), note("other"), note("aside", holding: .aside), note("beta", from: beta),
        ])
        await store.setKept(true, for: key("kept"))

        await store.remove(host: alpha.host)

        #expect(await store.sources() == [beta])
        #expect(await ids(store) == ["beta", "kept"])
        let stayed = await store.note(key("kept"))
        #expect(stayed?.source.host == alpha.host, "which is what marks it as from a removed source")
        #expect(await store.all().map(\.id).sorted() == ["beta", "kept"], "and it is still drawn")
        // Nothing new lands under the host that went, the kept row's own copy included.
        await store.ingest([note("late")], ifSourceHere: alpha.host)
        #expect(await ids(store) == ["beta", "kept"])
    }

    // MARK: - Gone from its source

    @Test("A kept post its source says is gone is still there after everything marked is let go, and was never in the count")
    func goneLeavesKept() async {
        let store = ItemStore(sources: [alpha], notes: [note("kept"), note("other"), note("fine")])
        await store.setKept(true, for: key("kept"))
        await store.markGone(key("kept"), at: origin)
        await store.markGone(key("other"), at: origin)

        #expect(await store.goneCount() == 1, "the press is asked about the one it would take")
        #expect(await store.letGoneGo() == 1)
        #expect(await ids(store) == ["fine", "kept"])
        #expect(await store.note(key("kept"))?.goneSince == origin, "still marked, for as long as it is kept")
        #expect(await store.letGoneGo(markedBy: origin.addingTimeInterval(86_400)) == 0, "and no wait reaches it either")
        #expect(await store.goneCount() == 0)
    }

    @Test("A kept post the person took back at its source stays, marked gone from then; one not kept goes as before")
    func takenBackStaysMarked() async {
        let store = ItemStore(sources: [alpha], notes: [note("kept"), note("other")])
        await store.setKept(true, for: key("kept"))

        await store.forget(key("kept"), at: origin)
        await store.forget(key("other"), at: origin)

        #expect(await ids(store) == ["kept"])
        #expect(await store.note(key("kept"))?.goneSince == origin)
        let revision = await store.revision
        await store.forget(key("kept"), at: origin.addingTimeInterval(60))
        #expect(await store.note(key("kept"))?.goneSince == origin, "the first moment is the one kept")
        #expect(await store.revision == revision)
    }

    @Test("A place settled beside a kept post marked gone is counted as a place, and goes as a mark; the post stays")
    func keptGonePlacesAreCounted() async {
        var marked = note("kept")
        marked.gaps = [TimelineGap(.settled, in: .public, since: origin)]
        let store = ItemStore(sources: [alpha], notes: [marked])
        await store.setKept(true, for: key("kept"))
        await store.markGone(key("kept"), at: origin)

        #expect(await store.goneCount() == 0)
        #expect(await store.settledCount() == 1)
        #expect(await store.letGoneGo() == 0)
        #expect(await store.letSettledGo() == 1)
        #expect(await store.note(key("kept"))?.gaps.isEmpty == true)
    }

    // MARK: - Un-keeping

    @Test("Un-keeping makes it an ordinary item from that moment: nothing goes by the press, and everything reaches it after")
    func unkeptIsOrdinary() async {
        let store = ItemStore(sources: [alpha], notes: [note("was-kept", daysAgo: 400), note("new")])
        await store.setKept(true, for: key("was-kept"))
        await store.setRetention(months: 1, from: origin, calendar: utc)
        await store.markGone(key("was-kept"), at: origin)

        #expect(await store.setKept(false, for: key("was-kept")))
        #expect(await ids(store) == ["new", "was-kept"], "the press itself lets nothing go")
        #expect(await store.note(key("was-kept"))?.kept == false)
        #expect(await store.goneCount() == 1, "and it is counted like any other from here")

        let day = origin.addingTimeInterval(-401 * 86_400)..<origin.addingTimeInterval(-399 * 86_400)
        #expect(await store.count(span: day) == 1)
        #expect(await store.letGoBeyond(months: 1, from: origin, calendar: utc).posts == 1)
        #expect(await ids(store) == ["new"])
    }

    @Test("A kept post whose source was removed is un-kept like any other, and then goes like one")
    func unkeptAfterRemoval() async {
        let store = ItemStore(sources: [alpha], notes: [note("kept")])
        await store.setKept(true, for: key("kept"))
        await store.remove(host: alpha.host)
        #expect(await store.setKept(false, for: key("kept")))
        #expect(await store.letGoOldest(count: 1).posts == 1)
        #expect(await ids(store).isEmpty)
    }

    // MARK: - Carried

    @Test("Kept rides a snapshot into a new store, and a read back takes a kept post in past the window")
    func ridesASnapshot() async {
        let store = ItemStore(sources: [alpha], notes: [note("kept", daysAgo: 400), note("old", daysAgo: 400)])
        await store.setKept(true, for: key("kept"))
        let taken = await store.snapshot()
        #expect(taken.notes.first { $0.id == "kept" }?.kept == true)

        let relaunched = ItemStore(sources: taken.sources, notes: taken.notes)
        #expect(await relaunched.note(key("kept"))?.kept == true)

        let other = ItemStore()
        await other.setRetention(months: 1, from: origin, calendar: utc)
        await other.replace(sources: taken.sources, notes: taken.notes)
        #expect(await ids(other) == ["kept"])
        #expect(await other.note(key("kept"))?.kept == true)
    }
}
