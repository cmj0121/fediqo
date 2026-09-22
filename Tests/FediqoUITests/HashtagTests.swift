import Foundation
import SwiftUI
import Synchronization
import Testing
#if os(macOS)
import AppKit
#endif
@testable import FediqoCore
@testable import FediqoUI

/// A hashtag in a post's words, as far as this package can hold it without a screen (#123).
///
/// What a test can reach: the cut, the `Text` built out of it, what a screen reader is given, and
/// — on macOS — the height a line and a row lay out at. What it cannot: how the plate looks on a
/// display. That is named in the report rather than claimed here.
///
/// `@MainActor` on the suite, for the reason `LinkTests` gives at length.
@MainActor
@Suite("A hashtag in a post")
struct HashtagTests {
    private static func tag(_ text: String) -> PostTag { PostTag(text)! }

    // MARK: - How it is drawn

    /// The tag's run as a line would carry it: the room, the letters, and the mark.
    private static func marked(_ text: String) -> Text {
        Text(verbatim: "\u{202F}\(text)\u{202F}").customAttribute(PostTagMark())
    }

    /// **Equal by construction**, as the link's own test is: what is held is that the mark and
    /// the room are on it, and that the two things that would make it read as a control — an
    /// address and an underline — and a control's ink are not.
    @Test("A tag is the word with room inside, marked for a pill, and nothing a control carries")
    func aTagIsALabel() {
        let drawn = EmojiText.drawn(Self.tag("#swift"))
        #expect(drawn == Self.marked("#swift"))
        #expect(EmojiText.tagRoom == "\u{202F}")

        // The mark is what the renderer looks for: without it there is no pill.
        #expect(drawn != Text(verbatim: "\u{202F}#swift\u{202F}"))
        // Room inside the pill: without the spaces it is not this drawing.
        #expect(drawn != Text(verbatim: "#swift").customAttribute(PostTagMark()))

        // Nothing that says *press here*, and no colour of its own: the plate is the renderer's.
        var plain = AttributedString("\u{202F}#swift\u{202F}")
        var pressable = plain
        pressable.link = URL(string: "https://example.test/tags/swift")!
        #expect(drawn != Text(pressable).customAttribute(PostTagMark()))
        var underlined = plain
        underlined.underlineStyle = .single
        #expect(drawn != Text(underlined).customAttribute(PostTagMark()))
        plain.foregroundColor = ShellChrome.selectInk(.light)
        #expect(drawn != Text(plain).customAttribute(PostTagMark()))
    }

    /// A capsule and not a rectangle: its ends are round, so a corner of the run's box is outside
    /// the plate while the middle of each end is inside it.
    @Test("The plate is a capsule round the run, outset sideways and not upright")
    func thePlateIsACapsule() {
        let run = CGRect(x: 10, y: 0, width: 60, height: 20)
        let plate = TagPlates.plate(around: run)
        let outset = run.height * TagPlates.plateOutset
        #expect(plate.boundingRect.minX == run.minX - outset)
        #expect(plate.boundingRect.maxX == run.maxX + outset)
        #expect(plate.boundingRect.minY == run.minY)
        #expect(plate.boundingRect.maxY == run.maxY)
        // Round ends: the box's corners are not on the plate, the ends' middles are.
        #expect(!plate.contains(CGPoint(x: run.minX - outset + 0.5, y: run.minY + 0.5)))
        #expect(!plate.contains(CGPoint(x: run.maxX + outset - 0.5, y: run.maxY - 0.5)))
        #expect(plate.contains(CGPoint(x: run.minX - outset + 0.5, y: run.midY)))
        #expect(plate.contains(CGPoint(x: run.maxX + outset - 0.5, y: run.midY)))
        // Two tags an ordinary space apart stay two pills at the body size.
        #expect(outset * 2 < 4.5)
    }

