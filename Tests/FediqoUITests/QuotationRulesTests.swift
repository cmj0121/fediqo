import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import FediqoCore
@testable import FediqoPersistence
@testable import FediqoUI

/// A quotation inside another has one rule per level, and whoever spoke first reads first — #160.
///
/// The structure is asked of `ForumQuotation.drawn(_:)`, which is the whole of the decision about
/// wrappers; the rules and their order are asked of the view itself, drawn once through
/// `ImageRenderer` and read back as columns of paint. Words there are blank lines, so the only
/// paint on the image is the rules: a line's height without a glyph to mistake for one.
@MainActor
@Suite("Nested quotations: one rule per level, the quoted first", .serialized)
struct QuotationRulesTests {
    typealias Q = DiscuzQuotation

    // MARK: - Structure

    @Test("A wrapper is replaced, in its place, by what it wraps; siblings stay two")
    func wrappersCollapse() {
        let chain = Q(words: "a", quoting: [Q(words: "b", quoting: [Q(words: "c")])])
        // No wrapper: nothing changes.
        #expect(ForumQuotation.drawn([chain]) == [chain])
        // A wrapper at the top, and one between every level: the same three levels.
        #expect(ForumQuotation.drawn([Q(words: "", quoting: [chain])]) == [chain])
        let wrappedEverywhere = Q(words: "", quoting: [
            Q(words: "a", quoting: [Q(words: "", quoting: [
                Q(words: "b", quoting: [Q(words: "", quoting: [Q(words: "c")])]),
            ])]),
        ])
        #expect(ForumQuotation.drawn([wrappedEverywhere]) == [chain])
        // Two side by side stay two — and so do two inside one wrapper, where the wrapper was.
        let two = [Q(words: "x"), Q(words: "y")]
        #expect(ForumQuotation.drawn(two) == two)
        #expect(ForumQuotation.drawn([Q(words: "", quoting: two)]) == two)
        #expect(ForumQuotation.drawn([Q(words: "a", quoting: [Q(words: "", quoting: two)])])
            == [Q(words: "a", quoting: two)])
        // A wrapper around nothing is nothing.
        #expect(ForumQuotation.drawn([Q(words: "")]).isEmpty)
    }

    // MARK: - Drawn

    /// One rule on the image: its column, and each stretch of it that is painted.
    struct Rule: Equatable {
        let x: Int
        let runs: [ClosedRange<Int>]
    }

    /// Three blank lines: a level's height with no glyph in it.
    static let blank = " \n \n "

    static func bitmap(_ quotations: [Q]) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let content = VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ForEach(quotations.indices, id: \.self) { index in
                ForumQuotation(quotation: quotations[index])
            }
        }
        .frame(width: 240, alignment: .topLeading)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }

    /// Every column holding a stretch of paint taller than a line of text, top to bottom.
    /// Rows are counted from the top of the image.
    static func rules(_ quotations: [Q]) throws -> [Rule] {
        let (pixels, width, height) = try bitmap(quotations)
        func painted(_ x: Int, _ y: Int) -> Bool { pixels[(y * width + x) * 4 + 3] > 8 }
        var found: [Rule] = []
        for x in 0 ..< min(width, 64) {
            var runs: [ClosedRange<Int>] = []
            var start: Int?
            for y in 0 ... height {
                let on = y < height && painted(x, y)
                if on, start == nil { start = y }
                if !on, let top = start {
                    runs.append(top ... y - 1)
                    start = nil
                }
            }
            let tall = runs.filter { $0.count >= 20 }
            if !tall.isEmpty { found.append(Rule(x: x, runs: tall)) }
        }
        return found
    }

    @Test("Three levels with words are three rules stepping right, the quoted above the words")
    func threeLevelsThreeRules() throws {
        let chain = Q(words: Self.blank, quoting: [Q(words: Self.blank, quoting: [Q(words: Self.blank)])])
        let rules = try Self.rules([chain])
        #expect(rules.map(\.x) == [0, 8, 16], "one rule per level, a step of `snug` apart")
        #expect(rules.allSatisfy { $0.runs.count == 1 })
        let spans = rules.compactMap(\.runs.first)
        // Each level's rule starts where its quotation starts, at the top, because what it
        // quoted is above its words; and the deeper one ends first, above the words it
        // answers. With the words first, the deeper rules would end at the bottom instead.
        #expect(Set(spans.map(\.lowerBound)).count == 1)
        #expect(spans[0].upperBound > spans[1].upperBound)
        #expect(spans[1].upperBound > spans[2].upperBound)
    }

    @Test("A wrapper draws no rule of its own: wrapped, the same three rules")
    func aWrapperDrawsNoRule() throws {
        let chain = Q(words: Self.blank, quoting: [Q(words: Self.blank, quoting: [Q(words: Self.blank)])])
        let bare = try Self.rules([chain])
        let wrapped = Q(words: "", quoting: [
            Q(words: Self.blank, quoting: [Q(words: "", quoting: [
                Q(words: Self.blank, quoting: [Q(words: Self.blank)]),
            ])]),
        ])
        #expect(try Self.rules([wrapped]) == bare)
        #expect(try Self.rules([Q(words: "", quoting: [chain])]) == bare)
    }

    @Test("Two quotations side by side in one level stay two rules, one above the other")
    func siblingsStayTwo() throws {
        let level = Q(words: Self.blank, quoting: [Q(words: Self.blank), Q(words: Self.blank)])
        let rules = try Self.rules([level])
        #expect(rules.map(\.x) == [0, 8])
        #expect(rules.first?.runs.count == 1)
        #expect(rules.last?.runs.count == 2, "two quotations, two rules, not one run through both")
        // And the same inside a wrapper, where the wrapper was.
        #expect(try Self.rules([Q(words: Self.blank, quoting: [Q(words: "", quoting: level.quoting)])])
            == rules)
    }

    // MARK: - Kept

    @Test("A quotation read back from what this device kept draws as the one read from the page")
    func keptDrawsAsRead() async throws {
        // A template that wraps each quotation in another with nothing of its own, which is what
        // drew one border twice.
        let html = #"""
        <div class="plc" id="pid900601">
          <ul class="authi"><li>6<sup>#</sup></li><li><a href="home.php?mod=space&amp;uid=56">己</a></li></ul>
          <div class="message">
            <div class="quote"><blockquote><div class="quote"><blockquote>沙洲电子 发表于 2017-12-15 17:49<br />
              <div class="quote"><blockquote><div class="quote"><blockquote>hexi 发表于 2017-12-15 17:00<br />
              论坛运维都要花钱</blockquote></div></blockquote></div>
              这个确实该支持一下</blockquote></div></blockquote></div>
            那就每人出十块
          </div>
        </div>
        """#
        let post = try #require(DiscuzThreadPage.posts(in: html, tid: 700500, host: "install-c.example").first)
        #expect(post.quoted.first?.words == "", "the page's wrapper is still read as one")

        let forum = Source(host: "install-c.example", kind: .discuz)
        let note = Note(
            id: "discuz:install-c.example:700500", source: forum, author: "己", handle: "@己@install-c.example",
            body: "", title: "运维", postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: [.board(id: "7")], opening: ForumOpening(words: post.body, quoted: post.quoted)
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await StoreFile(at: dir).save(sources: [forum], notes: [note])
        let kept = try #require(StoreFile.open(at: dir).notes.first?.opening?.quoted)

        let drawn = ForumQuotation.drawn(kept)
        #expect(drawn == ForumQuotation.drawn(post.quoted))
        #expect(drawn.count == 1 && drawn[0].quoting.count == 1 && drawn[0].quoting[0].quoting.isEmpty,
                "two people, two levels, and no wrapper left")
        #expect(drawn[0].words.hasPrefix("沙洲电子") && drawn[0].quoting[0].words.hasPrefix("hexi"))
        let read = try Self.bitmap(post.quoted), back = try Self.bitmap(kept)
        #expect(read.width == back.width && read.height == back.height && read.pixels == back.pixels)
    }
}
