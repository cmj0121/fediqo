import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// The one control rule: a mark is always drawn, live in its hue or dim with its reason, and the
/// glyph does not depend on which; a press that takes something away is offered only by the `…`
/// menu, and only with its question.
///
/// What a test can reach: the rules the mark and the menu are drawn by — ink, glyph, sentence,
/// what a press is, the menu's order and what choosing an item does — and the strings in all
/// three tables. What it cannot: the hover, VoiceOver's reading, the menu on a screen.
///
/// **The suite is `@MainActor`**: the rules are statics beside `View`s, and the ink is `Color`.
@Suite("A mark is live or dim, and danger is only in the menu")
@MainActor
struct MarkTests {
    private static let looks: [MarkLook] = [.live] + DimReason.allCases.map(MarkLook.dim)

    private static let question = ShellQuestion.dropCopies(language: .english)

    // MARK: - Two looks

    @Test("A live mark wears the quiet ink, or the warm one when on; a dim one the dim ink, on or off")
    func theInkFollowsTheLook() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(ShellMark.ink(.live, on: false, scheme) == ShellChrome.inkDim(scheme))
            #expect(ShellMark.ink(.live, on: true, scheme) == ShellChrome.filament(scheme))
            for reason in DimReason.allCases {
                for on in [false, true] {
                    #expect(ShellMark.ink(.dim(reason), on: on, scheme) == ShellChrome.markDim(scheme))
                }
            }
            // No look is the alarm: a mark never wears it.
            for look in Self.looks {
                for on in [false, true] {
                    #expect(ShellMark.ink(look, on: on, scheme) != ShellChrome.alarm(scheme))
                }
            }
            // Live quiet and dim are different inks, so the two looks are two.
            #expect(ShellChrome.markDim(scheme) != ShellChrome.inkDim(scheme))
        }
    }

    /// The person's rule: grey and not grey are the same icon, and only the colour differs. The
    /// glyph is read off the act and whether it is on, and the look is not asked at all.
    @Test("One glyph in both looks: filled where the mark is on, the outline where it is off")
    func theGlyphDoesNotDependOnTheLook() {
        for symbol in ["key", "star", "bookmark", "archivebox"] {
            #expect(ShellMark.drawn(symbol, on: false) == symbol)
            #expect(ShellMark.drawn(symbol, on: true) == "\(symbol).fill")
            for on in [false, true] {
                let drawn = Set(Self.looks.map { ShellMark(symbol, "x", look: $0, on: on).drawn })
                #expect(drawn == [ShellMark.drawn(symbol, on: on)], "\(symbol) on \(on) is drawn as \(drawn)")
            }
        }
        // A glyph with no twin is itself when on, rather than a symbol that does not exist.
        for symbol in ["arrow.2.squarepath", "quote.bubble", "checklist"] {
            #expect(ShellMark.drawn(symbol, on: true) == symbol)
        }
        // A bookmark that is on and must be asked again is still the filled bookmark, dim.
        let held = ShellMark("bookmark", "Bookmark", look: .dim(.askAgain), on: true)
        #expect(held.drawn == "bookmark.fill")
        #expect(ShellMark.ink(held.look, on: held.on, .light) == ShellChrome.markDim(.light))
        #expect(ShellMark("bookmark", "Bookmark", look: .dim(.askAgain)).drawn == "bookmark")
    }

    @Test("The count beside a dim mark is text, and is written in the faintest text ink")
    func aDimCountIsText() {
        for scheme in [ColorScheme.light, .dark] {
            for reason in DimReason.allCases {
                for on in [false, true] {
                    #expect(ShellMark.countInk(.dim(reason), on: on, scheme) == ShellChrome.inkFaint(scheme))
                }
            }
            #expect(ShellChrome.inkFaint(scheme) != ShellChrome.markDim(scheme))
            // Live, the count is the glyph's ink.
            for on in [false, true] {
                #expect(ShellMark.countInk(.live, on: on, scheme) == ShellMark.ink(.live, on: on, scheme))
            }
        }
    }

    // MARK: - Dim carries its reason

    @Test("A dim mark says its name and then why; a live one says its name",
          arguments: [DummyLanguage.english, .taiwanese])
    func aDimMarkSaysWhy(_ language: DummyLanguage) {
        #expect(ShellMark.spoken(name: "Boost", look: .live, language: language) == "Boost")
        var said: Set<String> = []
        for reason in DimReason.allCases {
            let why = L10n.t(reason.key, language: language)
            #expect(why != reason.key, "\(reason.key) is missing")
            let spoken = ShellMark.spoken(name: "Boost", look: .dim(reason), language: language)
            // The join is the language's own: a full stop and a space, or 「。」.
            #expect(spoken == (language == .english ? "Boost. \(why)" : "Boost。\(why)"))
            said.insert(spoken)
        }
        // Three reasons are three sentences: one look is never one silence.
        #expect(said.count == DimReason.allCases.count)
    }

    @Test("A dim mark never acts: one that needs asking again asks, the others take the press")
    func whatAPressIs() {
        #expect(ShellMark.press(.live) == .acts)
        #expect(ShellMark.press(.dim(.askAgain)) == .asks)
        #expect(ShellMark.press(.dim(.never)) == .nothing)
        #expect(ShellMark.press(.dim(.notNow)) == .nothing)
    }

    @Test("A press goes to the act only when live, to the question only when it must be asked again")
    func whereAPressGoes() {
        var acted = 0
        var asked = 0
        func press(_ look: MarkLook) -> [Int] {
            acted = 0
            asked = 0
            ShellMark.pressed(look, act: { acted += 1 }, ask: { asked += 1 })
            return [acted, asked]
        }
        #expect(press(.live) == [1, 0])
        #expect(press(.dim(.askAgain)) == [0, 1])
        #expect(press(.dim(.never)) == [0, 0])
        #expect(press(.dim(.notNow)) == [0, 0])

        // With no question to put, a mark that must be asked again still does not act.
        acted = 0
        ShellMark.pressed(.dim(.askAgain), act: { acted += 1 }, ask: nil)
        #expect(acted == 0)
    }

    @Test("A mark's box, widened by the touch floor, is a finger wide, and one box is every glyph-only control's")
    func aMarkIsAFingerWide() {
        let box = ShellGlyphBox.box
        #expect(box == 32)
        #expect(box + 2 * ShellTouchFloor.spill(drawn: box) == ShellTouchFloor.finger)
        #expect(ShellTouchFloor.finger == 44)
    }

    // MARK: - The menu

    @Test("A destructive item whose question is counted counts when chosen, and only its yes acts")
    func aCountedDangerCountsAtThePress() async {
        var done = 0
        var counts = 0
        var found: ShellConfirmation? = Self.question
        let item = ShellMoreItem.danger("trash", "Let go", counts: { counts += 1; return found }) { done += 1 }
        #expect(item.isDanger && item.isCounted && item.answers)
        #expect(item.question == nil)
        #expect(counts == 0, "the count was taken before the item was chosen")

        // Choosing it counts, and the question that comes back is put: nothing is done yet.
        var put: [ShellMoreAsk] = []
        await item.press { put.append($0) }?.value
        #expect(counts == 1 && put.count == 1 && put.first?.question == Self.question && done == 0)
        put.first?.answered("something else")
        #expect(done == 0)
        put.first?.answered(Self.question.chorded?.id ?? "")
        #expect(done == 1)

        // The count finding nothing: no question, and the act is not reached.
        found = nil
        await item.press { put.append($0) }?.value
        #expect(await item.counted() == nil)
        #expect(counts == 3 && put.count == 1 && done == 1)

        // Dim, it does not count at all; an uncounted item has nothing to count, and is put at
        // the press with no task to wait on.
        let dim = ShellMoreItem.danger("trash", "Let go", look: .dim(.notNow), counts: { counts += 1; return found }) {}
        #expect(!dim.answers)
        #expect(dim.press { put.append($0) } == nil)
        #expect(await dim.counted() == nil)
        let now = ShellMoreItem.danger("trash", "Drop", asks: Self.question) {}
        #expect(await now.counted() == nil)
        #expect(now.press { put.append($0) } == nil && put.count == 2)
        #expect(counts == 3)
    }

    @Test("Of a question with several choices, only its yes acts")
    func onlyTheYesActs() {
        var done = 0
        let several = ShellConfirmation(
            symbol: "trash", title: "Remove?", line: "It goes.", help: nil,
            choices: [
                .init("keep", "Keep the posts", role: .plain),
                .init("gone", "Remove", role: .destructive),
            ],
            cancel: "Cancel"
        )
        let ask = ShellMoreAsk(question: several) { done += 1 }
        ask.answered("keep")
        #expect(done == 0)
        ask.answered("gone")
        #expect(done == 1)

        // Clear's yes is keyed and not destructive, and is still the one that acts.
        let clear = ShellQuestion.clear(host: "a.example", detailKey: "account.clear.detail", language: .english)
        #expect(clear.chorded != nil)
        #expect(!clear.warns)
        let cleared = ShellMoreAsk(question: clear) { done += 10 }
        cleared.answered(clear.chorded?.id ?? "")
        #expect(done == 11)
    }

    @Test("An item that is on is told from one that is off by its glyph, as its mark is")
    func anItemThatIsOnIsFilled() {
        let off = ShellMoreItem.plain(ShellMark("bookmark", "Bookmark", look: .live)) {}
        let on = ShellMoreItem.plain(ShellMark("bookmark", "Take the bookmark off", look: .live, on: true)) {}
        #expect(off.drawn == "bookmark")
        #expect(on.drawn == "bookmark.fill")

        // Made from the row's mark, the item is that mark: one glyph, name, look and state.
        let mark = ShellMark("archivebox", "Stop keeping", look: .dim(.notNow), on: true)
        let item = ShellMoreItem.plain(mark) {}
        #expect(item.drawn == mark.drawn)
        #expect(item.drawn == "archivebox.fill")
        #expect(item.title(language: .english) == ShellMark.spoken(name: mark.name, look: mark.look, language: .english))
        #expect(!item.answers)

        // A destructive item made from a mark is that mark too, and is never on.
        let danger = ShellMoreItem.danger(ShellMark("trash", "Remove", look: .dim(.notNow)), asks: Self.question) {}
        #expect(danger.isDanger && danger.symbol == "trash" && danger.name == "Remove" && !danger.answers)
    }

    @Test("The menu's head says what the row says, then each dim mark's reason once",
          arguments: [DummyLanguage.english, .taiwanese])
    func theHeadCarriesTheReasons(_ language: DummyLanguage) {
        func why(_ reason: DimReason) -> String { L10n.t(reason.key, language: language) }
        let marks = [
            ShellMark("arrowshape.turn.up.left", "Answer", look: .dim(.askAgain)),
            ShellMark("arrow.2.squarepath", "Boost", look: .dim(.askAgain)),
            ShellMark("quote.bubble", "Quote", look: .live),
            ShellMark("star", "Favourite", look: .dim(.notNow), on: true),
            ShellMark("bookmark", "Bookmark", look: .dim(.askAgain)),
            ShellMark("archivebox", "Keep", look: .live, on: true),
        ]
        // Each line names the marks it is about, and a reason shared by three is said once.
        let english = language == .english
        let asked = english ? "Answer, Boost, Bookmark. \(why(.askAgain))" : "Answer、Boost、Bookmark。\(why(.askAgain))"
        let later = english ? "Favourite. \(why(.notNow))" : "Favourite。\(why(.notNow))"
        #expect(ShellMore.reasons(of: marks, language: language) == [asked, later])
        // One mark alone reads as the mark itself is spoken: its name, then its reason.
        #expect(later == ShellMark.spoken(name: "Favourite", look: .dim(.notNow), language: language))
        #expect(ShellMore.reasons(of: marks.filter { ShellMark.press($0.look) == .acts }, language: language).isEmpty)
        #expect(ShellMore.reasons(of: [], language: language).isEmpty)

    }

    @Test("An ordinary item acts at once and asks nothing")
    func plainActs() {
        var done = 0
        var put = 0
        let item = ShellMoreItem.plain("checklist", "Boards") { done += 1 }
        #expect(!item.isDanger)
        #expect(item.question == nil)
        item.press { _ in put += 1 }
        #expect(done == 1)
        #expect(put == 0)
    }

    @Test("A dim item does not act: it asks again where that is its reason, and is otherwise inert")
    func dimItemsDoNotAct() {
        var done = 0
        var asked = 0
        var put = 0
        for reason in [DimReason.never, .notNow] {
            let plain = ShellMoreItem.plain(ShellMark("checklist", "Boards", look: .dim(reason))) { done += 1 }
            let danger = ShellMoreItem.danger(
                "key.slash", "Forget password", look: .dim(reason), asks: Self.question
            ) { done += 1 }
            for item in [plain, danger] {
                #expect(!item.answers)
                item.press { _ in put += 1 }
            }
        }
        #expect(done == 0)
        #expect(put == 0)

        let bookmark = ShellMark("bookmark", "Bookmark", look: .dim(.askAgain))
        let again = ShellMoreItem.plain(bookmark, ask: { asked += 1 }, act: { done += 1 })
        #expect(again.answers)
        again.press { _ in put += 1 }
        #expect((done, asked, put) == (0, 1, 0))
        // With no question to put, there is nothing a press could do.
        #expect(!ShellMoreItem.plain(bookmark) {}.answers)
    }

    @Test("A dim item reads its reason, since a menu draws no ink of ours",
          arguments: [DummyLanguage.english, .taiwanese])
    func aDimItemReadsItsReason(_ language: DummyLanguage) {
        let live = ShellMoreItem.plain("checklist", "Boards") {}
        let dim = ShellMoreItem.plain(ShellMark("checklist", "Boards", look: .dim(.never))) {}
        #expect(live.title(language: language) == "Boards")
        #expect(dim.title(language: language) == ShellMark.said("Boards", L10n.t("mark.dim.never", language: language), language: language))
        #expect(dim.title(language: .english) == "Boards. This source has none")
        // Under a head that names it with its reason, it says its name alone and is as dim.
        #expect(dim.underHead.title(language: language) == "Boards" && !dim.underHead.answers)
        #expect(live.underHead.title(language: language) == "Boards" && live.underHead.answers)
    }

    @Test("The menu is ordinary items, then a divider, then the destructive ones, however it was built")
    func theMenuHasOneOrder() {
        let clear = ShellMoreItem.danger("eraser", "Clear", asks: Self.question) {}
        let remove = ShellMoreItem.danger("trash", "Remove", asks: Self.question) {}
        let boards = ShellMoreItem.plain("checklist", "Boards") {}
        let lists = ShellMoreItem.plain("list.bullet", "Lists") {}

        let more = ShellMore(head: ["Reading…"], items: [clear, boards, remove, lists])
        #expect(more.ordinary.map(\.name) == ["Boards", "Lists"])
        #expect(more.dangers.map(\.name) == ["Clear", "Remove"])
        #expect(more.divides)
        #expect(more.head == ["Reading…"])

        #expect(!ShellMore(items: [clear]).divides)
        #expect(!ShellMore(items: [boards, lists]).divides)
        #expect(ShellMore.symbol == "ellipsis")
    }

    @Test("A menu of one item is named by it; any other is More",
          arguments: [DummyLanguage.english, .taiwanese])
    func theMenuNamesItself(_ language: DummyLanguage) {
        let stop = ShellMoreItem.danger("archivebox", "Stop keeping a.example", asks: Self.question) {}
        let boards = ShellMoreItem.plain("checklist", "Boards") {}
        let word = L10n.t("mark.more", language: language)
        #expect(word != "mark.more")

        let one = ShellMore(items: [stop]).label(language: language)
        #expect(one.contains("Stop keeping a.example"))
        #expect(one.hasPrefix(word))
        #expect(one != word)
        #expect(ShellMore(items: [stop, boards]).label(language: language) == word)
        #expect(ShellMore(items: []).label(language: language) == word)
    }

    // MARK: - The words

    @Test("The reasons and the menu's name are in all three tables, and the two Chinese ones agree")
    func theWordsAreInEveryTable() throws {
        let keys = DimReason.allCases.map(\.key) + ["mark.more", "mark.more.one", "mark.dim.said", "mark.dim.names"]
        #expect(Set(keys).count == 7)
        #expect(L10n.t("mark.dim.said", language: .taiwanese) == "%1$@。%2$@" && L10n.t("mark.dim.names", language: .taiwanese) == "、")
        for key in keys {
            #expect(L10n.t(key, language: .english) != L10n.t(key, language: .taiwanese), "\(key)")
        }
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            for key in keys {
                #expect(strings.contains("\"\(key)\" = "), "\(key) is missing in \(lproj)")
            }
        }
        let tw = try Data(contentsOf: resources.appendingPathComponent("zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appendingPathComponent("zh-Hant.lproj/Localizable.strings"))
        #expect(tw == hant)
    }
}
