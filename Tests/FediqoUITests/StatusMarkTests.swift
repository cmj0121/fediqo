#if os(macOS)
import AppKit
#endif
import SwiftUI
import Testing
@testable import FediqoUI

@MainActor
@Suite("A page's status mark: every source's state behind one count (#396)")
struct StatusMarkTests {
    @Test("The mark counts sources, one each however many lines it has, and a line about the whole page once")
    func countsSources() {
        let lines = [
            StatusLine(id: "unasked:a.example", host: "a.example", words: "a"),
            StatusLine(id: "said:a.example", host: "a.example", words: "a again"),
            StatusLine(id: "locked:b.example", host: "b.example", words: "b"),
            StatusLine(id: "foot:limit", host: nil, words: "limit"),
        ]
        #expect(StatusWords.count(lines) == 3)
        #expect(StatusWords.count([]) == 0)
    }

    @Test("A line that only informs is listed and not counted: with only such lines the mark is quiet and has no number")
    func informingIsNotCounted() {
        let informs = [
            StatusLine(id: "onWay:1", host: "a.example", words: "on its way", needsReader: false),
            StatusLine(id: "foot:limit", host: nil, words: "limit", needsReader: false),
        ]
        #expect(StatusWords.count(informs) == 0)
        #expect(StatusWords.spoken(informs, language: .english) == "No source needs you. Opens what there is to know of them.")
        #expect(!StatusWords.spoken(informs, language: .english).contains("1 source"))
        #expect(L10n.t("status.mark.quiet.spoken", language: .taiwanese) != "status.mark.quiet.spoken")
        let mixed = informs + [StatusLine(id: "locked:b.example", host: "b.example", words: "b")]
        #expect(StatusWords.count(mixed) == 1)
        #expect(StatusWords.spoken(mixed, language: .english) == "1 source needs you. Opens what it needs.")
    }

    @Test("A press in the list closes the list before it acts")
    func pressClosesFirst() {
        var order: [String] = []
        let press = StatusPress(kind: .again, spoken: "Again") { order.append("act") }
        StatusList.pressed(press) { order.append("close") }
        #expect(order == ["close", "act"])
        #expect(StatusPress(kind: .ask, spoken: "") {}.symbol == SourceRow.permissionSymbol)
    }

    @Test("A listener hears the count and what the mark opens, in each language")
    func spoken() {
        let one = [StatusLine(id: "unasked:a.example", host: "a.example", words: "a")]
        let two = one + [StatusLine(id: "locked:b.example", host: "b.example", words: "b")]
        #expect(StatusWords.spoken(one, language: .english) == "1 source needs you. Opens what it needs.")
        #expect(StatusWords.spoken(two, language: .english) == "2 sources need you. Opens what each one needs.")
        let chinese = StatusWords.spoken(two, language: .taiwanese)
        #expect(chinese.contains("2") && chinese != StatusWords.spoken(two, language: .english))
        for key in ["status.press.ask", "status.press.again", "status.press.again.ask.spoken",
                    "status.press.again.read.spoken", "status.press.again.notices.spoken", "notices.foot.endMark"] {
            #expect(L10n.t(key, language: .taiwanese) != key, "\(key) has no 繁體中文")
            #expect(L10n.t(key, language: .english) != key, "\(key) has no English")
        }
    }

    @Test("The foot is a press while older notices can be read, and otherwise one plain end mark")
    func footIsAPlainEnd() {
        #expect(NoticesFootRow.spoken(.more, language: .english) == NoticesFoot.more.words(language: .english))
        for foot in [NoticesFoot.held, .limit, .full, .end] {
            #expect(NoticesFootRow.spoken(foot, language: .english) == "End of notices")
        }
    }

    #if os(macOS)
    @Test("The list is whole at 320 and 600 across: every sentence at the height it asks for, every press unsqueezed",
          arguments: [CGFloat(320), 600])
    func theListIsWhole(_ width: CGFloat) async {
        let long = String(repeating: "a-rather-long-instance-name.example was not read: the read was stopped. ", count: 3)
        let lines = [
            StatusLine(id: "unasked:a.example", host: "a.example", words: "a.example has not been asked for your notices.",
                       press: StatusPress(kind: .ask, spoken: "Ask a.example") {}),
            StatusLine(id: "unread:long", host: "long", words: long, press: StatusPress(kind: .again, spoken: "Again") {}),
            StatusLine(id: "foot:limit", host: nil, words: "Older notices are older than kept.", needsReader: false),
        ]
        let probe = StatusProbe()
        let view = NSHostingView(
            rootView: StatusList(lines: lines, close: {}).environment(\.shellStatusProbe, probe).frame(width: width)
        )
        view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        for _ in 0..<20 {
            view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        for line in lines {
            guard let words = probe.frames[.words(line.id)] else {
                Issue.record("\(width): \(line.id) is not drawn")
                continue
            }
            #expect(words.maxX <= width + 0.5, "\(width): \(line.id) runs past the list")
            let asks = NSHostingView(
                rootView: Text(line.words).shellFont(.meta).fixedSize(horizontal: false, vertical: true).frame(width: words.width)
            ).fittingSize.height
            #expect(words.height >= asks - 0.5, "\(width): \(line.id) is cut: \(words.height) of \(asks)")
            guard let press = line.press else {
                #expect(probe.frames[.press(line.id)] == nil)
                continue
            }
            let drawn = probe.frames[.press(line.id)] ?? .zero
            let whole = NSHostingView(
                rootView: ShellLinkButton(press.word(), symbol: press.symbol) {}.fixedSize()
            ).fittingSize
            // A hosting view's fitting size is rounded up to whole points: one point is rounding.
            #expect(drawn.width >= whole.width - 1 && drawn.height >= whole.height - 1, "\(width): \(line.id)'s press is squeezed: \(drawn) of \(whole); words \(words)")
        }
    }
    #endif
}
