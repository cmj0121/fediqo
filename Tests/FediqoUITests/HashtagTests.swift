import Foundation
import SwiftUI
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

    /// **Equal by construction**, as the link's own test is: what is held is that the plate and
    /// the room are on it, and that the two things that would make it read as a control — an
    /// address and an underline — and a control's ink are not.
    @Test("A tag is drawn on the shell's grey, with room inside, and nothing a control carries")
    func aTagIsALabel() {
        let tag = Self.tag("#swift")
        let plate = ShellChrome.well(.light)
        let drawn = EmojiText.drawn(tag, on: plate)

        var expected = AttributedString("\u{202F}#swift\u{202F}")
        expected.backgroundColor = plate
        #expect(drawn == Text(expected))
        #expect(EmojiText.tagRoom == "\u{202F}")

        // Room inside the plate: without the spaces it is not this drawing.
        var tight = AttributedString("#swift")
        tight.backgroundColor = plate
        #expect(drawn != Text(tight))

        // Nothing that says *press here*.
        var pressable = expected
        pressable.link = URL(string: "https://example.test/tags/swift")!
        #expect(drawn != Text(pressable))
        var underlined = expected
        underlined.underlineStyle = .single
        #expect(drawn != Text(underlined))
        var inked = expected
        inked.foregroundColor = ShellChrome.selectInk(.light)
        #expect(drawn != Text(inked))
    }

    @Test("The plate is the shell's grey in both schemes, never the lamp an address takes")
    func thePlateIsTheShellsGrey() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(ShellChrome.well(scheme) != ShellChrome.selectInk(scheme))
            #expect(ShellChrome.well(scheme) != ShellChrome.selectFill(scheme))
            #expect(ShellChrome.well(scheme) != ShellChrome.page(scheme))
        }
        let tag = Self.tag("#swift")
        #expect(EmojiText.drawn(tag, on: ShellChrome.well(.light))
            != EmojiText.drawn(tag, on: ShellChrome.well(.dark)))
    }

    @Test("A tag and an address beside it are two different drawings")
    func toldApartFromAnAddress() {
        let ink = ShellChrome.selectInk(.dark)
        let plate = ShellChrome.well(.dark)
        let link = PostLink("https://example.test/a")!
        let tag = Self.tag("#a")
        let cut = EmojiRun.prose(in: "https://example.test/a #a", emojis: [])
        #expect(EmojiText.line(cut, [:], at: 0, baseline: -4, linkInk: ink, tagPlate: plate)
            == Text(verbatim: "") + EmojiText.drawn(link, in: ink) + Text(verbatim: " ")
            + EmojiText.drawn(tag, on: plate))
    }

    @Test("A tag at the start, in the middle and at the end is drawn inside the one line")
    func theLineItself() {
        let plate = ShellChrome.well(.light)
        let swift = EmojiText.drawn(Self.tag("#swift"), on: plate)
        func line(_ text: String) -> Text {
            EmojiText.line(EmojiRun.prose(in: text, emojis: []), [:], at: 0, baseline: -4,
                           tagPlate: plate)
        }
        #expect(line("#swift first") == Text(verbatim: "") + swift + Text(verbatim: " first"))
        #expect(line("see #swift now")
            == Text(verbatim: "") + Text(verbatim: "see ") + swift + Text(verbatim: " now"))
        #expect(line("last #swift") == Text(verbatim: "") + Text(verbatim: "last ") + swift)
    }

    @Test("A tag in letters that are not ASCII is drawn exactly as one in ASCII is")
    func notASCII() {
        let plate = ShellChrome.well(.light)
        for word in ["台灣", "日本語", "swift"] {
            var expected = AttributedString("\u{202F}#\(word)\u{202F}")
            expected.backgroundColor = plate
            #expect(EmojiText.line(EmojiRun.prose(in: "請看 #\(word)", emojis: []), [:], at: 0,
                                   baseline: -4, tagPlate: plate)
                == Text(verbatim: "") + Text(verbatim: "請看 ") + Text(expected))
        }
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

    private static func lineHeight(_ text: Text) -> CGFloat {
        let host = NSHostingView(rootView: text.font(EmojiTextRole.body.font(at: .large))
            .frame(width: 720))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test("A plate in the line leaves the line as tall as its words")
    func theLineKeepsItsHeight() {
        let plate = ShellChrome.well(.light)
        func height(_ text: String) -> CGFloat {
            Self.lineHeight(EmojiText.line(EmojiRun.prose(in: text, emojis: []), [:], at: 0,
                                           baseline: -4, tagPlate: plate))
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
