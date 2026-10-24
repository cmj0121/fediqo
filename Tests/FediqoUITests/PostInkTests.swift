import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #386: in a post's words a link reads light blue, a hashtag quiet grey, and a name as a name —
/// and the lamp says nothing there.
///
/// What a test can reach: which ink each is given, what each measures on every plate, the `Text`
/// each is built as, which runs a laid-out line marks for an underline, and which underlines the
/// renderer draws at rest and under a pointer. What it cannot: how the blue looks beside the teal
/// on a screen, or through a colour filter. That is named in the report rather than claimed here.
@MainActor
@Suite("A post's words write a link, a tag and a name each in its own ink")
struct PostInkTests {
    private static let schemes: [ColorScheme] = [.light, .dark]
    private static let swift = PostTag("#Swift")!
    private static let ada = PostMention(text: "@ada", handle: "@ada@m.example")

    // MARK: - Which ink

    @Test("A link is the link's blue, a tag the quiet grey, a name the words' ink — and none is the lamp")
    func theThreeInks() {
        for scheme in Self.schemes {
            let inks = EmojiText.inks(scheme, tags: true, names: true)
            #expect(inks.link == ShellChrome.link(scheme))
            #expect(inks.tag == ShellChrome.inkFaint(scheme))
            #expect(inks.name == ShellChrome.ink(scheme))
            for ink in [inks.link, inks.tag, inks.name] {
                #expect(ink != ShellChrome.phosphor(scheme), "the lamp in a post's words in \(scheme)")
            }
            // Where a press opens nothing, a tag and a name are the letters they were.
            let outside = EmojiText.inks(scheme, tags: false, names: false)
            #expect(outside.tag == nil && outside.name == nil)
            #expect(outside.link == ShellChrome.link(scheme))
            // On a line written a step down the ramp, a name takes that step too.
            #expect(EmojiText.inks(scheme, tags: true, names: true, quiet: true).name == ShellChrome.inkDim(scheme))
        }
    }

    /// The blue stands apart from the lamp's teal by hue and leans toward the page's violet: its
    /// hue on the wheel is further round than the lamp's, by more than a nudge.
    @Test("The link's blue is its own hue, past the lamp's teal toward the page's violet")
    func theBlueIsNotTheLamp() {
        for scheme in Self.schemes {
            let link = Self.hue(ShellChrome.link(scheme), scheme)
            let lamp = Self.hue(ShellChrome.phosphor(scheme), scheme)
            #expect(link - lamp >= 15, "the link is \(link)° and the lamp \(lamp)° in \(scheme)")
            #expect(link < 285, "the link leans toward the page's violet, short of it, in \(scheme)")
        }
    }

    // MARK: - Can be read

    /// Every plate a post's words are written on, the lamp's wash over a selected row and a
    /// pointer's wash among them. A tag is written on its own pill, so its ground is the recess
    /// laid over whichever plate the row is on.
    @Test("A link, a tag on its pill and a name clear 4.5:1 on every plate, the selected wash included")
    func eachCanBeRead() {
        for scheme in Self.schemes {
            let inks = EmojiText.inks(scheme, tags: true, names: true)
            for (named, ground) in ShellContrast.plates(scheme, washed: true) {
                let link = ShellContrast.ratio(inks.link, on: ground, scheme)
                #expect(link >= 4.5, "a link is \(link):1 on \(named) in \(scheme)")
                let name = ShellContrast.ratio(inks.name!, on: ground, scheme)
                #expect(name >= 4.5, "a name is \(name):1 on \(named) in \(scheme)")
                let quiet = EmojiText.inks(scheme, tags: true, names: true, quiet: true).name!
                let quietName = ShellContrast.ratio(quiet, on: ground, scheme)
                #expect(quietName >= 4.5, "a name on a quiet line is \(quietName):1 on \(named) in \(scheme)")
                let tag = ShellContrast.ratio(inks.tag!, on: ground + [ShellChrome.well(scheme)], scheme)
                #expect(tag >= 4.5, "a tag is \(tag):1 on its pill on \(named) in \(scheme)")
            }
        }
    }

    // MARK: - How each is drawn

