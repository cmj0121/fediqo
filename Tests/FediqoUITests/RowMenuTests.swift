import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// #306: pressing and holding a post offers what can be done to it — and so does its `…`.
///
/// Every post draws the same seven marks (`ItemActs.marks`), dim where the post does not offer
/// one, and the menu under `…` and under a long press is one value (`ItemActs.more`) that
/// **repeats none of them** (#385). Both are asked directly, for each kind of post; and each row
/// is hosted and its drawn marks read back, so the menu is checked against what is really on the
/// row and not against the list it was made from.
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
        ItemActing(
            acts: PostActs(offered: offered, refused: refused, asking: asking), perform: { _ in }, keep: {}, ask: { _ in },
            withdraw: ItemActing.Withdraw(asks: { ShellQuestion.withdraw(DummyItem(note())) }, yes: {})
        )
    }

    /// Signed in, and may write: every act but taking back, which is for the reader's own.
    private static let writes = acting([.answer, .boost, .favourite, .bookmark])
    private static let own = acting(Set(PostAct.allCases))
    private static let signedOut = acting([], refused: .notSignedIn)
    private static let turnedAway = acting([], refused: .turnedAway)
    private static let forum = acting([], refused: .protocolCannot)

    /// The four of #54's acts that are marks, in the order they are drawn.
    private static let acts: [PostAct] = [.answer, .boost, .favourite, .bookmark]

    private func marks(_ item: DummyItem, _ acting: ItemActing) -> [RowMark] {
        ItemActs.marks(on: item, acting: acting, language: .english)
    }

    private func looks(_ item: DummyItem, _ acting: ItemActing) -> [MarkLook] {
        marks(item, acting).map(\.mark.look)
    }

    private func more(_ item: DummyItem, _ acting: ItemActing, leave: (() -> Void)? = nil) -> ShellMore {
        ItemActs.more(on: item, acting: acting, leave: leave, language: .english)
    }

    /// What the menu's ordinary items read, in its order: none of the row's marks (#385).
    private func titles(_ item: DummyItem, _ acting: ItemActing) -> [String] {
        more(item, acting).ordinary.map { $0.title(language: .english) }
    }

    // MARK: - The same seven, on every post

    @Test("Every post from every kind of source draws the same seven marks in the same order and the same glyphs, whatever its sign-in, and taking back is never one of them")
    func theSameSevenForEveryProtocol() {
        let glyphs = ["arrowshape.turn.up.left", "arrow.2.squarepath", "quote.bubble", "star", "bookmark", "archivebox", "ellipsis"]
        #expect(ItemActs.line == [.act(.answer), .act(.boost), .quote, .act(.favourite), .act(.bookmark), .keep, .more])
        let grants: [MastodonGrant?] = [nil] + MastodonGrant.allCases.map { $0 }
        var seen = 0
        for kind in ProtocolKind.allCases {
            let item = DummyItem(Self.note(source: Source(host: "\(kind.rawValue).example", kind: kind)))
            for grant in grants {
                for refused in [false, true] {
                    let writing = SourceWriting.of(kind: kind, grant: grant, refused: refused)
                    for bookmarks in BookmarkStanding.allCases {
                        for (nameable, mine, gone) in [(true, false, false), (true, true, false), (false, false, false), (true, false, true)] {
                            let acts = PostActs.on(writing, nameable: nameable, mine: mine, gone: gone, bookmarks: bookmarks)
                            for acting in [ItemActing(acts: acts), ItemActing(acts: acts, perform: { _ in }, keep: {}, ask: { _ in })] {
                                let drawn = marks(item, acting)
                                #expect(drawn.map(\.kind) == ItemActs.line, "\(kind) \(writing) \(acts)")
                                #expect(drawn.map(\.mark.symbol) == glyphs, "\(kind) \(writing): a dim mark is its own glyph")
                                #expect(drawn.last?.mark.look == .live, "`…` is never dim")
                                seen += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(seen == ProtocolKind.allCases.count * grants.count * 2 * BookmarkStanding.allCases.count * 4 * 2)
    }

    // Inverted (#385): the menu named all six marks; it now repeats none of them.
    @Test("Signed in to write, every act's mark is live and quoting alone is dim; the menu repeats none of the marks and takes nothing away")
    func signedInToWrite() {
        let item = DummyItem(Self.note())
        #expect(looks(item, Self.writes) == [.live, .live, .dim(.notNow), .live, .live, .live, .live])
        #expect(titles(item, Self.writes).isEmpty)
        #expect(more(item, Self.writes).dangers.isEmpty, "taking back is for the reader's own")
    }

    @Test("Each reason a post offers no act is a dim look with its own reason on every act's mark, and the mark says the sentence after it; keeping stays live",
          arguments: PostActRefusal.allCases)
    func eachRefusalIsALookAndAReason(_ refusal: PostActRefusal) throws {
        // No `default:` — a fifth refusal has to be given a reason here too.
        let reason: DimReason = switch refusal {
        case .protocolCannot: .never
        case .unnameable: .never
        case .turnedAway: .notNow
        case .notSignedIn: .notNow
        }
        #expect(ItemActs.reason(refusal) == reason)
        #expect(ItemActs.reason(refusal) != .askAgain, "no refusal has a question a post's row can put")
        let item = DummyItem(Self.note())
        let acting = Self.acting([], refused: refusal)
        for language in [DummyLanguage.english, .taiwanese] {
            let drawn = ItemActs.marks(on: item, acting: acting, language: language)
            for act in Self.acts {
                let mark = try #require(drawn.first { $0.kind == .act(act) })
                #expect(mark.mark.look == .dim(reason), "\(act)")
                let name = ItemActs.name(act, done: false, language: language)
                let spoken = ShellMark.spoken(name: name, look: .dim(reason), language: language)
                #expect(mark.label.hasPrefix(spoken), "\(act) in \(language): \(mark.label)")
                #expect(mark.label.hasSuffix(ItemActs.refusalLine(refusal, language: language)))
                #expect(!mark.label.contains("item.") && !mark.label.contains("%"))
            }
            #expect(drawn.first { $0.kind == .keep }?.mark.look == .live, "keeping is this device's own")
        }
        // None of them says it must be asked again, so none has a press that should have asked.
        var asked = 0, performed = 0
        var counting = acting
        counting.ask = { _ in asked += 1 }
        counting.perform = { _ in performed += 1 }
        for mark in marks(item, counting) where mark.kind != .keep {
            #expect(ShellMark.press(mark.mark.look) != .asks || mark.kind == .more)
            ItemActs.press(mark, acting: counting)
        }
        #expect(asked == 0 && performed == 0, "a dim mark never acts")
    }

    @Test("Not right now: a post gone at its source, a row in a list that cannot act, and quoting everywhere; never: a bookmark the source would not grant")
    func theOtherDimMarks() {
        let item = DummyItem(Self.note())
        let gone = ItemActing(acts: PostActs.on(.writes, nameable: true, gone: true), perform: { _ in }, keep: {})
        #expect(looks(DummyItem(Self.note(gone: true)), gone) == [.dim(.notNow), .dim(.notNow), .dim(.notNow), .dim(.notNow), .dim(.notNow), .live, .live])
        let nowhere = ItemActing(acts: PostActs(offered: Set(PostAct.allCases)))
        #expect(looks(item, nowhere) == [.dim(.notNow), .dim(.notNow), .dim(.notNow), .dim(.notNow), .dim(.notNow), .dim(.notNow), .live])
        #expect(more(item, nowhere).items.allSatisfy { !$0.answers }, "a mark with no press behind it is offered dim")
        let ungranted = ItemActing(acts: PostActs.on(.writes, nameable: true, bookmarks: .unavailable), perform: { _ in }, keep: {})
        #expect(looks(item, ungranted)[4] == .dim(.never))
        let quote = marks(item, Self.writes)[2]
        #expect(quote.kind == .quote && quote.label == "Quote. Quoting cannot be done here yet")
        #expect(ItemActs.marks(on: item, acting: Self.writes, language: .taiwanese)[2].label == "引用。這裡還不能引用")
        for language in [DummyLanguage.english, .taiwanese] {
            let line = ItemActs.quoteLine(language: language)
            #expect(!line.hasPrefix("item.") && !line.isEmpty)
        }
    }

    @Test("A dim mark keeps the glyph and the count it would have live, and is still filled where the act is done")
    func dimKeepsItsGlyphAndCount() {
        let item = DummyItem(Self.note(favourited: true, bookmarked: true, kept: true))
        let live = marks(item, Self.writes), dim = marks(item, Self.signedOut)
        #expect(live.map(\.mark.drawn) == dim.map(\.mark.drawn))
        #expect(dim.map(\.mark.drawn) == ["arrowshape.turn.up.left", "arrow.2.squarepath", "quote.bubble", "star.fill", "bookmark.fill", "archivebox.fill", "ellipsis"])
        #expect(live.map(\.mark.count) == dim.map(\.mark.count))
        #expect(dim.map(\.mark.count) == [1, 2, nil, 3, nil, nil, nil], "a count stays beside its mark, live or dim")
        #expect(dim.map(\.mark.on) == [false, false, false, true, true, true, false])
    }

    @Test("An act pressed and not yet answered is its own glyph, drawn as it was pressed, and a failed one a warning triangle — never the three dots, which on a post's row are the menu and nothing else")
    func onItsWayIsAnHourglass() {
        for act in PostAct.allCases {
            #expect(ItemActs.glyph(act, standing: .failed) == "exclamationmark.triangle")
            for done in [false, true] {
                let pressed = ShellMark.drawn(ItemActs.glyph(act, standing: .pressed(to: done)), on: done)
                #expect(pressed == ShellMark.drawn(ItemActs.glyph(act, standing: nil), on: done), "no hourglass")
                #expect(pressed != "hourglass" && pressed != ShellMore.symbol)
            }
        }
        var acting = Self.writes
        acting.standings = [.boost: .pressed(to: false), .favourite: .failed]
        let drawn = marks(DummyItem(Self.note(boosted: true)), acting)
        #expect(drawn.map(\.mark.drawn) == ["arrowshape.turn.up.left", "arrow.2.squarepath", "quote.bubble", "exclamationmark.triangle", "bookmark", "archivebox", "ellipsis"])
        #expect(drawn.filter { $0.mark.drawn == ShellMore.symbol }.map(\.kind) == [.more])
        #expect(!drawn[1].mark.on && drawn[1].mark.look == .live, "a boost pressed to be taken back is drawn taken back, and is still offered")
        #expect(drawn[1].label == "Boost", "named for what the next press does, nothing added")
    }

    @Test("An act already done says the way to undo it, in the words its mark says")
    func whatIsDoneSaysItsUndoing() {
        let item = DummyItem(Self.note(favourited: true, boosted: true, bookmarked: true, kept: true))
        let drawn = marks(item, Self.writes).dropLast()
        #expect(drawn.map(\.mark.name) == ["Answer", "Take the boost back", "Quote", "Take the favourite back", "Take the bookmark off", "Stop keeping"])
        #expect(drawn.map(\.mark.on) == [false, true, false, true, true, true])
        // Undoing a boost, a favourite or a bookmark is one press of its mark, never a red item (#385).
        #expect(more(item, Self.writes).items.isEmpty)
    }

    @Test("A sign-in made before bookmarks were asked for draws the bookmark dim in its own glyph, as to be asked again, and a press on it puts the question and bookmarks nothing")
    func theBookmarkAsked() {
        let item = DummyItem(Self.note())
        var performed: [PostAct] = [], asked: [PostAct] = []
        var asking = Self.acting([.answer, .boost, .favourite], asking: [.bookmark])
        asking.perform = { performed.append($0) }
        asking.ask = { asked.append($0) }
        let bookmark = marks(item, asking)[4]
        #expect(bookmark.kind == .act(.bookmark) && bookmark.mark.look == .dim(.askAgain))
        #expect(bookmark.mark.drawn == "bookmark", "the glyph it would have live, and no other")
        #expect(bookmark.label == "Bookmark. This sign-in must be asked again first")
        ItemActs.press(bookmark, acting: asking)
        #expect(asked == [.bookmark] && performed.isEmpty)
        // A list that cannot ask: the mark is as dim, and its press goes nowhere.
        let silent = ItemActing(acts: asking.acts)
        #expect(marks(item, silent)[4].mark.look == .dim(.askAgain))
        ItemActs.press(marks(item, silent)[4], acting: silent)
        #expect(asked == [.bookmark])
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
        let said = marks(item, Self.writes).dropLast().map(\.mark.name)
        #expect(said.first == "Answer — the post by Ada")
        #expect(said.last == "Keep this reblog")
        #expect(marks(item, Self.writes).map(\.kind) == ItemActs.line)
    }

    @Test("A forum's topic draws all seven: its four acts dim, as what a forum has none of, and keeping live")
    func aForumTopic() {
        let forum = Source(host: "forum.example", kind: .discuz)
        let item = DummyItem(Self.note(source: forum, audience: nil, title: "A topic"))
        #expect(looks(item, Self.forum) == [.dim(.never), .dim(.never), .dim(.notNow), .dim(.never), .dim(.never), .live, .live])
        #expect(more(item, Self.forum).items.isEmpty, "the marks are the bar's alone")
    }

    @Test("The marks that keep a post stand apart from the ones that pass it on: the bookmark opens the group on every row, offered or not")
    func theGapBeforeTheKeepers() throws {
        let item = DummyItem(Self.note())
        for acting in [Self.writes, Self.signedOut, Self.forum, ItemActing()] {
            let gaps = marks(item, acting).map { ItemActs.gap(before: $0) }
            #expect(gaps == [nil, nil, nil, nil, ShellSpace.room, nil, nil])
        }
    }

    // MARK: - The menu

    // Inverted (#385): the menu was the head, then every mark by name; it is now what the marks
    // do not offer — the way out, and under the divider taking back — and no line heads it.
    @Test("The menu is the way out, and under the divider taking back — no mark of the row, no line about the post, in that order however it was built")
    func theMenusContentsAndOrder() {
        let item = DummyItem(Self.note())
        let menu = more(item, Self.own, leave: {})
        #expect(menu.reasons.isEmpty)
        #expect(menu.ordinary.map(\.name) == [item.outwardName])
        #expect(menu.ordinary.map(\.drawn) == ["arrow.up.forward.app"])
        #expect(menu.dangers.map(\.name) == ["Take back what you wrote"] && menu.divides)
        #expect(menu.items.last?.isDanger == true, "what takes away is last")
        #expect(!menu.items.contains { $0.symbol == ShellMore.symbol }, "`…` is not an item of itself")
        #expect(more(item, Self.own).ordinary.isEmpty, "no way out where there is no address")
    }

    // Inverted (#385): where no act was offered the menu's head said why and named the dim marks;
    // the marks say it now, to the pointer and to VoiceOver, and the menu holds none of them.
    @Test("Where no act is offered the menu holds nothing of the row's marks and no line of why: each dim mark says its reason and the row's old sentence after it")
    func theMenuSaysWhyNot() {
        let item = DummyItem(Self.note())
        for (acting, refusal) in [(Self.signedOut, PostActRefusal.notSignedIn), (Self.forum, .protocolCannot), (Self.turnedAway, .turnedAway)] {
            for language in [DummyLanguage.english, .taiwanese] {
                let menu = ItemActs.more(on: item, acting: acting, language: language)
                #expect(menu.items.isEmpty && menu.reasons.isEmpty, "\(refusal): \(menu.items.map(\.name))")
                let answer = ItemActs.marks(on: item, acting: acting, language: language)[0]
                #expect(answer.label.contains(ItemActs.refusalLine(refusal, language: language)), "\(answer.label)")
            }
        }
        let asking = ItemActs.marks(on: item, acting: Self.acting([.answer, .boost, .favourite], asking: [.bookmark]), language: .english)
        #expect(asking.first { $0.isBookmark }?.label == "Bookmark. This sign-in must be asked again first")
    }

    @Test("Taking a post back is offered only as the menu's destructive item, only on the reader's own post, and only its question's yes takes it back")
    func withdrawIsOnlyADangerItem() throws {
        let item = DummyItem(Self.note())
        var taken = 0
        var own = Self.own
        own.withdraw = ItemActing.Withdraw(asks: { ShellQuestion.withdraw(item, language: .english) }, yes: { taken += 1 })
        #expect(!marks(item, own).contains { $0.kind == .act(.withdraw) }, "it has left the line of marks")
        let menu = more(item, own)
        #expect(menu.ordinary.allSatisfy { !$0.isDanger && $0.name != "Take back what you wrote" })
        let danger = try #require(menu.dangers.first)
        #expect(menu.dangers.count == 1 && danger.drawn == "trash" && danger.answers)
        var put: ShellMoreAsk?
        danger.press { put = $0 }
        #expect(taken == 0, "choosing it only asks")
        let ask = try #require(put)
        #expect(ask.question.title == ShellQuestion.withdraw(item, language: .english).title, "the question it has always asked")
        ask.answered("anything else")
        #expect(taken == 0)
        ask.answered(ShellQuestion.yes)
        #expect(taken == 1)
        // Somebody else's post, and a list that cannot ask: not offered, dim or otherwise.
        #expect(more(item, Self.writes).dangers.isEmpty)
        #expect(more(item, ItemActing(acts: PostActs(offered: Set(PostAct.allCases)), perform: { _ in })).dangers.isEmpty)
        // Pressed and not yet answered, the row is on no list (`ShownFirstTests`); where the
        // post is still drawn — a conversation opened on it — the item is not offered at all,
        // so nothing can be chosen whose yes would be dropped.
        own.standings = [.withdraw: .pressed(to: true)]
        #expect(more(item, own).dangers.isEmpty)
        // Failed, it can be asked again, and says so in its glyph as a mark does.
        own.standings = [.withdraw: .failed]
        let failed = try #require(more(item, own).dangers.first)
        #expect(failed.answers && failed.drawn == "exclamationmark.triangle")
    }

    /// **That the `…` and the long press are one panel is by construction**, and a menu built
    /// twice from one function says nothing about it. What can go wrong is a second way in, so
    /// what is held here is the shape of the source: the dots open the one panel from
    /// `RowMoreItems.build`, the row's one caller of `ItemActs.more`; a long press throws the switch
    /// the dots' panel is shown by (`shellMoreHeld`); a Mac's other button lists the same value;
    /// and the row puts no question itself.
    @Test("The row's three dots and a long press both open the one panel, built in one place, and the pane alone puts its question")
    func bothEntriesAreOneView() throws {
        func source(_ name: String) throws -> String { try ShellSource.shell(name) }
        func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
        let row = try source("DummyItemRow")
        #expect(count("ItemActs.more(", in: row) == 1, "the menu is built in one place")
        #expect(count("build(item, acting, openURL: openURL)", in: row) == 2, "the dots' panel and a Mac's other button")
        #expect(count("ShellMorePresenter(", in: row) == 1 && row.contains("let shown = held ?? $open"), "the dots open the panel, on the row's switch")
        #expect(count(".shellMoreHeld()", in: row) == 2, "the long press throws that switch, on a Mac and on a phone")
        #expect(!row.replacingOccurrences(of: "contextMenu {", with: "").contains("Menu {"), "no system menu stands for the dots")
        #expect(count("ShellMoreItems(", in: row) == 1 && count(".contextMenu", in: row) == 2,
                "a Mac's other button, and the plain way out, which a post's row does not use")
        #expect(!row.contains("ShellMoreAsks(") && !row.contains(".shellConfirm("), "a row carries no presenter")
        let pane = try source("TimelinePane")
        #expect(count(".modifier(RowAsks(session: session))", in: pane) == 1, "one asker for the pane")
        for other in ["DummyThreadPane", "PersonPane", "TagPane"] {
            #expect(!(try source(other)).contains("ShellMoreAsks("), "\(other) asks through the pane it is in")
        }
    }

    // Changed (#385): the menu's items did what the marks do; the menu holds none of them now,
    // and the marks alone are pressed.
    @Test("With nowhere for keeping to go its mark is dim and takes the press; each mark does what it says, and the menu offers none of them")
    func aPressInTheMenu() {
        var performed: [PostAct] = [], asked: [PostAct] = [], kept = 0
        var acting = ItemActing(acts: PostActs(offered: [.answer, .favourite], asking: [.bookmark]))
        acting.perform = { performed.append($0) }
        acting.ask = { asked.append($0) }
        let item = DummyItem(Self.note())
        #expect(marks(item, acting)[5].mark.look == .dim(.notNow))
        acting.keep = { kept += 1 }
        #expect(more(item, acting).items.isEmpty)
        for mark in marks(item, acting) { ItemActs.press(mark, acting: acting) }
        #expect(performed == [.answer, .favourite] && asked == [.bookmark] && kept == 1)
    }

    // MARK: - No line about the post

    // Inverted (#385): the menu was headed by who wrote the post, exactly when, who may read it,
    // that it was changed, gone or its source left, where it came from and why no act is offered.
    // The row says each of these; the menu says none.
    @Test("No line about the post heads its menu, whatever the post: plain, changed, gone, from a source that left, a reblog, a forum's")
    func noLineAboutThePost() {
        let post = Self.note("9")
        let reblog = Note(
            id: "900", source: Self.source, author: "Bob", handle: "@bob@\(Self.host)", body: "",
            postedAt: Self.posted.addingTimeInterval(600), categories: [.home], statusID: "900",
            refs: [Reference(kind: .reblogs, id: "9", statusID: "9")]
        )
        let items = [
            DummyItem(Self.note()), DummyItem(Self.note(edited: true)), DummyItem(Self.note(gone: true)),
            DummyItem(reblog, reblogging: post), DummyItem(Self.note(source: Source(host: "forum.example", kind: .discuz), audience: nil)),
        ]
        for item in items {
            for acting in [Self.writes, Self.own, Self.signedOut, Self.forum] {
                let menu = ItemActs.more(on: item, acting: acting, leave: {}, language: .english)
                let said = menu.items.map(\.name) + menu.reasons
                for line in [DummyItemRow.spokenNames(item), DummyItemRow.exact(DummyItemRow.headerTime(item)),
                             DummyItemRow.spokenAudience(.everyone), L10n.t("item.gone.detail"), L10n.t("item.left.detail"),
                             DummyItemRow.spokenSource(item), ItemActs.refusalLine(.notSignedIn)] {
                    #expect(!said.contains(line), "\(line) is in the menu")
                }
            }
        }
    }

    @Test("The menu's items are in the language asked for")
    func theMenuInBothLanguages() {
        let item = DummyItem(Self.note())
        let menu = ItemActs.more(on: item, acting: Self.own, language: .taiwanese)
        #expect(menu.dangers.first?.title(language: .taiwanese) == ItemActs.spoken(.withdraw, done: false, standing: nil, language: .taiwanese))
    }

    #if os(macOS)
    // MARK: - The menu against the row as it is drawn

    private func drawn(_ item: DummyItem, _ acting: ItemActing) -> [String: CGRect] {
        laid(item, acting, width: 900, layout: .wide).marks
    }

    private func laid(_ item: DummyItem, _ acting: ItemActing, width: CGFloat, layout: ShellLayout) -> RowBandProbe {
        let probe = RowBandProbe()
        let row = DummyItemRow(
            item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(), acting: acting, probe: probe
        )
        .environment(\.shellLayout, layout)
        let hosted = NSHostingView(rootView: row.frame(width: width))
        hosted.frame = NSRect(origin: .zero, size: hosted.fittingSize)
        hosted.layoutSubtreeIfNeeded()
        return probe
    }

    // Inverted (#385): the menu offered the six marks that are not itself; it now offers none.
    @Test("For every kind of post, the row draws all seven marks under their names and the menu offers none of them")
    func theMenuIsTheRowsMarks() {
        let forum = Source(host: "forum.example", kind: .discuz)
        let reblog = Note(
            id: "900", source: Self.source, author: "Bob", handle: "@bob@\(Self.host)", body: "",
            postedAt: Self.posted.addingTimeInterval(600), categories: [.home], statusID: "900",
            refs: [Reference(kind: .reblogs, id: "9", statusID: "9")]
        )
        let cases: [(String, DummyItem, ItemActing)] = [
            ("signed in to write", DummyItem(Self.note()), Self.writes),
            ("turned away", DummyItem(Self.note()), Self.turnedAway),
            ("signed out", DummyItem(Self.note()), Self.signedOut),
            ("the reader's own", DummyItem(Self.note()), Self.own),
            ("a reblog", DummyItem(reblog, reblogging: Self.note("9")), Self.writes),
            ("changed", DummyItem(Self.note(edited: true)), Self.writes),
            ("gone", DummyItem(Self.note(gone: true)), Self.writes),
            ("kept and done", DummyItem(Self.note(favourited: true, boosted: true, bookmarked: true, kept: true)), Self.writes),
            ("bookmark asked", DummyItem(Self.note()), Self.acting([.answer], asking: [.bookmark])),
            ("a forum's topic", DummyItem(Self.note(source: forum, audience: nil, title: "A topic")), Self.forum),
            ("a list that cannot act", DummyItem(Self.note()), ItemActing()),
        ]
        let dots = L10n.t("mark.more")
        for (name, item, acting) in cases {
            let onTheRow = Set(drawn(item, acting).keys)
            let listed = ItemActs.marks(on: item, acting: acting).map(\.mark.name)
            #expect(onTheRow.count == 7 && onTheRow == Set(listed), "\(name): the row draws \(onTheRow.sorted())")
            let offered = Set(ItemActs.more(on: item, acting: acting).items.map(\.name))
            #expect(onTheRow.subtracting([dots]).isDisjoint(with: offered), "\(name): the row draws \(onTheRow.sorted()), the menu offers \(offered.sorted())")
        }
    }

    private static func counted(_ replies: Int, _ reblogs: Int, _ favourites: Int) -> DummyItem {
        DummyItem(Note(
            id: "n1", source: source, author: "Ada", handle: "@ada@\(host)", body: "Short.",
            postedAt: posted, categories: [.public], audience: .everyone,
            counts: Counts(replies: replies, reblogs: reblogs, favourites: favourites), statusID: "1"
        ))
    }

    @Test("Seven marks stand on one line in a row 320 points wide at the default type size, live or dim: each glyph its full size, each count still drawn, none over another")
    func sevenFitAtThreeHundredAndTwenty() throws {
        for (item, roomy) in [(Self.counted(12, 340, 1289), true), (Self.counted(12_345, 67_890, 123_456), false)] {
            for acting in [Self.own, Self.signedOut, Self.forum, ItemActing()] {
                let probe = laid(item, acting, width: 320, layout: .narrow)
                let marks = ItemActs.marks(on: item, acting: acting)
                let order = try marks.map { try #require(probe.marks[$0.mark.name]) }
                #expect(order.count == 7)
                #expect(Set(order.map { ($0.midY * 2).rounded() / 2 }).count == 1, "one line: \(order.map(\.midY))")
                for (left, right) in zip(order, order.dropFirst()) {
                    #expect(right.minX - left.maxX >= DummyItemRow.Box.markGap - 0.5, "two marks are \(right.minX - left.maxX) apart")
                }
                #expect(try #require(order.first).minX >= 0 && (try #require(order.last)).maxX <= 320 + 0.5)
                for (mark, frame) in zip(marks, order) {
                    #expect(frame.height >= ShellGlyphBox.box - 0.5, "\(mark.mark.name) is \(frame.height) tall")
                    let glyph = try #require(probe.glyphs[mark.mark.name], "\(mark.mark.name) drew no glyph")
                    #expect(abs(glyph.width - 17) < 0.5 && abs(glyph.height - 17) < 0.5, "\(mark.mark.name)'s glyph was shrunk to \(glyph.size)")
                    // With counts of ordinary length nothing gives anything up: a whole press's box,
                    // and every count beside its mark. Counts five and six figures long are given up
                    // before two marks touch (#302), and then by every mark alike.
                    if roomy {
                        #expect(frame.width >= ShellGlyphBox.box - 0.5, "\(mark.mark.name) is \(frame.width) wide")
                        #expect((probe.counts[mark.mark.name] != nil) == (mark.mark.count != nil), "\(mark.mark.name): a count is drawn where there is one, live or dim")
                    } else {
                        #expect(probe.counts.isEmpty, "some marks kept a count and some gave it up: \(probe.counts.keys.sorted())")
                    }
                }
            }
        }
    }
    #endif
}
