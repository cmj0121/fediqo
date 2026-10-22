import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #385 (D6): pressing a dim mark — on a post's bar, a source's row, or a dim item of the panel —
/// shows its reason beside it in a small line; the one that must be asked again still asks.
@Suite("A dim mark says its reason when pressed")
@MainActor
struct DimReasonTests {
    init() {
        L10n.language = .english
    }

    @Test("A press on a live mark acts, on one to be asked again asks, and on any other dim mark — or one to be asked again with nothing to ask — says why instead")
    func whatAPressDoes() {
        var acted = 0, asked = 0
        #expect(!ShellMark.pressed(.live, act: { acted += 1 }, ask: { asked += 1 }))
        #expect(!ShellMark.pressed(.dim(.askAgain), act: { acted += 1 }, ask: { asked += 1 }))
        #expect(acted == 1 && asked == 1)
        #expect(ShellMark.pressed(.dim(.askAgain), act: { acted += 1 }, ask: nil))
        for reason in [DimReason.never, .notNow] {
            #expect(ShellMark.pressed(.dim(reason), act: { acted += 1 }, ask: { asked += 1 }))
        }
        #expect(acted == 1 && asked == 1, "saying why does nothing else")
    }

    private static let note = Note(
        id: "1", source: Source(host: "m.example", kind: .mastodon), author: "Ada", handle: "@ada@m.example", body: "Words.",
        postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public], statusID: "1"
    )

    @Test("On a post that offers no act, a press on a mark shows its label: its reason, and why the post offers none — the row's old sentence, by touch")
    func aPostsBarSaysWhy() throws {
        let item = DummyItem(Self.note)
        for refusal in PostActRefusal.allCases {
            let acting = ItemActing(acts: PostActs(offered: [], refused: refusal), perform: { _ in }, keep: {}, ask: { _ in })
            let marks = ItemActs.marks(on: item, acting: acting, language: .english)
            let answer = try #require(marks.first { $0.kind == .act(.answer) })
            #expect(ItemActs.press(answer, acting: acting), "\(refusal): the press says why")
            #expect(answer.label.contains(ItemActs.refusalLine(refusal, language: .english)))
            let keep = try #require(marks.first { $0.kind == .keep })
            #expect(!ItemActs.press(keep, acting: acting), "keeping is live and acts")
        }
        // Quoting, dim on a row that cannot quote, says its own sentence.
        let quote = try #require(ItemActs.marks(on: item, acting: ItemActing(), language: .english).first { $0.kind == .quote })
        #expect(ItemActs.press(quote, acting: ItemActing()))
        #expect(quote.label.contains(ItemActs.quoteLine(language: .english)))
    }

    @Test("A bookmark to be asked again still asks, and says nothing; in a list that cannot ask it says why")
    func askingStillAsks() throws {
        let item = DummyItem(Self.note)
        var asked: [PostAct] = []
        let asking = ItemActing(acts: PostActs(offered: [.answer], asking: [.bookmark]), perform: { _ in }, ask: { asked.append($0) })
        let bookmark = try #require(ItemActs.marks(on: item, acting: asking).first { $0.isBookmark })
        #expect(!ItemActs.press(bookmark, acting: asking) && asked == [.bookmark])
        let silent = ItemActing(acts: asking.acts)
        let dim = try #require(ItemActs.marks(on: item, acting: silent).first { $0.isBookmark })
        #expect(ItemActs.press(dim, acting: silent) && asked == [.bookmark])
    }

    @Test("A source row's permission glyph, held, says why when pressed; live, it asks again")
    func aSourcesMarkSaysWhy() throws {
        let row = SourceRow(
            source: Source(host: "micro.example", kind: .mastodon), profile: .unasked(host: "micro.example", kind: .mastodon),
            signedIn: true, writing: .refused
        )
        let held = try #require(SourceRow.permission(row, actsLive: false))
        let live = try #require(SourceRow.permission(row, actsLive: true))
        var asked = 0
        #expect(ShellMark.pressed(held.look, act: { asked += 1 }, ask: nil) && asked == 0)
        #expect(!ShellMark.pressed(live.look, act: { asked += 1 }, ask: nil) && asked == 1)
        #expect(held.spoken.contains(SourceRow.permissionLine(row)!))
    }

    @Test("The bar's marks, every mark button and the panel's dim items show their reason in a small line beside them, and a dim item of the panel takes its press")
    func theLineIsDrawnWherePressed() throws {
        let row = try ShellSource.shell("DummyItemRow")
        #expect(row.contains("saying = ItemActs.press(mark, acting: acting)"))
        #expect(row.contains(".modifier(ShellReasonLine(shown: $saying, words: mark.label))"))
        let mark = try ShellSource.shell("ShellMark")
        #expect(mark.contains("saying = ShellMark.pressed(mark.look, act: act, ask: ask)"))
        #expect(mark.contains(".modifier(ShellReasonLine(shown: $saying, words: mark.spoken))"))
        let panel = try ShellSource.shell("ShellMorePanel")
        #expect(panel.contains("if item.answers { choose(item) } else { saying = item.name }"))
        #expect(panel.contains("press(rows.items[lit])"), "Return on a dim item says why, as a press does")
        let head = try ShellSource.shell("PersonHead")
        #expect(head.components(separatedBy: "ShellSaysWhy(words: words)").count - 1 == 2, "a lock the head cannot ask about says why when pressed")
        #expect(!panel.contains(".disabled(!item.answers)"), "a dim item takes its press, to say why")
        #expect(!panel.contains(".sheet(isPresented: $shown"), "the reason is a line, never a sheet")
    }
}
