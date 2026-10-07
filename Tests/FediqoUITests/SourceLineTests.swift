import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// #302: on a narrow page one source is one line.
///
/// What the line gives up, and in what order, is a value and is asked directly. The row is then
/// hosted in the narrow arrangement at a phone's width, for each kind of source and each size of
/// text, and measured: one line tall — the same as its shortest neighbour — and no wider than it
/// was given. A wide page is hosted beside it and must be what it was.
@Suite("On a narrow page one source is one line", .serialized)
@MainActor
struct SourceLineTests {
    init() {
        L10n.language = .english
    }

    @Test("The line gives up the word after the host first, then every control but the first, then that one too; the host is on every rung")
    func theLadder() {
        #expect(SourceFit.ladder == [.whole, .wordless, .folded, .bare])
        #expect(Set(SourceFit.ladder) == Set(SourceFit.allCases))
        #expect(SourceFit.ladder.map(\.drawsWord) == [true, false, false, false])
        let controls: [SourceRow.Control] = [.signIn, .lists, .clear, .remove]
        #expect(SourceFit.whole.shown(controls) == controls && SourceFit.whole.folded(controls).isEmpty)
        #expect(SourceFit.wordless.shown(controls) == controls)
        #expect(SourceFit.folded.shown(controls) == [.signIn] && SourceFit.folded.folded(controls) == [.lists, .clear, .remove])
        #expect(SourceFit.bare.shown(controls).isEmpty && SourceFit.bare.folded(controls) == controls)
        for fit in SourceFit.ladder {
            #expect(fit.shown(controls) + fit.folded(controls) == controls, "\(fit): no control is lost, only folded")
            #expect(fit.hostRoom > 0)
        }
    }

    @Test("The one mark is drawn where a control is folded behind it or the row has something to say, and not otherwise; what takes something away is offered as such; a listener hears the row and then what it says")
    func theOneMark() {
        #expect(!SourceFit.hasMore(folded: [], said: []))
        #expect(SourceFit.hasMore(folded: [.remove], said: []))
        #expect(SourceFit.hasMore(folded: [], said: ["Signing in…"]))
        #expect(SourceFit.destroys(.clear) && SourceFit.destroys(.remove))
        #expect(!SourceFit.destroys(.signIn) && !SourceFit.destroys(.boards) && !SourceFit.destroys(.lists))
        #expect(SourceFit.spoken(row: "m.example, Mastodon", said: []) == "m.example, Mastodon")
        #expect(SourceFit.spoken(row: "m.example", said: ["It refused.", "Try again."]) == "m.example It refused. Try again.")
    }

    @Test("A row with something to say names it where the state word stood: waiting while it only waits, in the plain ink; needs a look otherwise, in the warning's; and the one mark says there is something to read")
    func somethingToSay() {
        #expect(SourceFit.troubleKey(waiting: false, said: []) == nil)
        #expect(SourceFit.troubleKey(waiting: true, said: ["Signing in…"]) == "account.source.state.waiting")
        #expect(SourceFit.troubleKey(waiting: false, said: ["It refused."]) == "account.source.state.trouble")
        #expect(SourceFit.troubleKey(waiting: true, said: ["Signing in…", "It refused."]) == "account.source.state.trouble")
        #expect(!SourceFit.warns(waiting: true, said: ["Signing in…"]) && !SourceFit.warns(waiting: false, said: []))
        #expect(SourceFit.warns(waiting: false, said: ["It refused."]))
        #expect(SourceFit.moreSymbol(waiting: false, said: []) == "ellipsis")
        #expect(SourceFit.moreSymbol(waiting: true, said: ["Signing in…"]) == "hourglass")
        #expect(SourceFit.moreSymbol(waiting: false, said: ["It refused."]) == "exclamationmark.circle")
        #expect(SourceFit.moreKey(said: []) == "account.source.more" && SourceFit.moreKey(said: ["x"]) == "account.source.more.said")
        for key in ["account.source.more", "account.source.more.said", "account.source.state.trouble", "account.source.state.waiting"] {
            #expect(L10n.t(key, language: .english) != key && L10n.t(key, language: .taiwanese) != L10n.t(key, language: .english), "\(key)")
        }
    }

