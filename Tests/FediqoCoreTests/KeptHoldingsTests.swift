import Foundation
import Testing
@testable import FediqoCore

/// The person can see what they keep, and let all of it go at once (#294), in the half Core
/// holds: what is kept counted and weighed by source, the one act that stops keeping, the counts
/// a question names, and the count a package's header carries.
@Suite("What is kept, counted, and let be ordinary again")
struct KeptHoldingsTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let two = Source(host: "two.example", kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private static func post(
        _ id: Int, _ source: Source = one, body: String = "hello", kept: Bool = false, title: String? = nil,
        spoiler: String? = nil, earlier: [Wording] = []
    ) -> Note {
        Note(
            id: "https://\(source.host)/\(id)", source: source, author: "Ada", handle: "@ada", body: body,
            title: title, postedAt: origin.addingTimeInterval(Double(id) * 86_400), categories: [.public],
            spoiler: spoiler, statusID: "\(id)", kept: kept,
            editedAt: earlier.isEmpty ? nil : origin, earlier: earlier
        )
    }

    private static func store(_ notes: [Note]) -> ItemStore {
        ItemStore(sources: [one, two], notes: notes)
    }

    // MARK: - Counted and weighed

    @Test("What is kept is counted by source and in all, a removed source's under its name, and a source with nothing kept is absent")
    func countedBySource() async {
        let notes = [
            Self.post(1, kept: true), Self.post(2, kept: true), Self.post(3),
            Self.post(4, Self.two, kept: true), Self.post(5, Self.two),
        ]
        let store = Self.store(notes)
        var holdings = Holdings(notes: await store.all(), per: .month)
        #expect(holdings.kept.posts == 3)
        #expect(holdings.kept(host: "ONE.example").posts == 2 && holdings.kept(host: Self.two.host).posts == 1)
        #expect(holdings.kept(host: "nobody.example") == .none)

        await store.remove(host: Self.one.host)
        holdings = Holdings(notes: await store.all(), per: .month)
        #expect(holdings.posts(host: Self.one.host) == 2, "the premise: only its kept posts stayed")
        #expect(holdings.kept(host: Self.one.host).posts == 2, "a removed source's kept posts are not counted under its name")
        #expect(holdings.keptBySource.keys.sorted() == [Self.one.host, Self.two.host])
        #expect(Holdings(notes: [Self.post(1)], per: .month).keptBySource.isEmpty)
    }

    @Test("What kept posts weigh is their words — body, title, warning and every earlier wording — and nothing of a post not kept")
    func weighed() {
        let was = Wording(body: "before", spoiler: "cw", until: Self.origin)
        let notes = [
            Self.post(1, body: "héllo", kept: true, title: "t", spoiler: "sp", earlier: [was, was]),
            Self.post(2, body: String(repeating: "x", count: 10_000)),
            Self.post(3, Self.two, body: "four", kept: true),
        ]
        let holdings = Holdings(notes: notes, per: .month)
        let first = "héllo".utf8.count + 1 + 2 + 2 * ("before".utf8.count + 2)
        #expect(holdings.kept(host: Self.one.host) == Holdings.Kept(posts: 1, bytes: first))
        #expect(holdings.kept(host: Self.two.host).bytes == 4)
        #expect(holdings.kept == Holdings.Kept(posts: 2, bytes: first + 4))
    }

    @Test("A kept post two sources carry is counted for each as kept through another source too; one only one of them keeps, or that only one carries, is not")
    func keptThroughAnotherSource() {
        func copy(_ name: String, _ source: Source, kept: Bool) -> Note {
            Note(
                id: "https://origin.example/\(name)", source: source, author: "Ada", handle: "@ada", body: name,
                postedAt: Self.origin, categories: [.public], statusID: "\(source.host)-\(name)", kept: kept
            )
        }
        let holdings = Holdings(notes: [
            copy("both", Self.one, kept: true), copy("both", Self.two, kept: true),
            copy("half", Self.one, kept: true), copy("half", Self.two, kept: false),
            copy("mine", Self.one, kept: true),
        ], per: .month)
        #expect(holdings.kept(host: Self.one.host).posts == 3 && holdings.kept(host: Self.two.host).posts == 1)
        #expect(holdings.keptElsewhere(host: Self.one.host) == 1, "only the post both keep")
        #expect(holdings.keptElsewhere(host: Self.two.host) == 1)
        #expect(holdings.keptElsewhere(host: "nobody.example") == 0)
        #expect(Holdings(notes: [copy("mine", Self.one, kept: true)], per: .month).keptElsewhereBySource.isEmpty)
    }

    // MARK: - Stop keeping

    @Test("Stopping keeping one source's posts un-keeps exactly those, in one change, and lets nothing go; the next letting go takes them")
    func stopKeepingOneSource() async {
        let store = Self.store([
            Self.post(1, kept: true), Self.post(2, kept: true), Self.post(3),
            Self.post(4, Self.two, kept: true),
        ])
        let revision = await store.revision
        #expect(await store.stopKeeping(host: "ONE.example") == 2)
        #expect(await store.revision == revision + 1, "one act, one change")
        let after = await store.all()
        #expect(after.count == 4, "stopping keeping let something go")
        #expect(after.filter(\.kept).map(\.key.host) == [Self.two.host])

        #expect(await store.stopKeeping(host: Self.one.host) == 0)
        #expect(await store.revision == revision + 1, "nothing kept, nothing changed")

        // Ordinary now: a span let go takes them, and still leaves the one kept.
        let all = Self.origin..<Self.origin.addingTimeInterval(100 * 86_400)
        #expect(await store.letGo(span: all) == 3)
        #expect(await store.all().map(\.key.host) == [Self.two.host])
    }

    @Test("Stopping keeping all reaches every source, one removed included; the oldest then go for room like any others")
    func stopKeepingAll() async {
        let store = Self.store([
            Self.post(1, kept: true), Self.post(2, Self.two, kept: true),
            Self.post(3, Self.two, kept: true), Self.post(4),
        ])
        await store.remove(host: Self.one.host)
        #expect(Set(await store.all().map(\.key.host)) == [Self.one.host, Self.two.host], "the premise: the removed source's kept post stayed")
        #expect(await store.holdsWhatRoomMayLetGo() == false, "the premise: everything left is kept")

        #expect(await store.stopKeeping() == 3)
        let left = await store.all()
        #expect(left.allSatisfy { !$0.kept })
        #expect(await store.holdsWhatRoomMayLetGo())
        #expect(await store.letGoOldest(count: 3).posts == 3)
    }

    // MARK: - What a question names

    @Test("How many kept posts a span would leave, and how many marked gone, are counted beside what would go")
    func whatStays() async {
        let store = Self.store([
            Self.post(1, kept: true), Self.post(2), Self.post(3, Self.two, kept: true), Self.post(40, kept: true),
        ])
        let span = Self.origin..<Self.origin.addingTimeInterval(10 * 86_400)
        #expect(await store.count(span: span) == 1)
        #expect(await store.keptCount(span: span) == 2)
        #expect(await store.keptCount(span: span, host: "TWO.example") == 1)
        #expect(await store.keptCount(span: span, host: "nobody.example") == 0)

        #expect(await store.keptGoneCount() == 0)
        for note in await store.all() where note.statusID != "40" { await store.markGone(note.key) }
        #expect(await store.goneCount() == 1)
        #expect(await store.keptGoneCount() == 2)
    }

    // MARK: - What a package's header carries

    private static func summary(kept: Int?) -> PackageSummary {
        PackageSummary(
            sources: [.init(host: one.host, kind: .mastodon)], posts: 12, timelines: 2, takenAt: origin,
            withPictures: false, bytes: 100, hasSecrets: false, device: "a test", appVersion: "0.1.0",
            entryCount: 3, kept: kept
        )
    }

    private static let prelude = PackageFormat.Prelude(
        keying: .password, salt: Data(), rounds: 1, noncePrefix: Data(), takenAt: origin, withPictures: false, bytes: 100
    )

    @Test("The header says how many posts are kept under one more name: a header without it reads as not saying, and a build that does not know the name reads the rest as before")
    func theHeader() throws {
        let said = try JSONEncoder().encode(PackageSummary.Header(Self.summary(kept: 5)))
        #expect(try JSONDecoder().decode(PackageSummary.Header.self, from: said).summary(Self.prelude).kept == 5)

        // What a build before this one wrote: every name but that one.
        let older = try JSONEncoder().encode(PackageSummary.Header(Self.summary(kept: nil)))
        #expect(String(decoding: older, as: UTF8.self).contains("kept") == false)
        let read = try JSONDecoder().decode(PackageSummary.Header.self, from: older).summary(Self.prelude)
        #expect(read.kept == nil && read.posts == 12)

        // What a build before this one reads of ours: its own names, the new one passed over.
        struct Before: Decodable { let contents: String; let posts: Int; let entryCount: Int }
        let theirs = try JSONDecoder().decode(Before.self, from: said)
        #expect(theirs.posts == 12 && theirs.contents == "whole" && theirs.entryCount == 3)
    }

    @Test("A header counting more kept posts than posts, or fewer than none, is not as written")
    func aHeaderThatDoesNotAddUp() throws {
        for kept in [13, -1] {
            let header = PackageSummary.Header(Self.summary(kept: kept))
            #expect(throws: PackageRefusal.altered) { try header.summary(Self.prelude) }
        }
        #expect(try PackageSummary.Header(Self.summary(kept: 12)).summary(Self.prelude).kept == 12)
        #expect(try PackageSummary.Header(Self.summary(kept: 0)).summary(Self.prelude).kept == 0)
    }

    @Test("The count rides to a device nearby with the rest of the summary, and one that says none rides as saying none")
    func onTheWire() throws {
        for kept in [Int?.some(4), nil] {
            let summary = Self.summary(kept: kept)
            let read = try JSONDecoder().decode(PackageSummary.self, from: try JSONEncoder().encode(summary))
            #expect(read == summary && read.kept == kept)
        }
    }
}
