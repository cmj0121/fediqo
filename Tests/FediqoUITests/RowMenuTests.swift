import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// #306: pressing and holding a post offers what can be done to it.
///
/// The menu and the row's marks are one list (`ItemActs.marks`), and the head is the words the
/// row's parts already tell a resting pointer. Both are asked directly, for each kind of post;
/// and each row is hosted and its drawn marks read back, so the menu is checked against what is
/// really on the row and not against the list it was made from.
@Suite("Pressing and holding a post offers what can be done to it", .serialized)
@MainActor
struct RowMenuTests {
    init() {
        L10n.language = .english
    }

    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let posted = Date(timeIntervalSince1970: 1_700_000_000)

    private static func note(
        _ id: String = "1", source: Source = RowMenuTests.source, audience: Audience? = .everyone,
        favourited: Bool = false, boosted: Bool = false, bookmarked: Bool = false, kept: Bool = false,
        gone: Bool = false, edited: Bool = false, boostedBy: String? = nil, title: String? = nil
    ) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada@\(source.host)", body: "Words.", title: title,
            postedAt: posted, categories: [.public], boostedBy: boostedBy, boosted: boosted, favourited: favourited,
            bookmarked: bookmarked, audience: audience, counts: Counts(replies: 1, reblogs: 2, favourites: 3),
            statusID: id, goneSince: gone ? posted : nil, kept: kept, editedAt: edited ? posted.addingTimeInterval(60) : nil
        )
    }

    private static func acting(_ offered: Set<PostAct>, refused: PostActRefusal? = nil, asking: Set<PostAct> = []) -> ItemActing {
        ItemActing(acts: PostActs(offered: offered, refused: refused, asking: asking), perform: { _ in }, keep: {}, ask: { _ in })
    }

    /// Signed in, and may write: every act but taking back, which is for the reader's own.
    private static let writes = acting([.answer, .boost, .favourite, .bookmark])
    private static let own = acting(Set(PostAct.allCases))
    private static let signedOut = acting([], refused: .notSignedIn)
    private static let readOnly = acting([], refused: .turnedAway)
    private static let forum = acting([], refused: .protocolCannot)

    private func kinds(_ item: DummyItem, _ acting: ItemActing) -> [RowMark.Kind] {
        ItemActs.menu(on: item, acting: acting).map(\.kind)
    }

    private func names(_ item: DummyItem, _ acting: ItemActing) -> [String] {
        ItemActs.menu(on: item, acting: acting).map(\.label)
    }

    // MARK: - What is offered, by kind of post

    @Test("Signed in to write, a post offers answering, boosting, favouriting, bookmarking and keeping, in the marks' order; not taking back, which is for the reader's own")
    func signedInToWrite() {
        let item = DummyItem(Self.note())
        #expect(kinds(item, Self.writes) == [.act(.answer), .act(.boost), .act(.favourite), .act(.bookmark), .keep])
        #expect(names(item, Self.writes) == ["Answer", "Boost", "Favourite", "Bookmark", "Keep"])
    }

    @Test("Signed out, or signed in to read only, a post offers keeping and nothing a source would have to be written to for")
    func withoutWriting() {
        let item = DummyItem(Self.note())
        #expect(kinds(item, Self.signedOut) == [.keep])
        #expect(kinds(item, Self.readOnly) == [.keep])
    }

    @Test("The reader's own post also offers taking it back, after keeping")
    func theReadersOwn() {
        let item = DummyItem(Self.note())
        #expect(kinds(item, Self.own) == [.act(.answer), .act(.boost), .act(.favourite), .act(.bookmark), .keep, .act(.withdraw)])
        #expect(names(item, Self.own).last == "Take back what you wrote")
    }

    @Test("An act already done says the way to undo it, in the words its mark says")
    func whatIsDoneSaysItsUndoing() {
        let item = DummyItem(Self.note(favourited: true, boosted: true, bookmarked: true, kept: true))
        #expect(names(item, Self.writes) == ["Answer", "Take the boost back", "Take the favourite back", "Take the bookmark off", "Stop keeping"])
        #expect(ItemActs.menu(on: item, acting: Self.writes).map(\.on) == [false, true, true, true, true])
    }

    @Test("A sign-in made before bookmarks were asked for offers the question in the bookmark's place, and a press puts it")
    func theBookmarkAsked() {
        let item = DummyItem(Self.note())
        let asking = Self.acting([.answer, .boost, .favourite], asking: [.bookmark])
        #expect(kinds(item, asking) == [.act(.answer), .act(.boost), .act(.favourite), .ask(.bookmark), .keep])
        #expect(names(item, asking)[3] == ItemActs.askLine(.bookmark))
    }

    @Test("On a reblog's row the acts go to the post and say whose it is; keeping is the reblog's and says so")
    func aReblogsRow() {
        let post = Self.note("9")
        let reblog = Note(
            id: "900", source: Self.source, author: "Bob", handle: "@bob@\(Self.host)", body: "",
            postedAt: Self.posted.addingTimeInterval(600), categories: [.home], statusID: "900",
            refs: [Reference(kind: .reblogs, id: "9", statusID: "9")]
        )
        let item = DummyItem(reblog, reblogging: post)
        let said = names(item, Self.writes)
        #expect(said.first == "Answer — the post by Ada")
        #expect(said.last == "Keep this reblog")
        #expect(kinds(item, Self.writes) == [.act(.answer), .act(.boost), .act(.favourite), .act(.bookmark), .keep])
    }

    @Test("A forum's topic offers keeping alone: a forum is read only, and its row draws no act's mark")
    func aForumTopic() {
        let forum = Source(host: "forum.example", kind: .discuz)
        let item = DummyItem(Self.note(source: forum, audience: nil, title: "A topic"))
        #expect(kinds(item, Self.forum) == [.keep])
    }

    @Test("The two marks that only say they are not built yet are on the row and not in the menu; a list with nowhere for a press to go offers no act")
    func whatIsLeftOut() {
        let item = DummyItem(Self.note())
        let drawn = ItemActs.marks(on: item, acting: Self.writes).map(\.kind)
        #expect(drawn == [.act(.answer), .act(.boost), .quote, .act(.favourite), .act(.bookmark), .keep, .more])
        #expect(!kinds(item, Self.writes).contains(.quote) && !kinds(item, Self.writes).contains(.more))
        let nowhere = ItemActing(acts: PostActs(offered: Set(PostAct.allCases)))
        #expect(kinds(item, nowhere).isEmpty, "a mark with no press behind it is not offered")
    }

    @Test("The marks that keep a post stand apart from the ones that pass it on: the bookmark opens the group, and keeping does where there is no bookmark")
    func theGapBeforeTheKeepers() throws {
        let item = DummyItem(Self.note())
        let all = ItemActs.marks(on: item, acting: Self.writes)
        let gaps = all.map { ItemActs.gap(before: $0, among: all) }
        #expect(gaps == [nil, nil, nil, nil, ShellSpace.room, nil, nil])
        let few = ItemActs.marks(on: item, acting: Self.signedOut)
        #expect(few.map { ItemActs.gap(before: $0, among: few) } == [nil, ShellSpace.room, nil])
    }

    // MARK: - The head

    @Test("The head of a plain post says exactly when it was published, who may read it and where it came from — the words its parts tell a resting pointer")
    func theHeadOfAPlainPost() {
        let item = DummyItem(Self.note())
        #expect(ItemActs.head(for: item, here: [Self.host]) == [
            "Ada, @ada@m.example", DummyItemRow.exact(Self.posted), DummyItemRow.spokenAudience(.everyone), Self.host,
        ])
    }

    @Test("A changed post says so and when; one gone at its source says so; one whose source has left says so; each in its tooltip's own words")
    func theHeadSaysWhatHappened() throws {
        let changed = DummyItem(Self.note(edited: true))
        let edited = try #require(changed.editedAt)
        #expect(ItemActs.head(for: changed, here: [Self.host]).contains(DummyItemRow.changedDetail(edited, earlier: 0)))
        let gone = DummyItem(Self.note(gone: true))
        #expect(ItemActs.head(for: gone, here: [Self.host]).contains(L10n.t("item.gone.detail")))
        #expect(!ItemActs.head(for: DummyItem(Self.note()), here: [Self.host]).contains(L10n.t("item.gone.detail")))
        let left = ItemActs.head(for: DummyItem(Self.note()), here: [])
        #expect(left.contains(L10n.t("item.left.detail")))
        #expect(!ItemActs.head(for: DummyItem(Self.note()), here: nil).contains(L10n.t("item.left.detail")), "nobody said which sources are here")
    }

    @Test("A reblog's head begins with who reblogged it and exactly when; a post with nobody it may be read by named says nothing of that")
    func theHeadOfAReblog() throws {
        let post = Self.note("9")
        let reblog = Note(
            id: "900", source: Self.source, author: "Bob", handle: "@bob@\(Self.host)", body: "",
            postedAt: Self.posted.addingTimeInterval(600), categories: [.home], statusID: "900",
            refs: [Reference(kind: .reblogs, id: "9", statusID: "9")]
        )
        let item = DummyItem(reblog, reblogging: post)
        let head = ItemActs.head(for: item, here: [Self.host])
        #expect(head.first == DummyItemRow.spokenNames(item), "who wrote the post, by name and whole handle")
        #expect(head[1] == DummyItemRow.spokenReblog(item))
        #expect(head.contains(DummyItemRow.exact(DummyItemRow.headerTime(item))), "and the post's own time after it")
        let forum = DummyItem(Self.note(source: Source(host: "forum.example", kind: .discuz), audience: nil))
        #expect(ItemActs.head(for: forum, here: ["forum.example"]).count == 3, "who, the time and the source")
    }

    @Test("Where no act is offered the head ends with why, in the sentence the row says under itself; where acts are offered it says nothing of the kind")
    func theHeadSaysWhyNot() {
        let item = DummyItem(Self.note())
        #expect(ItemActs.head(for: item, here: [Self.host], refused: .notSignedIn).last == ItemActs.refusalLine(.notSignedIn))
        #expect(ItemActs.head(for: item, here: [Self.host], refused: .turnedAway).last == ItemActs.refusalLine(.turnedAway))
        #expect(ItemActs.head(for: item, here: [Self.host], refused: nil).last == Self.host)
        #expect(ItemActs.head(for: item, here: [Self.host], refused: .notSignedIn, language: .taiwanese).last == ItemActs.refusalLine(.notSignedIn, language: .taiwanese))
    }

    @Test("Nothing in the menu is a press that does nothing: with nowhere for keeping to go it is not offered, though its mark is drawn; and taking back is marked as taking away")
    func noIdleEntry() {
        let item = DummyItem(Self.note())
        let noKeep = ItemActing(acts: PostActs(offered: [.answer]), perform: { _ in })
        #expect(kinds(item, noKeep) == [.act(.answer)])
        #expect(ItemActs.marks(on: item, acting: noKeep).map(\.kind).contains(.keep), "the mark is still on the row")
        let own = ItemActs.menu(on: item, acting: Self.own)
        #expect(own.filter(\.destroys).map(\.kind) == [.act(.withdraw)])
    }

    @Test("The head is in the language asked for")
    func theHeadInBothLanguages() {
        let item = DummyItem(Self.note(gone: true))
        let zh = ItemActs.head(for: item, here: [Self.host], language: .taiwanese)
        #expect(zh.contains(L10n.t("item.gone.detail", language: .taiwanese)))
        #expect(ItemActs.menu(on: item, acting: Self.writes, language: .taiwanese).map(\.label).first == L10n.t("item.act.answer", language: .taiwanese))
    }

    #if os(macOS)
    // MARK: - The menu against the row as it is drawn

    private func drawn(_ item: DummyItem, _ acting: ItemActing) -> Set<String> {
        let probe = RowBandProbe()
        let row = DummyItemRow(
            item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), acting: acting, probe: probe,
            onToast: { _ in }
        )
        .environment(\.shellLayout, .wide)
        let hosted = NSHostingView(rootView: row.frame(width: 900))
        hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
        hosted.layoutSubtreeIfNeeded()
        return Set(probe.marks.keys)
    }

    @Test("For every kind of post, the menu offers exactly the marks the row draws, less the two that do nothing yet — by the names the marks are drawn under")
    func theMenuIsTheRowsMarks() {
        let forum = Source(host: "forum.example", kind: .discuz)
        let reblog = Note(
            id: "900", source: Self.source, author: "Bob", handle: "@bob@\(Self.host)", body: "",
            postedAt: Self.posted.addingTimeInterval(600), categories: [.home], statusID: "900",
            refs: [Reference(kind: .reblogs, id: "9", statusID: "9")]
        )
        let cases: [(String, DummyItem, ItemActing)] = [
            ("signed in to write", DummyItem(Self.note()), Self.writes),
            ("read only", DummyItem(Self.note()), Self.readOnly),
            ("signed out", DummyItem(Self.note()), Self.signedOut),
            ("the reader's own", DummyItem(Self.note()), Self.own),
            ("a reblog", DummyItem(reblog, reblogging: Self.note("9")), Self.writes),
            ("changed", DummyItem(Self.note(edited: true)), Self.writes),
            ("gone", DummyItem(Self.note(gone: true)), Self.writes),
            ("kept and done", DummyItem(Self.note(favourited: true, boosted: true, bookmarked: true, kept: true)), Self.writes),
            ("bookmark asked", DummyItem(Self.note()), Self.acting([.answer], asking: [.bookmark])),
            ("a forum's topic", DummyItem(Self.note(source: forum, audience: nil, title: "A topic")), Self.forum),
        ]
        let idle: Set<String> = [L10n.t("item.act.quote"), L10n.t("item.act.more")]
        for (name, item, acting) in cases {
            let onTheRow = drawn(item, acting)
            let offered = Set(ItemActs.menu(on: item, acting: acting).map(\.label))
            #expect(onTheRow.subtracting(idle) == offered, "\(name): the row draws \(onTheRow.sorted()), the menu offers \(offered.sorted())")
            #expect(onTheRow.isSuperset(of: idle), "\(name): the two idle marks are still drawn")
        }
    }

    @Test("A row drawn and never pressed builds no head: what the menu says is worked out when a menu is raised")
    func noHeadUntilAMenu() {
        let before = ItemActs.headsBuilt
        for index in 0 ..< 6 {
            _ = drawn(DummyItem(Self.note("\(index)")), Self.writes)
        }
        #expect(ItemActs.headsBuilt == before, "\(ItemActs.headsBuilt - before) heads were built for six rows nobody pressed")
        _ = ItemActs.head(for: DummyItem(Self.note()), here: nil)
        #expect(ItemActs.headsBuilt == before + 1, "the count does count")
    }

    @Test("A press in the menu does what the mark does: each act reaches the row's own press, with the act it names")
    func aPressInTheMenu() {
        var performed: [PostAct] = [], asked: [PostAct] = [], kept = 0, toasts: [String] = []
        var acting = ItemActing(acts: PostActs(offered: [.answer, .favourite], asking: [.bookmark]))
        acting.perform = { performed.append($0) }
        acting.ask = { asked.append($0) }
        acting.keep = { kept += 1 }
        let item = DummyItem(Self.note())
        let row = DummyItemRow(
            item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), acting: acting, onToast: { toasts.append($0) }
        )
        for mark in ItemActs.menu(on: item, acting: acting) { row.press(mark.kind) }
        #expect(performed == [.answer, .favourite])
        #expect(asked == [.bookmark])
        #expect(kept == 1)
        #expect(toasts.isEmpty, "nothing in the menu only says it is not built")
        row.press(.quote)
        #expect(toasts == [L10n.t("item.toast.quote")])
    }
    #endif
}
