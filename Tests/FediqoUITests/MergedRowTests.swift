import FediqoCore
import Foundation
import Testing

@testable import FediqoUI

/// One post held from two sources is one row that names both (#114).
///
/// **Through the store, not beside it.** The row is the copy that arrived first, and which one
/// that was is the store's to say — so the copies are taken in by `ItemStore.ingest` in a known
/// order and the list is drawn from `all()`, which is what the timeline draws from.
@MainActor
@Suite("A merged row")
struct MergedRowTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    // `second` sorts after `first` by name, and is taken in first on purpose throughout, so an
    // answer that fell back on the host's spelling would be caught.
    private let first = Source(host: "first.example", kind: .mastodon)
    private let second = Source(host: "second.example", kind: .mastodon)
    private let written = "https://origin.example/users/ada/statuses/1"

    @Test("A post held from two sources draws as one row that names both")
    func oneRowNamesBoth() async {
        let items = TimelineQuery.all.items(from: await held(), latest: nil)

        #expect(items.count == 2, "the shared post once, and the post only one source carried")
        let shared = items.first { $0.noteID == written }
        #expect(shared?.sources.map(\.host) == ["second.example", "first.example"])
        #expect(shared.map { DummyItemRow.drawnSource($0, language: .english) } == "second.example +1")
        #expect(shared.map { DummyItemRow.spokenSource($0, language: .english) }
            == "second.example, also from first.example")

        // A post one source carried draws and says its host alone, as it always did.
        let alone = items.first { $0.noteID != written }
        #expect(alone.map { DummyItemRow.drawnSource($0, language: .english) } == "first.example")
        #expect(alone.map { DummyItemRow.spokenSource($0, language: .english) } == "first.example")
    }

    @Test("The row is the copy that arrived first, and keeps the id that copy always had")
    func theRowIsTheFirstCopy() async {
        let shared = TimelineQuery.all.items(from: await held(), latest: nil).first { $0.noteID == written }

        #expect(shared?.source.host == "second.example")
        #expect(shared?.body == "as second carried it")
        #expect(shared?.id == NoteKey(host: "second.example", id: written).rowID)

        // The other way about, so the first is not the second by accident.
        let store = ItemStore()
        await store.ingest([copy(from: first, body: "as first carried it")])
        await store.ingest([copy(from: second, body: "as second carried it")])
        let turned = TimelineQuery.all.items(from: await store.all(), latest: nil)
        #expect(turned.map(\.source.host) == ["first.example"])
        #expect(turned.first?.body == "as first carried it")
    }

    @Test("Opening it shows what each source carried, told apart by source")
    func openingShowsEachCopy() async {
        let shared = TimelineQuery.all.items(from: await held(), latest: nil).first { $0.noteID == written }
        let copies = shared?.copies ?? []

        #expect(copies.map(\.source.host) == ["second.example", "first.example"])
        #expect(copies.map(\.body) == ["as second carried it", "as first carried it"])
        #expect(copies.allSatisfy { $0.otherCopies.isEmpty }, "a copy carries no copies of its own")
        let lines = copies.map { DummyThreadPane.carriedWords($0, language: .english) }
        #expect(lines[0].contains("as second carried it") && !lines[0].contains("as first carried it"))
        #expect(lines[1].contains("as first carried it") && !lines[1].contains("as second carried it"))
    }

    @Test("A covered copy is compared by its cover, and never uncovered by the comparison")
    func aCoveredCopyStaysCovered() {
        let covered = DummyItem(Note(
            id: written, source: first, author: "Ada", handle: "@ada@origin.example",
            body: "under the cover", postedAt: origin, categories: [.public],
            sensitive: true, spoiler: "a line"
        ))
        let line = DummyThreadPane.carriedWords(covered, language: .english)
        #expect(!line.contains("under the cover"))
        #expect(line.contains("a line"))
    }

    @Test("The keys walk the merged row once, and a mark keyed by it acts once")
    func oneRowForTheKeysAndTheMarks() async {
        let items = TimelineQuery.all.items(from: await held(), latest: nil)
        let ids = items.map(\.id)

        // Every stop `j` makes, from the top to the bottom.
        var walked: [String] = []
        var at: String? = nil
        while let next = DummyCommand.stepped(ids, from: at, by: 1), next != at {
            walked.append(next)
            at = next
        }
        #expect(walked == ids)
        #expect(Set(walked).count == 2)
        // The second copy's own row is nowhere a key or a mark could land.
        #expect(!ids.contains(NoteKey(host: "first.example", id: written).rowID))
    }

    @Test("A timeline whose rule reaches only one of the two still shows the row")
    func aRuleReachingOneCopyShowsTheRow() async throws {
        let onlyFirst = TimelineDefinition(name: "first", rules: [try #require(Rule.source("first.example"))])
        let items = TimelineQuery.written(onlyFirst.id)
            .items(from: await held(), among: [onlyFirst], latest: nil)

        let shared = items.first { $0.noteID == written }
        #expect(shared != nil)
        // Drawn as the copy the rule let through, and naming only the source it came from: the
        // other copy is one the reader's rule did not reach.
        #expect(shared?.source.host == "first.example")
        #expect(shared?.sources.map(\.host) == ["first.example"])
    }

    @Test("Search draws a merged row once, as the timeline does")
    func searchMergesToo() async {
        let notes = await held()
        #expect(DummyItem.merged(notes).count == TimelineQuery.all.items(from: notes, latest: nil).count)
    }

    @Test("Every language names the other sources")
    func everyLanguageSaysIt() async {
        let shared = TimelineQuery.all.items(from: await held(), latest: nil).first { $0.noteID == written }
        for language in [DummyLanguage.english, .taiwanese] {
            let spoken = shared.map { DummyItemRow.spokenSource($0, language: language) } ?? ""
            #expect(spoken.contains("second.example") && spoken.contains("first.example"), "\(language)")
            #expect(!spoken.contains("item.source"), "\(language): a key, not a sentence")
            #expect(!L10n.t("thread.copies.title", language: language).hasPrefix("thread."))
        }
    }

    /// Two copies of one post, `second`'s taken in first, and one post only `first` carried.
    private func held() async -> [Note] {
        let store = ItemStore()
        await store.add(first)
        await store.add(second)
        await store.ingest([copy(from: second, body: "as second carried it")])
        await store.ingest([
            copy(from: first, body: "as first carried it"),
            Note(
                id: "https://first.example/users/bob/statuses/9", source: first, author: "Bob",
                handle: "@bob@first.example", body: "only here", postedAt: origin.addingTimeInterval(-60),
                categories: [.public]
            ),
        ])
        return await store.all()
    }

    private func copy(from source: Source, body: String) -> Note {
        Note(
            id: written, source: source, author: "Ada", handle: "@ada@origin.example", body: body,
            postedAt: origin, categories: [.public]
        )
    }
}
