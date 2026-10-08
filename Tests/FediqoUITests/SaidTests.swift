import AppKit
import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// What did not happen is said on every page: what the session holds of it (`ShellSaid`), how
/// long a line stands, the sentences, and the strip the root draws at each page's foot
/// (`SaidStrip`).
///
/// **What this reaches.** The lines and their lifetime as the session holds them; each
/// sentence in each language; the strip hosted in an `NSHostingView` at 600 and 320 points,
/// each part reporting where it was laid out.
///
/// **What it does not reach.** No window is made: light and dark, the strip under a sheet and
/// over the tabs on a phone, the count's sheet opened, and VoiceOver itself are for a person
/// on a running app.
@Suite("What did not happen is said on every page", .serialized)
@MainActor
struct SaidTests {
    private typealias F = NoticeActFixture
    private static let a = F.a
    private static let b = F.b
    private static let long = "a-rather-long-instance-name.example"

    private static func row(_ host: String, _ id: Int) -> String { "\(host)\u{1e}\(id)" }

    private static func boost(_ host: String, _ id: Int, _ why: WriteWhy = .unreachable) -> Said {
        Said(.act(.boost, row: row(host, id)), why, host: host)
    }

    // MARK: - What is held, and for how long

    @Test("A line is said in front of the others, and the same act at the same source said again replaces its line")
    func saidNewestFirstAndReplaced() {
        let said = ShellSaid()
        said.announce = { _ in }
        said.say(Self.boost(Self.a, 1))
        said.say(Said(.notice(.dismiss), .refused, host: Self.a))
        said.say(Self.boost(Self.a, 2))
        #expect(said.lines.map(\.what) == [
            .act(.boost, row: Self.row(Self.a, 2)), .notice(.dismiss), .act(.boost, row: Self.row(Self.a, 1)),
        ])

        // The same boost of the same post fails again, for another reason: one line, in front.
        said.say(Self.boost(Self.a, 1, .unconfirmed))
        #expect(said.lines.count == 3)
        #expect(said.lines.first == Self.boost(Self.a, 1, .unconfirmed))
        // Another act on that post, and the same act at another source, are lines of their own.
        said.say(Said(.act(.favourite, row: Self.row(Self.a, 1)), .unreachable, host: Self.a))
        said.say(Said(.notice(.dismiss), .refused, host: Self.b))
        #expect(said.lines.count == 5)
        #expect(Said.id(.notice(.dismiss), host: "A.Example") == Said.id(.notice(.dismiss), host: Self.a), "a host is one source however it is written")
    }

    @Test("A line stands until it is taken down, its act succeeds, or its source leaves; nothing goes by itself")
    func aLineStandsUntilAnswered() async throws {
        let said = ShellSaid()
        said.announce = { _ in }
        said.say(Self.boost(Self.a, 1))
        said.say(Self.boost(Self.b, 1))
        said.say(Said(.notice(.letGo), .declined, host: Self.b))
        try await Task.sleep(for: .milliseconds(50))
        #expect(said.lines.count == 3)

        // Its own press, and the same act having since succeeded, by the same name.
        said.takeDown(Said.id(.act(.boost, row: Self.row(Self.a, 1)), host: Self.a))
        #expect(said.lines.map(\.host) == [Self.b, Self.b])
        said.takeDown("nothing said under this")
        #expect(said.lines.count == 2)

        said.say(Self.boost(Self.a, 2))
        said.forget(host: "B.Example")
        #expect(said.lines == [Self.boost(Self.a, 2)])
        said.clear()
        #expect(said.lines.isEmpty)
    }

    @Test("A burst cannot fill the page: twenty lines are held, the oldest goes, and a page draws three — one where it is narrow — and counts the rest")
    func aBurstIsBounded() {
        let said = ShellSaid()
        said.announce = { _ in }
        for id in 1...25 { said.say(Self.boost(Self.a, id)) }
        #expect(said.lines.count == ShellSaid.kept && ShellSaid.kept == 20)
        #expect(said.lines.first == Self.boost(Self.a, 25) && said.lines.last == Self.boost(Self.a, 6))

        let drawn = SaidStrip.drawn(said.lines, in: .wide)
        #expect(drawn.shown == Array(said.lines.prefix(3)) && drawn.more == 17)
        #expect(SaidStrip.drawn(Array(said.lines.prefix(3)), in: .wide).more == 0)
        let narrow = SaidStrip.drawn(said.lines, in: .narrow)
        #expect(narrow.shown == [said.lines[0]] && narrow.more == 19)
        #expect(SaidStrip.drawn([said.lines[0]], in: .narrow).more == 0)
        #expect(SaidStrip.drawn([], in: .wide).shown.isEmpty)
        #expect(SaidStrip.more(17, language: .english).word == "17 more")
        #expect(SaidStrip.more(1, language: .english).spoken == "1 more thing not done. Show them all.")
        #expect(SaidStrip.more(2, language: .english).spoken == "2 more things not done. Show them all.")
    }

    @Test("A new line is said aloud once, in its own sentence; taking one down says nothing")
    func aNewLineIsAnnouncedOnce() {
        let said = ShellSaid()
        var aloud: [String] = []
        said.announce = { aloud.append($0) }
        let line = Said(.notice(.dismiss), .refused, host: Self.a)
        said.say(line)
        #expect(aloud == [line.words()])

        said.takeDown(line.id)
        said.forget(host: Self.a)
        said.clear()
        #expect(aloud.count == 1)
        // Failing again is a new thing to hear.
        said.say(line)
        #expect(aloud.count == 2 && said.lines.count == 1)
    }

    // MARK: - The sentences

    @Test("A notice's line is the sentence the notices page says of it, and every act a line can be about has words in each language")
    func theSentences() {
        func words(_ what: Said.What, _ why: WriteWhy, _ language: DummyLanguage = .english) -> String {
            Said(what, why, host: Self.a).words(language: language)
        }
        #expect(words(.notice(.dismiss), .refused) == "a.example would not let this sign-in dismiss the notice. It is still here.")
        #expect(words(.notice(.dismiss), .refused)
            == NoticeActs.words(.init(act: .dismiss, why: .refused), host: Self.a, language: .english))
        let row = Self.row(Self.a, 1)
        #expect(words(.act(.withdraw, row: row), .refused) == "a.example would not let this sign-in take the post back. It is still here.")
        #expect(words(.act(.boost, row: row), .unreachable) == "a.example could not be reached, so the boost did not change. It is as it was.")
        #expect(words(.act(.bookmark, row: row), .declined) == "a.example did not change the bookmark. It is as it was.")
        #expect(words(.act(.favourite, row: row), .unconfirmed) == "a.example did not confirm the favourite changed. Reload to see.")
        #expect(words(.act(.boost, row: row), .locked) == "This device could not read the sign-in for a.example, so it was not asked.")

        let notices: [Said.What] = [ShellNoticeActs.Act.dismiss, .dismissAll, .letThrough, .letGo].map { .notice($0) }
        let acts: [Said.What] = PostAct.allCases.map { .act($0, row: row) }
        for language in [DummyLanguage.english, .taiwanese] {
            for what in notices + acts {
                for why in [WriteWhy.refused, .unreachable, .declined, .unconfirmed, .locked] {
                    let said = words(what, why, language)
                    #expect(
                        said.contains(Self.a) && !said.contains("said.act.") && !said.contains("notices.act."),
                        "\(what) \(why) has no words in \(language)"
                    )
                }
            }
        }
    }

    // MARK: - A source leaving

    @Test("A source that leaves takes what was said of it: a sign-out, a server ending the sign-in, and a Clear")
    func aSourceLeavingTakesItsLines() async throws {
        let (session, _, _) = try await F.shell([:], signedIn: [Self.a: F.acts, Self.b: F.acts, "c.example": F.acts])
        session.said.announce = { _ in }
        func sayAll() {
            for host in [Self.a, Self.b, "c.example"] { session.said.say(Self.boost(host, 1)) }
        }
        sayAll()
        await session.signOut(host: Self.a)
        #expect(session.said.lines.map(\.host) == ["c.example", Self.b])

        session.mastodon.endedByServer(host: Self.b)
        #expect(session.said.lines.map(\.host) == ["c.example"])

        await session.clear(host: "c.example")
        #expect(session.said.lines.isEmpty)
    }

    // MARK: - The strip, hosted

    /// The strip over a page that reports how much room it was left.
    private struct Page: View {
        let said: ShellSaid
        let room: Room

        var body: some View {
            GeometryReader { place in
                let _ = (room.page = place.frame(in: .global))
                Color.clear
            }
            .modifier(SaidStrip(said: said))
        }
    }

    @MainActor
    private final class Room {
        var page = CGRect.zero
    }

    private static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        view.layoutSubtreeIfNeeded()
    }

    private func hosted(
        _ said: ShellSaid, width: CGFloat, layout: ShellLayout = .wide, type: DynamicTypeSize = .large,
        corner: CGSize = .zero
    ) -> (NSView, SaidProbe, Room) {
        let probe = SaidProbe(), room = Room()
        let view = NSHostingView(
            rootView: Page(said: said, room: room)
                .environment(\.shellSaidProbe, probe)
                .environment(\.shellFloatingCorner, corner)
                .environment(\.shellLayout, layout)
                .dynamicTypeSize(type)
        )
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        for _ in 0..<3 { Self.settle(view) }
        return (view, probe, room)
    }

    /// The size a view asks for with nothing holding it in.
    private static func ideal(_ view: some View, _ type: DynamicTypeSize) -> CGSize {
        NSHostingView(rootView: view.fixedSize().dynamicTypeSize(type)).fittingSize
    }

    /// How tall words stand when they are wrapped to `width` and nothing is cut.
    private static func wrapped(_ text: some View, width: CGFloat, _ type: DynamicTypeSize) -> CGFloat {
        NSHostingView(
            rootView: text.fixedSize(horizontal: false, vertical: true).frame(width: width).dynamicTypeSize(type)
        ).fittingSize.height
    }

    private func lines(_ probe: SaidProbe) -> [String] {
        probe.frames.compactMap { part, frame -> (String, CGFloat)? in
            if case .line(let id) = part { (id, frame.minY) } else { nil }
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    @Test("Nothing said draws nothing and takes no room; a line stands under the page, which ends above it")
    func theStripIsAnInset() throws {
        let said = ShellSaid()
        said.announce = { _ in }
        let (_, nothing, whole) = hosted(said, width: 600)
        #expect(nothing.frames.isEmpty)
        #expect(whole.page.height == 700, "an empty strip took room from the page")

        said.say(Said(.notice(.dismiss), .refused, host: Self.a))
        let (_, probe, room) = hosted(said, width: 600)
        let line = try #require(probe.frames[.line(said.lines[0].id)])
        #expect(room.page.height < 700 && line.height > 0)
        // The page and the line share no point: the strip covers nothing the page draws.
        #expect(!room.page.intersects(line), "the line lies over the page")
        #expect(probe.frames[.more] == nil)

        said.takeDown(said.lines[0].id)
        let (_, after, back) = hosted(said, width: 600)
        #expect(after.frames.isEmpty && back.page.height == 700)
    }

    @Test("A wide page draws three lines, newest on top, and a narrow one the newest alone; the rest are behind a count under them",
          arguments: [ShellLayout.wide, .narrow])
    func someLinesAndACount(_ layout: ShellLayout) throws {
        let width: CGFloat = layout == .wide ? 600 : 320
        let said = ShellSaid()
        said.announce = { _ in }
        // From two sources, so no more than three are about one act at one of them: more
        // would be drawn as one line that says how many (`ShellSaid.folded`).
        for id in 1...5 { said.say(Self.boost(id.isMultiple(of: 2) ? Self.a : Self.b, id)) }
        let (_, probe, _) = hosted(said, width: width, layout: layout)
        let drawn = said.lines.prefix(layout == .wide ? 3 : 1).map(\.id)
        #expect(lines(probe) == drawn)
        let more = try #require(probe.frames[.more], "the count of the rest is not drawn")
        let last = try #require(probe.frames[.line(drawn[drawn.count - 1])])
        #expect(more.minY >= last.maxY - 0.5 && more.minX >= -0.5 && more.maxX <= width + 0.5)
    }

    @Test("At 320 points, beside the compose button, the line is not cut: its sentence at the height it asks for, its press whole and clear of the words, the count whole",
          arguments: [DummyFontSize.standard.dynamicType, DummyFontSize.largest.dynamicType, DynamicTypeSize.accessibility2])
    func nothingCutAt320(_ type: DynamicTypeSize) throws {
        let width: CGFloat = 320
        let corner = FediqoRootView.composeCorner(canCompose: true)
        let said = ShellSaid()
        said.announce = { _ in }
        said.say(Said(.notice(.letThrough), .unreachable, host: Self.long))
        said.say(Said(.act(.withdraw, row: Self.row(Self.long, 1)), .refused, host: Self.long))
        for id in 1...3 { said.say(Self.boost(Self.long, id, .unconfirmed)) }

        let (_, probe, room) = hosted(said, width: width, layout: .narrow, type: type, corner: corner)
        // And at the sizes the app reaches, one line with its count is well under half a phone.
        if type <= DummyFontSize.largest.dynamicType {
            #expect(700 - room.page.height <= 240, "\(type): the strip stands \(700 - room.page.height) points tall")
        }
        // Everything stands to the leading side of the corner the button floats in.
        let edge = width - corner.width
        for (part, frame) in probe.frames {
            #expect(frame.minX >= -0.5 && frame.maxX <= edge + 0.5, "\(type): \(part) runs under the compose button or off the page")
        }
        let box = Self.ideal(ShellIconButton("xmark", name: "said.close") {}, type)
        #expect(lines(probe) == [said.lines[0].id])
        for line in said.lines.prefix(1) {
            let words = try #require(probe.frames[.words(line.id)], "\(type): \(line.id) is not drawn")
            let asks = Self.wrapped(Text(line.words()).shellFont(.meta), width: words.width, type)
            #expect(words.height >= asks - 0.5, "\(type): the sentence is cut: \(words.height) of \(asks)")
            let close = try #require(probe.frames[.close(line.id)])
            // `fittingSize` is whole points, rounded up.
            #expect(close.width >= box.width - 1 && close.height >= box.height - 1, "\(type): the press to close is squeezed")
            #expect(close.minX >= words.maxX - 0.5, "\(type): the press lies over the words")
        }
        let more = try #require(probe.frames[.more])
        let word = Self.ideal(ShellLinkButton(SaidStrip.more(4).word) {}, type)
        #expect(more.width >= word.width - 0.5 && more.height >= word.height - 0.5, "\(type): the count is cut")
    }
}
