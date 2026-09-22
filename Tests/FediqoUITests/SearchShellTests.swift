import Foundation
import FediqoCore
import Testing
@testable import FediqoUI

/// #32: `/` opens a search over what this device holds, and Escape gives the timeline back.
@Suite("Searching from the timeline")
@MainActor
struct SearchShellTests {
    private let one = Source(host: "one.example", kind: .mastodon)

    private func note(
        _ id: String, _ body: String, at postedAt: Date = Date(timeIntervalSince1970: 0),
        _ categories: Set<FediqoCore.Category> = [.public]
    ) -> Note {
        Note(id: id, source: one, author: "Ada", handle: "@ada@one.example", body: body,
             postedAt: postedAt, categories: categories)
    }

    private func ids(_ items: [DummyItem]?) -> [String]? {
        items?.map(\.noteID)
    }

    /// What `search` finds on All — every post held, which is what #32 searched before a search
    /// was asked of the timeline in front (#145).
    private func onAll(
        _ search: ShellSearch, _ notes: [Note], revision: Int, sources: [Source], latest: LatestDate?
    ) -> [DummyItem]? {
        search.items(in: .all, text: TextIndex([]), from: notes, revision: revision, sources: sources, latest: latest)
    }

    /// An open search over `notes`, its index landed, searching `pattern`.
    private func searching(_ pattern: String, over notes: [Note], from selection: String? = nil) async -> ShellSearch {
        let search = ShellSearch()
        search.open(from: selection, over: notes)
        await search.indexed()
        search.text = pattern
        search.settle(pattern)
        return search
    }

    // MARK: Keys

    @Test("`/` searches and `?` shows the keys list")
    func slashAndQuestion() {
        #expect(DummyCommand.from("/") == .search)
        #expect(DummyCommand.from("?") == .showShortcuts)
        #expect(DummyCommand.from("?", shift: true) == .showShortcuts)
        // A field with the keys owns `/`, and so does a draft.
        #expect(DummyCommand.from("/", fieldFocused: true) == nil)
        #expect(DummyCommand.from("/", typing: true) == nil)
        #expect(DummyCommand.from("/", command: true) == nil)
    }

    @Test("Shift-/ is the keys list on the ANSI slash key, and search where the layout shifts its /")
    func shiftedSlash() {
        // US: the `/` key with Shift, reported as `/` with Shift held, is asking for `?`.
        let ansi = DummyCommand.typed("/", shift: true, onSlashKey: true)
        #expect(DummyCommand.from(ansi, shift: true) == .showShortcuts)
        // German and Nordic Shift-7, AZERTY Shift-:: the `/` the reader typed.
        let shifted = DummyCommand.typed("/", shift: true, onSlashKey: false)
        #expect(DummyCommand.from(shifted, shift: true) == .search)
        // Without Shift the slash key is `/` on any layout; other keys are left as they are.
        #expect(DummyCommand.typed("/", shift: false, onSlashKey: true) == "/")
        #expect(DummyCommand.typed("?", shift: true, onSlashKey: false) == "?")
        #expect(DummyCommand.typed("j", shift: true, onSlashKey: true) == "j")
    }

    @Test("The keys list names `/` under Timeline, in both languages")
    func keysList() throws {
        let line = try #require(DummyShortcut.all.first { $0.commands == [.search] })
        #expect(line.group == .read)
        #expect(line.keys == ["/"])
        for language in [DummyLanguage.english, .taiwanese] {
            for key in ["shortcut.search", "search.placeholder", "search.label", "search.empty.title",
                        "search.empty.detail"] {
                #expect(L10n.t(key, language: language) != key, "\(key) \(language)")
            }
            #expect(L10n.t("search.found", language: language).contains("%d"))
        }
    }