    #if os(macOS)
    private static let sources: [(String, Source, Bool)] = [
        ("signed in", Source(host: "fixture.example", kind: .mastodon), true),
        ("signed out", Source(host: "signed-out.example", kind: .mastodon), false),
        ("a forum with boards", Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 1, name: "General")]), false),
        ("another kind of forum", Source(host: "talk.example", kind: .discourse), false),
        ("a long name", Source(host: "a-rather-long-subdomain.of-a-long-name.example", kind: .mastodon), true),
    ]

    private func row(
        _ source: Source, signedIn: Bool, layout: ShellLayout, width: CGFloat, type: DynamicTypeSize,
        waiting: String? = nil
    ) -> CGSize {
        let view = SourceRowView(
            row: SourceRow(source: source, profile: .unasked(host: source.host, kind: source.kind)), signedIn: signedIn, width: width,
            widest: SourceRow.controls(of: source, signedIn: signedIn),
            actsLive: true, waiting: waiting, refusal: nil,
            signIn: {}, clear: {}, remove: {}, changeBoards: {}, open: {}
        )
        .environment(\.shellLayout, layout)
        .dynamicTypeSize(type)
        // Offered the width and free to be wider: a line that could not give way runs past it.
        let landed = Landed()
        let placed = view
            .background(GeometryReader { place in
                let _ = landed.maxX = place.frame(in: .named("row")).maxX
                Color.clear
            })
            .frame(minWidth: 0, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .coordinateSpace(.named("row"))
        let hosted = NSHostingView(rootView: placed)
        hosted.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        hosted.layoutSubtreeIfNeeded()
        return CGSize(width: landed.maxX, height: hosted.fittingSize.height)
    }

    /// Where the row's far edge landed, written as it is laid out.
    private final class Landed {
        var maxX: CGFloat = 0
    }

    @Test("At 288 points — a 320-point phone's row — every kind of source is one line at every size of text: all one height, a finger tall and no taller than a second line would make it, and no wider than the row",
          arguments: [DynamicTypeSize.medium, .xxLarge, .xxxLarge, .accessibility1])
    func oneLineEach(_ type: DynamicTypeSize) {
        let width: CGFloat = 288
        let line = NSHostingView(rootView: Text("Ag").shellFont(.name).dynamicTypeSize(type).fixedSize()).fittingSize.height
        var heights: [CGFloat] = []
        for (name, source, signedIn) in Self.sources {
            let size = row(source, signedIn: signedIn, layout: .narrow, width: width, type: type)
            #expect(size.width <= width + 0.5, "\(type) \(name): the line is \(size.width) wide in a row \(width) wide")
            #expect(size.height >= SourceRow.touch, "\(type) \(name): a finger tall")
            #expect(size.height < SourceRow.touch + ShellSpace.tight * 2 + line, "\(type) \(name): \(size.height) is more than one line")
            heights.append(size.height)
        }
        #expect(Set(heights.map { ($0 * 2).rounded() / 2 }).count == 1, "\(type): the rows are \(heights) tall")
        // And with something to say, it is still one line: the sentence is behind the mark.
        let waiting = row(Self.sources[2].1, signedIn: false, layout: .narrow, width: width, type: type, waiting: "Signing in to forum.example…")
        #expect(abs(waiting.height - heights[0]) <= 0.5 && waiting.width <= width + 0.5)
    }

    @Test("A wide page draws the row as it did: taller than the one line, with its line held open under the host")
    func wideIsAsItWas() {
        let source = Self.sources[0].1
        let wide = row(source, signedIn: true, layout: .wide, width: 900, type: .large)
        let narrow = row(source, signedIn: true, layout: .narrow, width: 900, type: .large)
        #expect(wide.height > narrow.height + 4, "the wide row is \(wide.height), the one line \(narrow.height)")
        // Taller than one line would be even with a wide page's room above and below it: the
        // line held open under the host is still there.
        #expect(wide.height > SourceRow.touch + ShellSpace.step * 2 + 2, "the wide row is \(wide.height) tall")
    }
    #endif
}
