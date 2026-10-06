import AppKit
import FediqoPersistence
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A post changed at its source gains a revision, and stays where it was (#286), from the session
/// up.
///
/// What a test can reach: a changed copy landing as a reload lands one, and the row staying in
/// its place with its new words and its mark; what the opened post offers of what it said before,
/// in order, with when, and under its cover; a timeline's keyword rule asked of what it says now;
/// what Usage counts; a relaunch; and every word in both languages. What it cannot: the mark and
/// the earlier wordings drawn in light and dark, on a Mac and a phone — that lives in view bodies.
@MainActor
@Suite("A changed post on its row and where it is opened", .serialized)
struct RevisionRowTests {
    private static let source = Source(host: "social.example", kind: .mastodon)
    private static let posted = Date(timeIntervalSince1970: 1_700_000_000)
    private static func at(_ minutes: Double) -> Date { posted.addingTimeInterval(minutes * 60) }

    /// A post as its source hands it over: `edited` minutes after it was published, or never.
    private static func copy(
        _ id: String, _ body: String, edited: Double? = nil, spoiler: String = "", daysAgo: Double = 0
    ) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada@social.example", body: body,
            postedAt: posted.addingTimeInterval(-daysAgo * 86_400), categories: [.public],
            spoiler: spoiler, statusID: id, editedAt: edited.map(at)
        )
    }

    /// A session holding three posts, the middle one the one that changes.
    private static func shell() async -> ShellSession {
        let store = ItemStore(sources: [source], notes: [
            copy("new", "the newest", daysAgo: 0), copy("9", "about apples", daysAgo: 1), copy("old", "the oldest", daysAgo: 2),
        ])
        let session = ShellSession(http: FixtureHTTP(), store: store)
        await session.reloadFromStore()
        return session
    }

    /// A changed copy of the middle post landing, as a reload's read lands one.
    private static func lands(_ session: ShellSession, _ body: String, edited: Double, spoiler: String = "") async {
        await session.store.ingest([copy("9", body, edited: edited, spoiler: spoiler, daysAgo: 1)], ifSourceHere: source.host)
        await session.reloadFromStore()
    }

    private static func row(_ session: ShellSession) throws -> DummyItem {
        try #require(session.timelineItems(latest: nil).first { $0.noteID == "9" })
    }

    // MARK: - Read, changed, read again

    @Test("Read, changed at its source, read again: the row is where it was, shows the new words, and says it was changed")
    func theRowStaysAndSaysSo() async throws {
        let session = await Self.shell()
        let before = try Self.row(session)
        #expect(before.editedAt == nil && before.earlier.isEmpty)
        #expect(session.timelineItems(latest: nil).map(\.noteID) == ["new", "9", "old"])

        await Self.lands(session, "about plums", edited: 30)

        let row = try Self.row(session)
        #expect(session.timelineItems(latest: nil).map(\.noteID) == ["new", "9", "old"], "a change moved the row")
        #expect(row.id == before.id, "the row became another row")
        #expect(row.postedAt == before.postedAt, "its age now reads when it changed")
        #expect(row.body == "about plums")
        #expect(row.editedAt == Self.at(30))
        #expect(row.earlier.map(\.body) == ["about apples"])
    }

    @Test("Read again with nothing changed adds nothing, and draws nothing again")
    func nothingChanged() async throws {
        let session = await Self.shell()
        await Self.lands(session, "about plums", edited: 30)
        let row = try Self.row(session)
        let drawn = await session.store.drawn

        await Self.lands(session, "about plums", edited: 30)

        #expect(try Self.row(session) == row)
        #expect(await session.store.drawn == drawn)
    }

    // MARK: - Where it is opened

    @Test("Opened, a post changed twice offers both earlier wordings in order, each with when its source said it changed", arguments: [DummyLanguage.english, .taiwanese])
    func openedOffersWhatItSaidBefore(language: DummyLanguage) async throws {
        let session = await Self.shell()
        await Self.lands(session, "about pears", edited: 30)
        await Self.lands(session, "about plums", edited: 90)
        let opened = try #require(session.held(try Self.row(session).id))

        let lines = EarlierWordings.lines(of: opened, lifted: false, language: language)

        try #require(lines.count == 2)
        #expect(lines.map(\.words) == ["about apples", "about pears"])
        #expect(lines.map(\.warning) == [nil, nil])
        #expect(lines[0].until.contains(EarlierWordings.when(Self.at(30), language: language)))
        #expect(lines[1].until.contains(EarlierWordings.when(Self.at(90), language: language)))
        #expect(lines[0].until != lines[1].until)
        #expect(!lines[0].until.contains("thread.earlier") && !lines[0].until.contains("%"))
    }

    @Test("A post already changed when first read says it was changed and offers no earlier wording; one never changed says nothing")
    func alreadyChanged() async throws {
        let store = ItemStore(sources: [Self.source], notes: [Self.copy("9", "as it is now", edited: 30), Self.copy("8", "never")])
        let session = ShellSession(http: FixtureHTTP(), store: store)
        await session.reloadFromStore()
        let changed = try Self.row(session)
        #expect(changed.editedAt == Self.at(30))
        #expect(EarlierWordings.lines(of: changed, lifted: true).isEmpty)
        let never = try #require(session.timelineItems(latest: nil).first { $0.noteID == "8" })
        #expect(never.editedAt == nil && never.earlier.isEmpty)
    }

    @Test("An earlier wording keeps its author's cover: its warning and not its words, until the reader lifts the post's cover")
    func anEarlierWordingKeepsItsCover() async throws {
        let session = await Self.shell()
        await Self.lands(session, "now in the open", edited: 30, spoiler: "")
        await session.store.ingest(
            [Self.copy("9", "under a warning", edited: 60, spoiler: "spiders", daysAgo: 1)], ifSourceHere: Self.source.host
        )
        await Self.lands(session, "in the open again", edited: 90)
        let opened = try Self.row(session)
        #expect(opened.earlier.map(\.body) == ["about apples", "now in the open", "under a warning"])

        let covered = EarlierWordings.lines(of: opened, lifted: false, language: .english)
        try #require(covered.count == 3)
        #expect(covered.map(\.words) == ["about apples", "now in the open", nil])
        #expect(covered[2].warning == "Author's warning: spiders")
        let lifted = EarlierWordings.lines(of: opened, lifted: true, language: .english)
        #expect(lifted.map(\.words) == ["about apples", "now in the open", "under a warning"])
        #expect(lifted[2].warning == "Author's warning: spiders", "lifted, it still says what it was covered with")

        // And every earlier wording of a post covered now is covered with it.
        await Self.lands(session, "covered now", edited: 120, spoiler: "mind")
        let now = try Self.row(session)
        #expect(EarlierWordings.lines(of: now, lifted: false).allSatisfy { $0.words == nil && $0.warning != nil })
    }

    @Test("A row two sources carried says what the copy it is drawn as said before")
    func aMergedRowShowsItsDrawnCopys() async throws {
        let other = Source(host: "second.example", kind: .mastodon)
        let uri = "https://origin.example/users/ada/statuses/1"
        func copy(_ source: Source, _ body: String, edited: Double? = nil) -> Note {
            Note(
                id: uri, source: source, author: "Ada", handle: "@ada@origin.example", body: body,
                postedAt: Self.posted, categories: [.public], spoiler: "", statusID: "1", editedAt: edited.map(Self.at)
            )
        }
        let store = ItemStore(sources: [Self.source, other], notes: [copy(Self.source, "as written"), copy(other, "as written")])
        let session = ShellSession(http: FixtureHTTP(), store: store)
        // Only the second server has heard of the change.
        await store.ingest([copy(other, "as changed", edited: 30)], ifSourceHere: other.host)
        await session.reloadFromStore()

        let merged = try #require(session.timelineItems(latest: nil).first)
        #expect(merged.copies.count == 2)
        #expect(merged.source.host == Self.source.host && merged.editedAt == nil && merged.earlier.isEmpty)
        #expect(merged.otherCopies.first?.earlier.map(\.body) == ["as written"])
    }

    @Test("A wording that was marked sensitive with no warning stays covered once the post is not, and its own Show it uncovers it: a post with no cover to lift still lets it be read")
    func aSensitiveWordingStaysCovered() async throws {
        func copy(_ body: String, sensitive: Bool, spoiler: String = "", edited: Double? = nil) -> Note {
            Note(
                id: "9", source: Self.source, author: "Ada", handle: "@ada@social.example", body: body,
                postedAt: Self.posted, categories: [.public], sensitive: sensitive, spoiler: spoiler,
                statusID: "9", editedAt: edited.map(Self.at)
            )
        }
        let store = ItemStore(sources: [Self.source], notes: [copy("sensitive, no warning", sensitive: true)])
        await store.ingest([copy("warned", sensitive: true, spoiler: "spiders", edited: 10)], ifSourceHere: Self.source.host)
        await store.ingest([copy("in the open now", sensitive: false, edited: 20)], ifSourceHere: Self.source.host)
        let session = ShellSession(http: FixtureHTTP(), store: store)
        await session.reloadFromStore()
        let opened = try Self.row(session)
        #expect(!opened.covered, "the post itself has no cover to lift")

        let lines = EarlierWordings.lines(of: opened, lifted: false, language: .english)
        try #require(lines.count == 2)
        #expect(lines.map(\.words) == [nil, nil], "an earlier wording its author had covered was shown in the open")
        #expect(lines.map(\.covered) == [true, true])
        #expect(lines[0].warning == "Covered" && lines[1].warning == "Author's warning: spiders")

        // Each has its own way to be uncovered, one at a time, and the same press covers it again.
        var shown = EarlierWordings.Shown()
        shown.toggle(lines[0].id)
        let one = EarlierWordings.lines(of: opened, lifted: false, shown: shown, language: .english)
        #expect(one.map(\.words) == ["sensitive, no warning", nil])
        #expect(one[0].warning == nil && !one[0].covered && one[0].pressedOpen)
        #expect(!one[1].pressedOpen)
        shown.toggle(lines[1].id)
        let both = EarlierWordings.lines(of: opened, lifted: false, shown: shown, language: .english)
        #expect(both.map(\.words) == ["sensitive, no warning", "warned"])
        shown.toggle(lines[0].id)
        #expect(EarlierWordings.lines(of: opened, lifted: false, shown: shown).map(\.words) == [nil, "warned"], "a second press did not cover it again")
        // A wording never covered offers neither press.
        #expect(lines.allSatisfy { !$0.pressedOpen })
        for language in [DummyLanguage.english, .taiwanese] {
            #expect(L10n.t("item.covered.show", language: language) != "item.covered.show")
            #expect(L10n.t("item.covered.again", language: language) != "item.covered.again")
        }
    }

    @Test("A wording uncovered by a press stays the one uncovered when another arrives or the oldest goes: no wording is shown that nobody pressed")
    func aPressFollowsItsWording() async throws {
        func covered(_ body: String, until: Double) -> Wording {
            Wording(body: body, spoiler: "mind", sensitive: true, until: Self.at(until))
        }
        func opened(_ earlier: [Wording]) -> DummyItem {
            DummyItem(Note(
                id: "9", source: Self.source, author: "Ada", handle: "@ada@social.example", body: "now",
                postedAt: Self.posted, categories: [.public], sensitive: false, spoiler: "", statusID: "9",
                editedAt: Self.at(99), earlier: earlier
            ))
        }
        let (first, second, third) = (covered("first", until: 1), covered("second", until: 2), covered("third", until: 3))
        var shown = EarlierWordings.Shown()
        shown.toggle(EarlierWordings.Key(second))
        #expect(EarlierWordings.lines(of: opened([first, second]), lifted: false, shown: shown).map(\.words) == [nil, "second"])

        // The oldest goes for the bound while the pane is open: `second` is now in the first place.
        #expect(EarlierWordings.lines(of: opened([second, third]), lifted: false, shown: shown).map(\.words) == ["second", nil],
                "the press moved to whatever took its place")
        // Another arrives ahead of it in the list.
        let zeroth = covered("zeroth", until: 0.5)
        #expect(EarlierWordings.lines(of: opened([zeroth, first, second, third]), lifted: false, shown: shown).map(\.words)
            == [nil, nil, "second", nil])
        // The same words at another moment are another wording.
        #expect(EarlierWordings.lines(of: opened([covered("second", until: 7)]), lifted: false, shown: shown).map(\.words) == [nil])
        // And one line is one wording: every line's identity is its own.
        let ids = EarlierWordings.lines(of: opened([zeroth, first, second, third]), lifted: false).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Putting the post's own cover back covers every earlier wording again, the ones shown one by one included")
    func theCoverGoingBackCoversThemAll() throws {
        let wording = Wording(body: "under it", spoiler: "mind", sensitive: true, until: Self.at(1))
        let opened = DummyItem(Note(
            id: "9", source: Self.source, author: "Ada", handle: "@ada@social.example", body: "now",
            postedAt: Self.posted, categories: [.public], sensitive: true, spoiler: "mind", statusID: "9",
            editedAt: Self.at(9), earlier: [wording]
        ))
        var shown = EarlierWordings.Shown()
        shown.toggle(EarlierWordings.Key(wording))
        #expect(EarlierWordings.lines(of: opened, lifted: false, shown: shown).map(\.words) == ["under it"])

        // The post's cover lifted changes nothing a press did; put back, the press is undone.
        shown.postCover(lifted: true)
        #expect(shown.contains(EarlierWordings.Key(wording)))
        #expect(EarlierWordings.lines(of: opened, lifted: true, shown: shown).allSatisfy { !$0.pressedOpen }, "lifted, there is nothing to cover again one by one")
        shown.postCover(lifted: false)
        #expect(shown == EarlierWordings.Shown())
        #expect(EarlierWordings.lines(of: opened, lifted: false, shown: shown).map(\.words) == [nil], "a wording stayed open under a cover put back")
    }

    // MARK: - A rule is asked of what it says now

    @Test("A timeline whose keyword rule matched only the earlier wording no longer shows the post, and one matching the new wording does")
    func aKeywordTimelineReadsWhatItSaysNow() async throws {
        let session = await Self.shell()
        func timeline(_ word: String) throws -> [String] {
            var draft = TimelineDraft(new: 1)
            draft.name = word
            draft.rules = [try #require(Rule.keyword(word, in: .every))]
            session.commit(draft)
            return session.timelineItems(latest: nil).map(\.noteID)
        }
        #expect(try timeline("apples") == ["9"])

        await Self.lands(session, "about plums", edited: 30)

        #expect(session.timelineItems(latest: nil).isEmpty, "a rule matched a wording the post no longer says")
        #expect(try timeline("plums") == ["9"])
        let search = try #require(NoteSearch("apples", sources: session.sources))
        #expect(search.found(session.notes, SearchIndex(session.notes)).isEmpty)
    }

    // MARK: - Part of what the device holds

    @Test("Usage counts what changed posts said before, and says nothing of it where none did", arguments: [DummyLanguage.english, .taiwanese])
    func usageCountsThem(language: DummyLanguage) async throws {
        let session = await Self.shell()
        #expect(session.holdings.earlier == 0)
        #expect(UsagePane.earlierFigure(session.holdings.earlier, language: language) == nil)

        await Self.lands(session, "about pears", edited: 30)
        #expect(session.holdings.earlier == 1)
        let one = try #require(UsagePane.earlierFigure(1, language: language))
        await Self.lands(session, "about plums", edited: 90)
        #expect(session.holdings.earlier == 2 && session.holdings.posts == 3)
        let two = try #require(UsagePane.earlierFigure(2, language: language))
        #expect(one.contains("1") && two.contains("2") && !two.contains("prefs.held"))
        #expect(L10n.t("prefs.held.earlier", language: language) != "prefs.held.earlier")
    }

    @Test("Letting the item go lets its earlier wordings go with it, from the session and from what Usage counts")
    func theyGoWithTheItem() async throws {
        let session = await Self.shell()
        await Self.lands(session, "about plums", edited: 30)
        #expect(session.holdings.earlier == 1)

        let day = Self.posted.addingTimeInterval(-1.5 * 86_400)..<Self.posted.addingTimeInterval(-0.5 * 86_400)
        #expect(await session.letGo(span: day, host: nil) == 1)

        #expect(session.notes.map(\.id) == ["new", "old"])
        #expect(session.holdings.earlier == 0)
        #expect(await session.store.snapshot().notes.allSatisfy(\.earlier.isEmpty))
    }

    @Test("Quit and open again: the mark and the earlier wordings are still there, and the row is where it was")
    func survivesARelaunch() async throws {
        let dir = LimitRoom.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = await Self.shell()
        let file = try StoreFile(at: dir)
        session.persist = {
            let snapshot = await session.store.snapshot()
            try? await file.save(sources: snapshot.sources, notes: snapshot.notes)
        }
        await Self.lands(session, "about pears", edited: 30)
        await Self.lands(session, "about plums", edited: 90)
        await session.persist?()
        let before = try Self.row(session)

        let opened = StoreFile.open(at: dir)
        let again = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: opened.sources, notes: opened.notes))
        await again.reloadFromStore()

        #expect(again.timelineItems(latest: nil).map(\.noteID) == ["new", "9", "old"])
        let row = try Self.row(again)
        #expect(row.editedAt == before.editedAt && row.body == "about plums")
        #expect(EarlierWordings.lines(of: row, lifted: false) == EarlierWordings.lines(of: before, lifted: false))
        #expect(row.earlier.map(\.body) == ["about apples", "about pears"])
    }

    // MARK: - The mark and the words

    private static func height(_ item: DummyItem, layout: ShellLayout) -> CGFloat {
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), onToast: { _ in })
            .environment(\.shellLayout, layout)
        let host = NSHostingView(rootView: row.frame(width: layout == .wide ? 720 : 390))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test("The mark is on the row's own line: a changed row is the height of its neighbour, and the pane draws what it said before", arguments: [ShellLayout.wide, .narrow])
    func theMarkCostsTheRowNothing(_ layout: ShellLayout) async throws {
        let session = await Self.shell()
        let plain = try Self.row(session)
        await Self.lands(session, "about apples", edited: 30)
        await Self.lands(session, "about plums", edited: 90)
        let changed = try Self.row(session)
        #expect(changed.editedAt != nil)

        #expect(Self.height(changed, layout: layout) == Self.height(plain, layout: layout), "a changed row is taller than its neighbour")

        let earlier = NSHostingView(rootView: EarlierWordings(item: changed, lifted: false).frame(width: 390))
        earlier.layoutSubtreeIfNeeded()
        #expect(earlier.fittingSize.height > 0)
    }

    /// Where the header's line laid its parts out for `item`, at `width`.
    private static func header(
        _ item: DummyItem, layout: ShellLayout, width: CGFloat, here: Set<String> = []
    ) -> [RowMetaPart: CGRect] {
        let probe = RowBandProbe()
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), probe: probe, onToast: { _ in })
            .environment(\.shellLayout, layout)
            .environment(\.shellSourcesHere, here)
        let host = NSHostingView(rootView: row.frame(width: width))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return probe.meta
    }

    /// A post from a long-named host by a long-named author: removed source, deleted there, and
    /// changed — every mark the header has, at once — or only the ones asked for.
    private static func crowded(gone: Bool = true, changed: Bool = true) -> DummyItem {
        let source = Source(host: "a-rather-long-instance-name.example", kind: .mastodon)
        return DummyItem(Note(
            id: "9", source: source, author: "Ada Lovelace the First", handle: "@ada@a-rather-long-instance-name.example",
            body: "hello", postedAt: posted, categories: [.public], audience: .everyone, spoiler: "", statusID: "9",
            goneSince: gone ? posted : nil, editedAt: changed ? at(10) : nil
        ))
    }

    @Test("With its source removed, deleted there and changed, the header still holds across a phone: every mark, the name and the age inside the row, none over another",
          arguments: [CGFloat(390), 320])
    func theHeaderHoldsWithEveryMark(width: CGFloat) throws {
        let item = Self.crowded()
        #expect(DummyItemRow.headerMarks(item, here: []) == 3)
        let parts = Self.header(item, layout: .narrow, width: width)
        let order: [RowMetaPart] = [.names, .source, .left, .gone, .changed, .age]
        let frames = try order.map { try #require(parts[$0], "\($0) was not laid out") }
        for (part, frame) in zip(order, frames) {
            #expect(frame.minX >= 0 && frame.maxX <= width + 0.5, "\(part) at \(frame) leaves a row \(width) wide")
            #expect(frame.width > 0, "\(part) was squeezed to nothing")
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(left.maxX <= right.minX + 0.5, "two parts of the header overlap: \(left) and \(right)")
        }
        #expect(frames[0].width >= 40, "the name was left a letter")
    }

    @Test("One mark alone keeps its word on a phone; two or more give up their words together; a wide page keeps them all")
    func theMarksGiveWayTogether() throws {
        // A mark drawn as a word is far wider than its glyph.
        func widths(
            _ item: DummyItem, _ layout: ShellLayout, _ width: CGFloat, here: Set<String> = []
        ) -> [RowMetaPart: CGFloat] {
            Self.header(item, layout: layout, width: width, here: here).mapValues(\.width)
        }
        let here: Set<String> = ["a-rather-long-instance-name.example"]
        #expect(DummyItemRow.headerMarks(Self.crowded(gone: false), here: here) == 1)
        let alone = widths(Self.crowded(gone: false), .narrow, 390, here: here)
        #expect(try #require(alone[.changed]) > 30, "the one mark lost its word")
        #expect(alone[.gone] == nil && alone[.left] == nil)
        // And still inside the row, with the name readable.
        let placed = Self.header(Self.crowded(gone: false), layout: .narrow, width: 320, here: here)
        #expect(try #require(placed[.age]).maxX <= 320.5 && #require(placed[.names]).width >= 40)

        let crowded = widths(Self.crowded(), .narrow, 390)
        #expect(try #require(crowded[.changed]) < 30 && #require(crowded[.gone]) < 30 && #require(crowded[.left]) < 30)

        let wide = widths(Self.crowded(), .wide, 720)
        #expect(try #require(wide[.changed]) > 30 && #require(wide[.gone]) > 30 && #require(wide[.left]) > 30)
    }

    @Test("Every word of it is written in the language asked for", arguments: [DummyLanguage.english, .taiwanese])
    func words(language: DummyLanguage) {
        for key in [
            "item.changed", "item.changed.detail", "item.changed.detail.none", "thread.earlier.title",
            "thread.earlier.until", "prefs.held.earlier", "prefs.held.earlier.count",
        ] {
            #expect(L10n.t(key, language: language) != key, "\(key) is not written in \(language)")
        }
        #expect(DummyItemRow.changedWord(language: language) == L10n.t("item.changed", language: language))
        let when = EarlierWordings.when(Self.at(30), language: language)
        let held = DummyItemRow.changedDetail(Self.at(30), earlier: 2, language: language)
        let never = DummyItemRow.changedDetail(Self.at(30), earlier: 0, language: language)
        #expect(held.contains(when) && never.contains(when) && held != never)
        #expect(!held.contains("%") && !never.contains("%"))
    }
}
