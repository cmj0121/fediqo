import Foundation
import Testing
@testable import FediqoCore

@Suite("Written in pictures")
struct EmojiRunTests {
    /// A picture named after its shortcode. Percent-encoded, because a shortcode under test may
    /// hold a space or a newline and the address only has to be unique, not pretty.
    private static func emoji(_ shortcode: String) -> CustomEmoji {
        let slug = shortcode.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "x"
        return CustomEmoji(
            shortcode: shortcode,
            url: URL(string: "https://first.example/\(slug).png")!,
            staticURL: URL(string: "https://first.example/\(slug)-still.png")
        )
    }

    private let blobcat = emoji("blobcat")
    private let a = emoji("a")
    private let b = emoji("b")
    private let cjk = emoji("cjk")

    private var all: [CustomEmoji] { [blobcat, a, b, cjk] }

    @Test("A shortcode with a picture becomes a picture; the words either side stay words")
    func oneShortcodeInTheMiddle() {
        #expect(CustomEmoji.runs(in: "hi :blobcat: there", from: all) == [
            .text("hi "), .emoji(blobcat), .text(" there"),
        ])
    }

    @Test("A shortcode at the very start and at the very end")
    func atBothEnds() {
        #expect(CustomEmoji.runs(in: ":blobcat: hi", from: all) == [.emoji(blobcat), .text(" hi")])
        #expect(CustomEmoji.runs(in: "hi :blobcat:", from: all) == [.text("hi "), .emoji(blobcat)])
        #expect(CustomEmoji.runs(in: ":blobcat:", from: all) == [.emoji(blobcat)])
    }

    @Test("Adjacent shortcodes are two pictures and no text between them")
    func adjacentShortcodes() {
        #expect(CustomEmoji.runs(in: ":a::b:", from: all) == [.emoji(a), .emoji(b)])
        #expect(CustomEmoji.runs(in: ":a::b::a:", from: all) == [.emoji(a), .emoji(b), .emoji(a)])

        // A list nobody folded: the first spelling wins here too, not the last.
        let other = CustomEmoji(shortcode: "a", url: URL(string: "https://elsewhere/a.png")!)
        #expect(CustomEmoji.runs(in: ":a::b:", from: [a, other, b]) == [.emoji(a), .emoji(b)])
        #expect(CustomEmoji.runs(in: ":a:", from: [other, a]) == [.emoji(other)])
    }

    @Test("A name is whatever the server registered, hyphens and all")
    func theServerNamesIt() {
        let hyphen = Self.emoji("blob-cat")
        let rainbow = Self.emoji("ablobcat-rainbow")
        let dotted = Self.emoji("party.parrot")
        let plussed = Self.emoji("c++")
        let pictures = [hyphen, rainbow, dotted, plussed]

        #expect(CustomEmoji.runs(in: "hi :blob-cat:", from: pictures) == [
            .text("hi "), .emoji(hyphen),
        ])
        #expect(CustomEmoji.runs(in: ":ablobcat-rainbow::blob-cat:", from: pictures) == [
            .emoji(rainbow), .emoji(hyphen),
        ])
        #expect(CustomEmoji.runs(in: ":party.parrot: :c++:", from: pictures) == [
            .emoji(dotted), .text(" "), .emoji(plussed),
        ])
    }

    @Test("A name stops at a space, at a newline, and at a sane length")
    func theScanIsBounded() {
        // The dictionary would answer for these, and the scan never asks it: a name that spans
        // words or lines is not a name, and one this long is not a shortcode.
        let spaced = Self.emoji("two words")
        let lined = Self.emoji("two\nlines")
        let long = Self.emoji(String(repeating: "x", count: 65))
        let allowed = Self.emoji(String(repeating: "y", count: 64))

        #expect(CustomEmoji.runs(in: ":two words:", from: [spaced]) == [.text(":two words:")])
        #expect(CustomEmoji.runs(in: ":two\nlines:", from: [lined]) == [.text(":two\nlines:")])
        #expect(CustomEmoji.runs(in: ":\(long.shortcode):", from: [long]) == [
            .text(":\(long.shortcode):"),
        ])
        #expect(CustomEmoji.runs(in: ":\(allowed.shortcode):", from: [allowed]) == [.emoji(allowed)])
    }

    @Test("A trailing lone colon is a colon")
    func trailingColon() {
        #expect(CustomEmoji.runs(in: "hi :blobcat::", from: all) == [
            .text("hi "), .emoji(blobcat), .text(":"),
        ])
        #expect(CustomEmoji.runs(in: "wait:", from: all) == [.text("wait:")])
        #expect(CustomEmoji.runs(in: ":", from: all) == [.text(":")])
    }

    @Test("A hand-typed smiley is left exactly as it was typed")
    func handTypedSmiley() {
        #expect(CustomEmoji.runs(in: ":-) and :) too", from: all) == [.text(":-) and :) too")])
        #expect(CustomEmoji.runs(in: "a :: b", from: all) == [.text("a :: b")])
    }

    @Test("A shortcode nobody sent a picture for stays as it was written")
    func unknownShortcode() {
        #expect(CustomEmoji.runs(in: "hi :nobody: there", from: all) == [.text("hi :nobody: there")])
        #expect(CustomEmoji.runs(in: ":nobody::blobcat:", from: all) == [
            .text(":nobody:"), .emoji(blobcat),
        ])
    }

    @Test("A colon in an address opens nothing")
    func addressInTheWords() {
        #expect(CustomEmoji.runs(in: "see http://host/a", from: all) == [.text("see http://host/a")])
        #expect(CustomEmoji.runs(in: "http://host :blobcat:", from: all) == [
            .text("http://host "), .emoji(blobcat),
        ])
    }

    @Test("CJK pressed against a shortcode is not part of its name")
    func cjkAgainstAShortcode() {
        #expect(CustomEmoji.runs(in: "你好:cjk:世界", from: all) == [
            .text("你好"), .emoji(cjk), .text("世界"),
        ])
        #expect(CustomEmoji.runs(in: ":你好:", from: all) == [.text(":你好:")])
    }

    @Test("No pictures, or no colon, is one run and no scan")
    func fastPath() {
        #expect(CustomEmoji.runs(in: "hi :blobcat: there", from: []) == [.text("hi :blobcat: there")])
        #expect(CustomEmoji.runs(in: "plain words", from: all) == [.text("plain words")])
        #expect(CustomEmoji.runs(in: "", from: all) == [])
        #expect(CustomEmoji.runs(in: "", from: []) == [])
    }

    @Test("One shortcode, one picture, first spelling wins")
    func foldingKeepsTheFirst() {
        let second = CustomEmoji(shortcode: "blobcat", url: URL(string: "https://elsewhere/b.png")!)
        let nameless = CustomEmoji(shortcode: "", url: URL(string: "https://first.example/x.png")!)
        let folded = CustomEmoji.folded([blobcat, second, nameless, a, blobcat])
        #expect(folded == [blobcat, a])
        #expect(CustomEmoji.folded([]).isEmpty)
    }

    @Test("A picture carries its still, and nothing where the server sent none")
    func stillIsCarried() {
        #expect(blobcat.staticURL == URL(string: "https://first.example/blobcat-still.png"))
        #expect(CustomEmoji(shortcode: "x", url: URL(string: "https://host/x.png")!).staticURL == nil)
    }
}