    @Test("The two Chinese string files are the same bytes")
    func chineseFilesAgree() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        let tw = try Data(contentsOf: resources.appendingPathComponent("zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appendingPathComponent("zh-Hant.lproj/Localizable.strings"))
        #expect(tw == hant)
    }

    // MARK: Layers

    @Test("Escape leaves a thread opened from a result first, then the search, then the selection")
    func escapeOrder() {
        #expect(DummyCommand.outermost(of: [.search, .selection]) == .search)
        #expect(DummyCommand.outermost(of: [.thread, .search, .selection]) == .thread)
        #expect(DummyCommand.canOpen(.search, whenOpen: [.selection]))
        #expect(!DummyCommand.canOpen(.search, whenOpen: [.thread]))
        #expect(!DummyCommand.canOpen(.search, whenOpen: [.viewer]))
        #expect(!DummyCommand.canOpen(.search, whenOpen: [.shortcuts]))
        #expect(DummyCommand.canOpen(.thread, whenOpen: [.search, .selection]))
    }

    @Test("e opens the editor only over the timeline itself, with at most a post selected")
    func editOnlyOverTheTimeline() {
        #expect(DummyCommand.canEditTimeline(whenOpen: []))
        #expect(DummyCommand.canEditTimeline(whenOpen: [.selection]))
        #expect(!DummyCommand.canEditTimeline(whenOpen: [.search]))
        #expect(!DummyCommand.canEditTimeline(whenOpen: [.search, .selection]))
        #expect(!DummyCommand.canEditTimeline(whenOpen: [.thread, .selection]))
        #expect(!DummyCommand.canEditTimeline(whenOpen: [.viewer]))
        #expect(!DummyCommand.canEditTimeline(whenOpen: [.shortcuts]))
    }

    @Test("Closing the search gives back the timeline and the post selected before it")
    func escapeRestores() async {
        let notes = [note("a", "swift"), note("b", "other")]
        #expect(onAll(ShellSearch(), notes, revision: 0, sources: [one], latest: nil) == nil)

        let search = await searching("swift", over: notes, from: "row-b")
        #expect(ids(onAll(search, notes, revision: 0, sources: [one], latest: nil)) == ["a"])

        #expect(search.close() == "row-b")
        #expect(!search.isOpen)
        #expect(search.text.isEmpty)
        // Nothing to stand in for the timeline any more: it is drawn as it was.
        #expect(onAll(search, notes, revision: 0, sources: [one], latest: nil) == nil)
        // A second close has nothing to give back.
        #expect(search.close() == nil)
    }

    @Test("Emptying the field gives back the timeline and its selection at once, and keeps the search open")
    func clearingRestores() async {
        let notes = [note("a", "swift"), note("b", "other")]
        let search = await searching("swift", over: notes, from: "row-b")
        #expect(ids(onAll(search, notes, revision: 0, sources: [one], latest: nil)) == ["a"])

        search.text = ""
        // No pause to wait for: the timeline is back on the next draw.
        #expect(onAll(search, notes, revision: 0, sources: [one], latest: nil) == nil)
        #expect(search.selectionBefore == "row-b")
        #expect(search.isOpen)
        // Typing again searches again, and the selection to give back is still the first one.
        search.text = "other"
        search.settle("other")
        #expect(ids(onAll(search, notes, revision: 0, sources: [one], latest: nil)) == ["b"])
        #expect(search.close() == "row-b")
    }

    @Test("Leaving the Timeline page closes the search")
    func leavingCloses() async {
        let search = await searching("swift", over: [note("a", "swift")])
        #expect(!search.closes(leavingFor: .timeline))
        for place in ShellPlace.allCases where place != .timeline {
            #expect(search.closes(leavingFor: place), "\(place)")
        }
        _ = search.close()
        #expect(!search.closes(leavingFor: .account))
    }

    @Test("The notes are folded when the search opens, not while typing")
    func indexedOnOpen() async {
        let notes = [note("a", "swift"), note("b", "swiftui")]
        let search = ShellSearch()
        search.open(from: nil, over: notes)
        await search.indexed()
        #expect(search.isIndexed)
        search.text = "swift"
        search.settle("swift")
        #expect(ids(onAll(search, notes, revision: 0, sources: [one], latest: nil)) == ["a", "b"])
        // A note that arrived after the search opened is still found.
        let more = notes + [note("c", "Swift too")]
        #expect(ids(onAll(search, more, revision: 1, sources: [one], latest: nil)) == ["a", "b", "c"])
    }

    @Test("While the index is still being folded, a pattern shows an empty list that says it is searching")
    func searchingWhileIndexing() async {
        let notes = [note("a", "swift"), note("b", "other")]
        let search = ShellSearch()
        search.open(from: nil, over: notes)
        search.text = "swift"
        search.settle("swift")
        #expect(!search.isIndexed)
        #expect(search.isSearching)
        #expect(onAll(search, notes, revision: 0, sources: [one], latest: nil) == [], "not the timeline")
        await search.indexed()
        #expect(ids(onAll(search, notes, revision: 0, sources: [one], latest: nil)) == ["a"])
        for key in ["search.indexing.title", "search.indexing.detail"] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    @Test("A pattern of spaces alone is no search: the timeline stays")
    func spacesAlone() async {
        let notes = [note("a", "foot ball")]
        let search = await searching("   ", over: notes)
        #expect(!search.isSearching)
        #expect(onAll(search, notes, revision: 0, sources: [one], latest: nil) == nil)
    }

    @Test("Closing the search stops folding its index")
    func closeCancelsTheIndex() async {
        let search = ShellSearch()
        search.open(from: nil, over: [note("a", "swift")])
        _ = search.close()
        await search.indexed()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(!search.isIndexed, "the fold for a closed search did not land")
    }

    @Test("The results are kept per notes revision, not by comparing every note")
    func cachedPerRevision() async {
        let notes = [note("a", "swift"), note("b", "swiftui")]
        let search = await searching("swift", over: notes)
        #expect(ids(onAll(search, notes, revision: 3, sources: [one], latest: nil)) == ["a", "b"])
        let more = notes + [note("c", "swift too")]
        #expect(ids(onAll(search, more, revision: 3, sources: [one], latest: nil)) == ["a", "b"],
                "same revision: the kept answer")
        #expect(ids(onAll(search, more, revision: 4, sources: [one], latest: nil)) == ["a", "b", "c"])
    }

    @Test("Emptying the field gives the selection back only while the search is open")
    func clearedOnlyWhileOpen() async {
        let search = await searching("swift", over: [note("a", "swift")], from: "row-b")
        var restored: [String?] = []
        search.cleared { restored.append($0) }
        #expect(restored == ["row-b"])
        #expect(search.close() == "row-b")
        search.cleared { restored.append($0) }
        #expect(restored == ["row-b"], "closing's own emptying does not take the selection away again")
    }

    @Test("An open search with nothing typed shows the timeline, and a stale pause searches nothing")
    func typing() async {
        let notes = [note("a", "swift"), note("b", "swiftui")]
        let search = await searching("", over: notes)
        #expect(!search.isSearching)
        #expect(onAll(search, notes, revision: 0, sources: [one], latest: nil) == nil)

        search.text = "swift"
        // The pause for "swif" ended after "swift" was typed: it is not what the field says.
        search.settle("swif")
        #expect(onAll(search, notes, revision: 0, sources: [one], latest: nil) == nil)
        search.settle("swift")
        #expect(ids(onAll(search, notes, revision: 0, sources: [one], latest: nil)) == ["a", "b"])
        search.text = "swift?"
        search.settle("swift?")
        #expect(ids(onAll(search, notes, revision: 0, sources: [one], latest: nil)) == ["b"])
    }

    // MARK: What is found

    @Test("Public, trends and home are found by their English words and by their labels in both languages")
    func categoryLabels() async {
        let notes = [
            note("public", "x", [.public]), note("trends", "x", [.trends]), note("home", "x", [.home]),
        ]
        for (pattern, expected) in [
            ("trends", "trends"), ("Trends", "trends"), ("趨勢", "trends"),
            ("public", "public"), ("公開", "public"),
            ("home", "home"), ("首頁", "home"),
        ] {
            let search = await searching(pattern, over: notes)
            #expect(ids(onAll(search, notes, revision: 0, sources: [one], latest: nil)) == [expected], "\(pattern)")
        }
    }

    @Test("A list is found by its name")
    func listName() async {
        let source = Source(host: "one.example", kind: .mastodon, lists: [ListSubscription(id: "9", name: "Friends")])
        let post = Note(id: "l", source: source, author: "Ada", handle: "@ada@one.example", body: "x",
                        postedAt: Date(timeIntervalSince1970: 0), categories: [.list(id: "9")])
        let search = await searching("friend", over: [post])
        #expect(ids(onAll(search, [post], revision: 0, sources: [source], latest: nil)) == ["l"])
    }

    @Test("Results are in time order and stop at the latest date")
    func latestDate() async {
        let latest = LatestDate("2026-09-01")!
        let end = latest.end()
        let notes = [
            note("after", "swift", at: end),
            note("last", "swift", at: end.addingTimeInterval(-1)),
            note("older", "Swift", at: end.addingTimeInterval(-60)),
        ]
        let search = await searching("swift", over: notes)
        #expect(ids(onAll(search, notes, revision: 0, sources: [one], latest: latest)) == ["last", "older"])
        #expect(ids(onAll(search, notes, revision: 0, sources: [one], latest: nil)) == ["after", "last", "older"])
    }

    @Test("Searching sends no request to any source")
    func noRequest() async {
        L10n.language = .english
        let http = FixtureHTTP([
            "/": .text(#"<html><head><meta name="application-name" content="Mastodon"></head></html>"#),
            "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First"}"#),
            "/api/v1/timelines/public": .text(#"""
            [
              {"id": "1", "uri": "https://first.example/s/one", "created_at": "2024-01-01T00:00:00.000Z",
               "content": "<p>Football tonight #sport</p>", "visibility": "public",
               "account": {"username": "ada", "acct": "ada", "display_name": "Ada"}},
              {"id": "2", "uri": "https://first.example/s/two", "created_at": "2024-12-01T00:00:00.000Z",
               "content": "<p>Tea</p>", "visibility": "public",
               "account": {"username": "bo", "acct": "bo", "display_name": "Bo"}}
            ]
            """#),
        ])
        let session = ShellSession(http: http)
        session.hostname = "first.example"
        await session.add()
        await session.confirm()
        let asked = await http.requested.count

        let search = await searching("", over: session.notes)
        for pattern in ["football", "#sp*", "*", "nothing", "first.example", "public", "b?"] {
            search.text = pattern
            search.settle(pattern)
            _ = onAll(search, session.notes, revision: session.notesRevision, sources: session.sources, latest: nil)
        }
        search.text = "FOOT"
        search.settle("FOOT")
        #expect(ids(onAll(search, session.notes, revision: session.notesRevision, sources: session.sources, latest: nil)) == [
            "https://first.example/s/one",
        ])
        _ = search.close()
        #expect(await http.requested.count == asked)
    }
}
