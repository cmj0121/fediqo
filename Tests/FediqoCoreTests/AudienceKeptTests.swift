import Foundation
import Testing
@testable import FediqoCore

/// #208 — what a post's source said of it is not lost to a copy that says less, and a row that
/// never heard it takes it from the next copy that says it.
///
/// A row kept before audience was written down is a row whose audience is nothing: that is how
/// a relaunch hands it back (`StoreFile`'s own tests pin that half), so it is built that way here.
@Suite("What a post's source said, kept")
struct AudienceKeptTests {
    private let source = Source(host: "first.example", kind: .mastodon)
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func copy(
        audience: Audience? = nil,
        holding: Holding = .arrived,
        boosted: Bool? = nil,
        favourited: Bool? = nil,
        sensitive: Bool? = nil,
        spoiler: String? = nil,
        board: String? = nil,
        counts: Counts = Counts(),
        statusID: String? = nil
    ) -> Note {
        Note(
            id: "https://first.example/1", source: source, author: "Ada", handle: "@ada@first.example",
            body: "hello", board: board, postedAt: origin, categories: [.home],
            boosted: boosted, favourited: favourited, audience: audience, sensitive: sensitive,
            spoiler: spoiler, counts: counts, statusID: statusID, holding: holding
        )
    }

    @Test("A row kept without its audience takes it from the next timeline that brings it, and is drawn anew")
    func timelineRestoresAudience() async {
        let store = ItemStore(sources: [source], notes: [copy()])
        let drawn = await store.drawn
        let revision = await store.revision
        await store.ingest([copy(audience: .followers)])
        #expect(await store.all().first?.audience == .followers)
        #expect(await store.drawn > drawn, "the row's mark is drawn")
        #expect(await store.revision > revision, "and written down")
    }

    @Test("A row held aside takes its audience the same way, and what is held aside says it changed")
    func asideRestoresAudience() async {
        let store = ItemStore(sources: [source], notes: [copy(holding: .aside)])
        let aside = await store.asideRevision
        let drawn = await store.drawn
        await store.hold([copy(audience: .mentioned)], ifSourceHere: source.host)
        #expect(await store.aside().first?.audience == .mentioned)
        #expect(await store.asideRevision > aside)
        #expect(await store.drawn == drawn, "no timeline draws a row held aside")
    }

    @Test("A timeline copy that says nothing of audience leaves the one held, and says nothing moved")
    func silentTimelineKeepsAudience() async {
        let store = ItemStore(sources: [source], notes: [copy(audience: .unlisted)])
        let revision = await store.revision
        await store.ingest([copy()])
        #expect(await store.all().first?.audience == .unlisted)
        #expect(await store.revision == revision)
    }

    @Test("A timeline copy saying another audience does not overwrite the first copy's")
    func firstCopyWins() async {
        let store = ItemStore(sources: [source], notes: [copy(audience: .everyone)])
        await store.ingest([copy(audience: .followers)])
        #expect(await store.all().first?.audience == .everyone)
    }

    @Test("A read again that says nothing of audience leaves the one held; one that says, says")
    func readAgainKeepsAudience() async {
        let store = ItemStore(sources: [source], notes: [copy(audience: .followers)])
        #expect(await store.refresh([copy()], ifSourceHere: source.host) == false)
        #expect(await store.all().first?.audience == .followers)
        #expect(await store.refresh([copy(audience: .everyone)], ifSourceHere: source.host))
        #expect(await store.all().first?.audience == .everyone)
    }

    @Test("A row with no counts takes them from the next timeline, each count apart, and a read again leaves the unsaid ones")
    func countsFilledAndKept() async {
        let store = ItemStore(sources: [source], notes: [copy(counts: Counts(replies: 2))])
        await store.ingest([copy(counts: Counts(replies: 9, reblogs: 1, favourites: 4))])
        #expect(await store.all().first?.counts == Counts(replies: 2, reblogs: 1, favourites: 4))
        await store.refresh([copy(counts: Counts(replies: 5))], ifSourceHere: source.host)
        #expect(await store.all().first?.counts == Counts(replies: 5, reblogs: 1, favourites: 4))
    }

    @Test("A row kept without boost, favourite or its server's id takes each from the next timeline")
    func olderFactsFilled() async {
        let store = ItemStore(sources: [source], notes: [copy()])
        await store.ingest([copy(boosted: true, favourited: false, statusID: "10942")])
        let held = await store.all().first
        #expect(held?.boosted == true)
        #expect(held?.favourited == false)
        #expect(held?.statusID == "10942")
    }

    @Test("A row with no cover or board takes them from a copy that says; a held one is not overwritten")
    func coverAndBoardFilled() async {
        let store = ItemStore(sources: [source], notes: [copy(sensitive: false)])
        await store.ingest([copy(sensitive: true, spoiler: "cw", board: "Talk")])
        let held = await store.all().first
        #expect(held?.sensitive == false, "the first copy's word stands")
        #expect(held?.spoiler == "cw")
        #expect(held?.board == "Talk")
    }

    @Test("A read again that says nothing of the cover leaves the one held")
    func readAgainKeepsCover() async {
        let store = ItemStore(sources: [source], notes: [copy(sensitive: true, spoiler: "cw")])
        #expect(await store.refresh([copy()], ifSourceHere: source.host) == false)
        let held = await store.all().first
        #expect(held?.sensitive == true)
        #expect(held?.spoiler == "cw")
    }

    @Test("A booster is never filled in: an original is not drawn as a boost because a boost of it came later")
    func boosterNotFilled() async {
        let store = ItemStore(sources: [source], notes: [copy()])
        let boost = Note(
            id: "https://first.example/1", source: source, author: "Ada", handle: "@ada@first.example",
            body: "hello", postedAt: origin, categories: [.home], boostedBy: "Bob",
            boosterHandle: "@bob@first.example"
        )
        await store.ingest([boost])
        #expect(await store.all().first?.boostedBy == nil)
        #expect(await store.all().first?.boosterHandle == nil)
    }
}