    @Test("A tag that opens something is the grey, a step heavier, marked for a pill and for a line only under a pointer")
    func aTagIsQuietAndHeavier() throws {
        let ink = ShellChrome.inkFaint(.light)
        let url = try #require(ShellTags.url(for: Self.swift))
        var letters = AttributedString(EmojiText.tagRoom + "#Swift" + EmojiText.tagRoom)
        letters.link = url
        letters.foregroundColor = ink
        let unruled = PostPressMark(target: url, ink: ink, ruled: false)
        let drawn = EmojiText.drawn(Self.swift, ink: ink)
        #expect(drawn == Text(letters).fontWeight(.medium).customAttribute(PostTagMark()).customAttribute(unruled))
        #expect(drawn != Text(letters).customAttribute(PostTagMark()).customAttribute(unruled), "a step heavier")
        #expect(drawn != Text(letters).fontWeight(.medium).customAttribute(PostTagMark())
            .customAttribute(PostPressMark(target: url, ink: ink, ruled: true)), "no line at rest")
    }

    /// The marks a laid-out line hands the renderer, recorded by a renderer that draws the line
    /// and nothing of its own: the address ruled, the tag and the name not.
    @Test("Laid out, the address, the tag and the name each carry a press mark, and only the address is ruled")
    func theMarksReachTheRenderer() throws {
        let seen = Seen()
        let inks = EmojiText.inks(.light, tags: true, names: true)
        let cut = EmojiRun.prose(in: "hi @ada see https://example.test/a #Swift", emojis: [],
                                 mentions: [Self.ada.handle])
        let line = EmojiText.line(cut, [:], at: 0, baseline: -4,
                                  linkInk: inks.link, tagInk: inks.tag, nameInk: inks.name)
        let renderer = ImageRenderer(content: line.font(EmojiTextRole.body.font(at: .large))
            .textRenderer(Recorder(seen: seen)).frame(width: 720, alignment: .leading))
        _ = renderer.cgImage
        let marks = seen.marks.withLock { $0 }
        var byTarget: [URL: Bool] = [:]
        for mark in marks { byTarget[mark.target] = mark.ruled }
        #expect(byTarget[URL(string: "https://example.test/a")!] == true)
        #expect(byTarget[try #require(ShellTags.url(for: Self.swift))] == false)
        #expect(byTarget[try #require(ShellMentions.url(for: Self.ada.handle))] == false)
        #expect(byTarget.count == 3)
    }

    // MARK: - The renderer is there

    @Test("A line with only an address in it is painted; plain words are not")
    func aLinkAloneIsPainted() {
        let linked = EmojiRun.prose(in: "see https://example.test/a", emojis: [])
        #expect(EmojiText.paints(linked, links: EmojiText.links(in: linked), named: []))
        let plain = EmojiRun.prose(in: "just words", emojis: [])
        #expect(!EmojiText.paints(plain, links: EmojiText.links(in: plain), named: []))
        // A name is painted only where a press on it opens something.
        let naming = EmojiRun.prose(in: "hi @ada", emojis: [], mentions: [Self.ada.handle])
        #expect(!EmojiText.paints(naming, links: [], named: []))
        #expect(EmojiText.paints(naming, links: [], named: EmojiText.mentions(in: naming)))
    }

    /// The renderer itself, drawn on a line with an address and nothing else, beside the same
    /// line drawn by a renderer that draws only the letters: what differs is the underline, and
    /// it lies under the letters' middle.
    @Test("Drawn, a line with only an address in it carries its underline")
    func aLinkAloneDrawsItsRule() throws {
        let link = PostLink("https://example.test/a")!
        let line = EmojiText.line(EmojiRun.prose(in: "https://example.test/a", emojis: []), [:], at: 0,
                                  baseline: -4, linkInk: Color(red: 1, green: 0, blue: 0))
        #expect(EmojiText.links(in: EmojiRun.prose(in: "https://example.test/a", emojis: [])) == [link])
        let ruled = try Self.pixels(line, ProseInks(plate: .clear))
        let bare = try Self.pixels(line, LettersOnly())
        #expect(ruled.width == bare.width && ruled.height == bare.height)
        var differing: [Int] = []
        for y in 0..<ruled.height {
            for x in 0..<ruled.width {
                let i = (y * ruled.width + x) * 4
                if ruled.bytes[i..<i + 4] != bare.bytes[i..<i + 4] { differing.append(y) }
            }
        }
        #expect(differing.count > 40, "the underline is drawn: \(differing.count) pixels differ")
        let middle = ruled.height / 2
        #expect(differing.allSatisfy { $0 > middle }, "the underline is under the letters")
    }

    // MARK: - The underlines

    private static let link = URL(string: "https://example.test/a")!
    private static let tag = URL(string: "https://example.test/tags/swift")!

    @Test("At rest an address is underlined faint in its own blue, and a tag not at all")
    func atRest() {
        let blue = ShellChrome.link(.light), grey = ShellChrome.inkFaint(.light)
        let runs: [(mark: PostPressMark?, bounds: CGRect)] = [
            (nil, CGRect(x: 0, y: 0, width: 30, height: 20)),
            (PostPressMark(target: Self.link, ink: blue, ruled: true), CGRect(x: 30, y: 0, width: 50, height: 20)),
            (nil, CGRect(x: 80, y: 0, width: 10, height: 20)),
            (PostPressMark(target: Self.tag, ink: grey, ruled: false), CGRect(x: 90, y: 0, width: 40, height: 20)),
        ]
        let rules = ProseInks.rules(runs, pressed: nil)
        #expect(rules.count == 1)
        #expect(rules.first?.ink == blue.opacity(ShellChrome.linkRuleAtRest))
        #expect(rules.first?.rect.minX == 30 && rules.first?.rect.width == 50)
        // Under the letters, inside the line's own height.
        let rule = rules.first!.rect
        #expect(rule.minY > 14 && rule.maxY <= 20)
    }

    @Test("Under a pointer the line is solid: an address's turns full, a tag gains one")
    func underAPointer() {
        let blue = ShellChrome.link(.dark), grey = ShellChrome.inkFaint(.dark)
        let runs: [(mark: PostPressMark?, bounds: CGRect)] = [
            (PostPressMark(target: Self.link, ink: blue, ruled: true), CGRect(x: 0, y: 0, width: 50, height: 20)),
            (nil, CGRect(x: 50, y: 0, width: 10, height: 20)),
            (PostPressMark(target: Self.tag, ink: grey, ruled: false), CGRect(x: 60, y: 0, width: 40, height: 20)),
        ]
        #expect(ProseInks.target(at: CGPoint(x: 70, y: 10), among: runs) == Self.tag)
        #expect(ProseInks.target(at: CGPoint(x: 55, y: 10), among: runs) == nil)
        let onTag = ProseInks.rules(runs, pressed: Self.tag)
        #expect(onTag.map(\.ink) == [blue.opacity(ShellChrome.linkRuleAtRest), grey])
        let onLink = ProseInks.rules(runs, pressed: Self.link)
        #expect(onLink.map(\.ink) == [blue])
    }

    /// One press set in two faces is two runs; it is one line under the pointer, not two.
    @Test("The runs of one press are one line")
    func oneLinePerPress() {
        let blue = ShellChrome.link(.light)
        let mark = PostPressMark(target: Self.link, ink: blue, ruled: true)
        let runs: [(mark: PostPressMark?, bounds: CGRect)] = [
            (mark, CGRect(x: 0, y: 2, width: 20, height: 18)),
            (mark, CGRect(x: 20, y: 0, width: 30, height: 20)),
        ]
        let rules = ProseInks.rules(runs, pressed: nil)
        #expect(rules.count == 1)
        #expect(rules.first?.rect.minX == 0 && rules.first?.rect.maxX == 50)
    }

    // MARK: - Measuring

    private struct LettersOnly: TextRenderer {
        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            for line in layout { context.draw(line) }
        }
    }

    /// The line drawn at 40 points by `renderer`, as rows of RGBA bytes, top row first.
    private static func pixels(_ line: Text, _ renderer: some TextRenderer) throws
        -> (bytes: [UInt8], width: Int, height: Int) {
        let image = ImageRenderer(content: line.font(.system(size: 40)).textRenderer(renderer).padding(20))
        image.scale = 1
        let drawn = try #require(image.cgImage)
        let width = drawn.width, height = drawn.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }

    private final class Seen: Sendable {
        let marks = Mutex<[PostPressMark]>([])
    }

    private struct Recorder: TextRenderer {
        let seen: Seen

        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            var marks: [PostPressMark] = []
            for line in layout {
                marks += line.compactMap { $0[PostPressMark.self] }
                context.draw(line)
            }
            seen.marks.withLock { $0 = marks }
        }
    }

    /// The colour's hue on the wheel, in degrees.
    private static func hue(_ colour: Color, _ scheme: ColorScheme) -> Double {
        let drawn = ShellContrast.resolved(colour, scheme)
        let (r, g, b) = (Double(drawn.red), Double(drawn.green), Double(drawn.blue))
        let top = max(r, g, b), bottom = min(r, g, b), span = top - bottom
        guard span > 0 else { return 0 }
        let degrees: Double
        switch top {
        case r: degrees = 60 * ((g - b) / span).truncatingRemainder(dividingBy: 6)
        case g: degrees = 60 * ((b - r) / span + 2)
        default: degrees = 60 * ((r - g) / span + 4)
        }
        return degrees < 0 ? degrees + 360 : degrees
    }
}