    @Test("The plate is the shell's grey in both schemes, never the lamp an address takes")
    func thePlateIsTheShellsGrey() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(ShellChrome.well(scheme) != ShellChrome.selectInk(scheme))
            #expect(ShellChrome.well(scheme) != ShellChrome.selectFill(scheme))
            #expect(ShellChrome.well(scheme) != ShellChrome.page(scheme))
        }
        #expect(ShellChrome.well(.light) != ShellChrome.well(.dark))
    }

    @Test("Only a line with a tag in it is given the renderer")
    func onlyATaggedLineIsPlated() {
        #expect(EmojiText.hasTags(EmojiRun.prose(in: "see #swift", emojis: [])))
        #expect(!EmojiText.hasTags(EmojiRun.prose(in: "see https://example.test/#top", emojis: [])))
        #expect(!EmojiText.hasTags(CustomEmoji.runs(in: "see #swift", from: [])))
    }

    @Test("A tag and an address beside it are two different drawings")
    func toldApartFromAnAddress() {
        let ink = ShellChrome.selectInk(.dark)
        let link = PostLink("https://example.test/a")!
        let cut = EmojiRun.prose(in: "https://example.test/a #a", emojis: [])
        #expect(EmojiText.line(cut, [:], at: 0, baseline: -4, linkInk: ink)
            == Text(verbatim: "") + EmojiText.drawn(link, in: ink) + Text(verbatim: " ")
            + Self.marked("#a"))
    }

    /// The line is the plain words and the marked tag, concatenated — so the tag's segment is the
    /// only one carrying the mark. `renderedMarks` below asks the laid-out line the same thing.
    @Test("A tag at the start, in the middle and at the end is drawn inside the one line")
    func theLineItself() {
        let swift = Self.marked("#swift")
        func line(_ text: String) -> Text {
            EmojiText.line(EmojiRun.prose(in: text, emojis: []), [:], at: 0, baseline: -4)
        }
        #expect(line("#swift first") == Text(verbatim: "") + swift + Text(verbatim: " first"))
        #expect(line("see #swift now")
            == Text(verbatim: "") + Text(verbatim: "see ") + swift + Text(verbatim: " now"))
        #expect(line("last #swift") == Text(verbatim: "") + Text(verbatim: "last ") + swift)
    }

    @Test("A tag in letters that are not ASCII is drawn exactly as one in ASCII is")
    func notASCII() {
        for word in ["台灣", "日本語", "swift"] {
            #expect(EmojiText.line(EmojiRun.prose(in: "請看 #\(word)", emojis: []), [:], at: 0,
                                   baseline: -4)
                == Text(verbatim: "") + Text(verbatim: "請看 ") + Self.marked("#\(word)"))
        }
    }

    /// What the renderer is actually handed once a line is laid out: which runs carry the mark,
    /// and how many plates `TagPlates` would draw from them. Recorded by a renderer that draws
    /// the line and nothing of its own.
    private final class Seen: Sendable {
        let pass = Mutex<(marks: [Bool], plates: Int)>(([], 0))
    }

    private struct Recorder: TextRenderer {
        let seen: Seen

        /// One pass's worth: `ImageRenderer` draws a line more than once, so each pass replaces
        /// the last rather than adding to it.
        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            var marks: [Bool] = []
            var plates = 0
            for line in layout {
                let runs = line.map { ($0[PostTagMark.self] != nil, $0.typographicBounds.rect) }
                marks += runs.map(\.0)
                plates += TagPlates.plateBounds(runs).count
                context.draw(line)
            }
            seen.pass.withLock { $0 = (marks, plates) }
        }
    }

    private static func rendered(_ text: String) -> (marks: [Bool], plates: Int) {
        let seen = Seen()
        let line = EmojiText.line(EmojiRun.prose(in: text, emojis: []), [:], at: 0, baseline: -4)
        let renderer = ImageRenderer(content: line.font(EmojiTextRole.body.font(at: .large))
            .textRenderer(Recorder(seen: seen)).frame(width: 720, alignment: .leading))
        _ = renderer.cgImage
        return seen.pass.withLock { $0 }
    }

    @Test("Laid out, only a tag's runs carry the mark, and each tag is one plate")
    func laidOut() {
        let one = Self.rendered("see #swift now")
        #expect(one.plates == 1)
        // The words either side are laid out, and are not marked.
        #expect(one.marks.first == false && one.marks.last == false)

        // A tag in a fallback face is several runs; it is still one plate, and so is every other.
        let cjk = Self.rendered("看 #台灣")
        #expect(cjk.marks.filter { $0 }.count > 1)
        #expect(cjk.plates == 1)
        #expect(Self.rendered("#one and #二 and #three").plates == 3)

        let none = Self.rendered("see https://example.test/#top, c#not")
        #expect(!none.marks.isEmpty)
        #expect(none.marks.allSatisfy { !$0 })
        #expect(none.plates == 0)
    }

    /// The renderer itself, drawn: a plate in a colour nothing else on the image has, then its
    /// painted extent read back. A rectangle would fill the corners of that extent; a capsule
    /// leaves them empty and fills the middle of each end.
    @Test("Drawn, the plate is a capsule with round ends, not a rectangle")
    func drawnAsACapsule() throws {
        let line = EmojiText.line(EmojiRun.prose(in: "#swift", emojis: []), [:], at: 0, baseline: -4)
        let renderer = ImageRenderer(content: line.font(.system(size: 40))
            .foregroundStyle(Color.clear)
            .textRenderer(TagPlates(plate: Color(red: 1, green: 0, blue: 0)))
            .padding(20))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func painted(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return pixels[i] > 200 && pixels[i + 1] < 60 && pixels[i + 3] > 200
        }
        var xs: [Int] = [], ys: [Int] = []
        for y in 0 ..< height { for x in 0 ..< width where painted(x, y) { xs.append(x); ys.append(y) } }
        let minX = try #require(xs.min()), maxX = try #require(xs.max())
        let minY = try #require(ys.min()), maxY = try #require(ys.max())
        let midY = (minY + maxY) / 2
        #expect(maxX - minX > maxY - minY, "wider than tall, like a pill")
        for (x, y) in [(minX, minY), (maxX, minY), (minX, maxY), (maxX, maxY)] {
            #expect(!painted(x, y), "corner \(x),\(y) is outside a capsule")
        }
        #expect(painted(minX + 1, midY))
        #expect(painted(maxX - 1, midY))
    }

    @Test("A tag's runs on one line are joined into one plate, and an unmarked run parts two")
    func plateBounds() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 18)
        let b = CGRect(x: 10, y: -1, width: 20, height: 20)
        let gap = CGRect(x: 30, y: 0, width: 4, height: 18)
        let c = CGRect(x: 34, y: 0, width: 10, height: 18)
        #expect(TagPlates.plateBounds([(true, a), (true, b), (false, gap), (true, c)])
            == [a.union(b), c])
        #expect(TagPlates.plateBounds([(false, a), (false, gap)]).isEmpty)
        // The taller face sets the plate for the whole word.
        #expect(TagPlates.plateBounds([(true, a), (true, b)]).first?.height == 20)
    }

    @Test("A post that carries no tag is drawn exactly as it was")
    func noTagNoChange() {
        let cache = EmojiCache(http: FixtureHTTP())
        for text in ["just words", "c#not a tag", "a # b", "see https://example.test/#top"] {
            #expect(!cache.proseRuns(in: text, from: []).contains { if case .tag = $0 { true } else { false } })
        }
        #expect(EmojiText.line(cache.proseRuns(in: "just words", from: []), [:], at: 0, baseline: -4)
            == Text(verbatim: "") + Text(verbatim: "just words"))
    }

    // MARK: - Not a control

    /// There is nothing to open. A line whose only mark is a tag has no address, so `ProseLinks`
    /// installs no press, no menu and no hint, and `LinkWays` names no action for VoiceOver.
    @Test("A tag gives the line nothing to press and names no action")
    func aTagIsNotAControl() {
        let cut = EmojiRun.prose(in: "#swift and #台灣", emojis: [])
        #expect(EmojiText.links(in: cut).isEmpty)
    }

    // MARK: - What a screen reader is given

    @Test("Through VoiceOver the word is read as written and said to be a hashtag")
    func spoken() {
        let said = { (word: String) in String(format: L10n.t("post.tag.spoken"), word) }
        #expect(EmojiText.spoken(EmojiRun.prose(in: "see #swift now", emojis: []))
            == Text(verbatim: "see \(said("swift")) now"))
        #expect(EmojiText.spoken(EmojiRun.prose(in: "請看 #台灣。", emojis: []))
            == Text(verbatim: "請看 \(said("台灣"))。"))
        // The word as written: case and script kept, the `#` given back as a word.
        #expect(said("SwiftUI").contains("SwiftUI"))
        #expect(!said("SwiftUI").contains("#"))
    }

    @Test("Every language the app speaks says the tag and the word")
    func spokenInEveryLanguage() {
        for language in [DummyLanguage.english, .taiwanese] {
            let sentence = L10n.t("post.tag.spoken", language: language)
            #expect(sentence != "post.tag.spoken")
            #expect(String(format: sentence, "台灣").contains("台灣"))
        }
    }

    @Test("A line with no tag is read exactly as it was typed, shortcodes and all")
    func noTagIsReadAsTyped() {
        let blobcat = CustomEmoji(shortcode: "blobcat", url: URL(string: "https://e.test/b.png")!)
        for text in ["Ada :blobcat: Lovelace", "see https://example.test/#top", "c#not", "#1 fan"] {
            #expect(EmojiText.spoken(CustomEmoji.runs(in: text, from: [blobcat]))
                == Text(verbatim: text))
        }
        #expect(EmojiText.spoken(EmojiRun.prose(in: "see https://example.test/#top :blobcat:",
                                                emojis: [blobcat]))
            == Text(verbatim: "see https://example.test/#top :blobcat:"))
    }

    /// A name and a covered post are cut as labels, so they neither draw a pill nor are said to
    /// hold a tag — what is said follows what is drawn.
    @Test("A name or a covered post is not said to carry a tag")
    func labelsAreNotTagged() {
        let cache = EmojiCache(http: FixtureHTTP())
        let name = EmojiText("#1 fan", emojis: [], host: "e.test", role: .name, cache: cache)
        #expect(name.accessibilityText == Text(verbatim: "#1 fan"))
        let covered = EmojiText.words("see #swift", emojis: [], host: "e.test", covered: true)
        #expect(covered.linked == false)
        let lifted = EmojiText(prose: "see #swift", emojis: [], host: "e.test", cache: cache)
        #expect(lifted.accessibilityText
            == Text(verbatim: "see " + String(format: L10n.t("post.tag.spoken"), "swift")))
    }

    #if os(macOS)
    // MARK: - The line and the row keep their height

    /// One line, measured with the plates drawn — the renderer the row gives a tagged line.
    private static func lineHeight(_ text: Text, plate: Color) -> CGFloat {
        let host = NSHostingView(rootView: text.font(EmojiTextRole.body.font(at: .large))
            .textRenderer(TagPlates(plate: plate))
            .frame(width: 720))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test("A plate in the line leaves the line as tall as its words")
    func theLineKeepsItsHeight() {
        func height(_ text: String) -> CGFloat {
            let plated = EmojiText.line(EmojiRun.prose(in: text, emojis: []), [:], at: 0,
                                        baseline: -4)
            return Self.lineHeight(plated, plate: ShellChrome.well(.light))
        }
        let plain = height("a line of words about swift and 台灣")
        #expect(height("#swift a line of words about swift and 台灣") == plain)
        #expect(height("a line of words about #swift and 台灣") == plain)
        #expect(height("a line of words about swift and #台灣") == plain)
    }

    private static func rowHeight(body: String) -> CGFloat {
        let item = DummyItem(Note(
            id: "n1", source: Source(host: "first.example", kind: .mastodon), author: "Ada",
            handle: "@ada@author.example", body: body, postedAt: Date(timeIntervalSince1970: 0),
            categories: [.public]
        ))
        let row = DummyItemRow(item: item, catalogues: EmojiCatalogueStore(), posts: ForumPosts(),
                               marks: .constant(DummyMarks()), onToast: { _ in })
            .frame(width: 720)
        let host = NSHostingView(rootView: row)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test("A timeline row is one height whatever a post tagged")
    func theRowKeepsItsHeight() {
        let many = (0 ..< 200).map { "#t\($0)" }.joined(separator: " ")
        let heights = Set([
            "words",
            "#swift",
            "about #swift in the middle and at the end #台灣",
            many,
        ].map(Self.rowHeight))
        #expect(heights.count == 1, "one height, got \(heights.sorted())")
    }
    #endif
}
