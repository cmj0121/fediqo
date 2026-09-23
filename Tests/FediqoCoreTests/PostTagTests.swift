import Foundation
import Testing
@testable import FediqoCore

/// What a hashtag is in a post's words, and where the prose cut puts one (#123).
///
/// Everything here is the rule and the cut; how a tag is drawn and read aloud is `HashtagTests`
/// on the UI side.
@Suite("A hashtag in a post's words")
struct PostTagTests {
    private static func tags(_ text: String) -> [String] { PostTag.found(in: text).map(\.text) }

    // MARK: - What a tag is

    @Test("A tag is `#` and a word, where the `#` does not sit inside a word")
    func whatATagIs() {
        #expect(Self.tags("#swift") == ["#swift"])
        #expect(Self.tags("a #swift b") == ["#swift"])
        #expect(Self.tags("(#swift)") == ["#swift"])
        #expect(Self.tags("#snake_case #_x #2024") == ["#snake_case", "#_x", "#2024"])
        // Not a tag: inside a word, a bare `#`, and a `#` with nothing after it.
        #expect(Self.tags("c#not") == [])
        #expect(Self.tags("# alone") == [])
        #expect(Self.tags("the end #") == [])
        // The second `#` of `##y` is an opener, since what is before it is not a letter.
        #expect(Self.tags("##y") == ["#y"])
    }

    @Test("A tag ends where its word ends: at a space, at punctuation, at the end of the line")
    func whereATagEnds() {
        #expect(Self.tags("#swift, and #swiftui.") == ["#swift", "#swiftui"])
        #expect(Self.tags("#one\n#two") == ["#one", "#two"])
        #expect(Self.tags("#a-b") == ["#a"])
    }

    /// The acceptance line about non-ASCII: a tag in Chinese or Japanese is a tag exactly as one
    /// in ASCII is. What is before the `#` is judged in the same alphabet, so `看#台灣` with no
    /// space is a word and not a tag — see `PostTag.spans` for why that is not `PostLink`'s rule.
    @Test("A tag written in letters that are not ASCII is a tag the same way")
    func notASCII() {
        #expect(Self.tags("#台灣 #日本語 #한국어 #café") == ["#台灣", "#日本語", "#한국어", "#café"])
        #expect(Self.tags("請看 #台灣。") == ["#台灣"])
        #expect(Self.tags("（#台灣）") == ["#台灣"])
        #expect(Self.tags("「#東京」に行った") == ["#東京"])
        // A tag's letters run on through CJK, so what ends one is what ends a word.
        #expect(Self.tags("#台灣 真好") == ["#台灣"])
        // Inside a word, in any script.
        #expect(Self.tags("看#台灣") == [])
    }

    @Test("A tag is only ever built out of letters that are one")
    func theInitialiserHoldsTheRule() {
        #expect(PostTag("#swift")?.name == "swift")
        #expect(PostTag("#台灣")?.name == "台灣")
        #expect(PostTag("swift") == nil)
        #expect(PostTag("#") == nil)
        #expect(PostTag("#a b") == nil)
        #expect(PostTag("#a.b") == nil)
    }

    @Test("A post draws no more tags than the bound, and the rest stay as letters")
    func theScanIsBounded() {
        let many = (0 ..< 200).map { "#t\($0)" }.joined(separator: " ")
        let found = PostTag.found(in: many)
        #expect(found.count == PostTag.maxTags)
        #expect(found.first?.text == "#t0")
        #expect(found.last?.text == "#t\(PostTag.maxTags - 1)")
    }

    /// One rule for what is drawn and what is searched, so a post cannot be found by a tag its
    /// row draws as ordinary words.
    @Test("Search reads exactly the tags the row draws")
    func searchReadsTheSameRule() {
        for text in ["a #swift b (#SwiftUI) c#not #_x ##y #", "#台灣 #日本語", "看#台灣",
                     (0 ..< 50).map { "#t\($0)" }.joined(separator: " ")] {
            #expect(SearchIndex.Entry.hashtags(in: text) == Self.tags(text))
        }
    }

    // MARK: - Where the prose cut puts it

    @Test("A tag at the start, in the middle and at the end of a line is its own run")
    func theCut() throws {
        let swift = try #require(PostTag("#swift"))
        #expect(EmojiRun.prose(in: "#swift first", emojis: []) == [.tag(swift), .text(" first")])
        #expect(EmojiRun.prose(in: "see #swift now", emojis: [])
            == [.text("see "), .tag(swift), .text(" now")])
        #expect(EmojiRun.prose(in: "last #swift", emojis: []) == [.text("last "), .tag(swift)])
    }

    @Test("A line with no tag is cut exactly as it was before")
    func noTagNoChange() {
        let blobcat = CustomEmoji(shortcode: "blobcat", url: URL(string: "https://e.test/b.png")!)
        for text in ["just words", "c#not a tag", "a # b", "12:30 :blobcat: here", ""] {
            #expect(EmojiRun.prose(in: text, emojis: [blobcat])
                == CustomEmoji.runs(in: text, from: [blobcat]))
        }
    }

    /// A `#` is legal in an address, and an address keeps every character it was written with.
    @Test("A `#` inside an address is part of the address, not a tag")
    func anAddressKeepsItsFragment() throws {
        let cut = EmojiRun.prose(in: "see https://example.test/#top and #swift", emojis: [])
        let link = try #require(PostLink("https://example.test/#top"))
        let swift = try #require(PostTag("#swift"))
        #expect(cut == [.text("see "), .link(link), .text(" and "), .tag(swift)])
    }

    @Test("Addresses, tags and pictures come out in the order they were written")
    func mixedOrder() throws {
        let blobcat = CustomEmoji(shortcode: "blobcat", url: URL(string: "https://e.test/b.png")!)
        let one = try #require(PostTag("#one"))
        let two = try #require(PostTag("#二"))
        let link = try #require(PostLink("https://example.test/a"))
        let cut = EmojiRun.prose(in: "#one :blobcat: https://example.test/a #二", emojis: [blobcat])
        #expect(cut == [.tag(one), .text(" "), .emoji(blobcat), .text(" "), .link(link), .text(" "),
                        .tag(two)])
    }

    /// `EmojiText` reads a line aloud from its cut; that is only honest if the cut is the words.
    @Test("The cut, put back together, is the words exactly")
    func theCutIsTheWords() {
        let blobcat = CustomEmoji(shortcode: "blobcat", url: URL(string: "https://e.test/b.png")!)
        let text = "#a (#b) :blobcat: https://x.test/#c, 請看 #台灣。##d #"
        let rebuilt = EmojiRun.prose(in: text, emojis: [blobcat]).map { run -> String in
            switch run {
            case .text(let words): words
            case .link(let link): link.text
            case .emoji(let emoji): ":\(emoji.shortcode):"
            case .tag(let tag): tag.text
            }
        }.joined()
        #expect(rebuilt == text)
    }

    /// The label cut is how a name, a handle and a covered post are drawn, and none of those is
    /// somewhere a pill belongs.
    @Test("A label's cut grows no tag")
    func aLabelGrowsNoTag() {
        let cut = CustomEmoji.runs(in: "#1 fan of #swift", from: [])
        #expect(cut == [.text("#1 fan of #swift")])
    }

    // MARK: - A tag is one path segment (#124)

    /// A prepend letter joins the scalar after it into one grapheme, so judging a character by its
    /// first scalar let a `/` into a name that is sent to a server as a path segment.
    @Test("A character is a tag's only where every scalar in it is: no slash rides in on a letter")
    func everyScalarIsJudged() {
        #expect(PostTag("#\u{0D4E}/x") == nil)
        #expect(PostTag("#a\u{0D4E}/b") == nil)
        for text in ["#\u{0D4E}/x", "look #\u{0D4E}/../../accounts", "#a\u{0D4E}?x=1", "#x\u{0D4E}#y"] {
            for tag in PostTag.found(in: text) {
                #expect(!tag.name.contains { "/?#%".contains($0) }, "\(tag.text) from \(text)")
            }
        }
        // What stays a tag: letters with their marks, any script, digits, `_`, an emoji-style join.
        #expect(PostTag("#café") != nil)
        #expect(PostTag("#e\u{0301}t\u{00E9}") != nil)
        #expect(PostTag("#台灣") != nil)
        #expect(PostTag("#ക്ഷ") != nil)
        #expect(PostTag("#a\u{200D}b") != nil)
    }

    @Test("A tag's timeline is the name as one segment, and nothing else")
    func oneSegment() throws {
        for text in ["#swift", "#台灣", "#café", "#snake_case", "#2024"] {
            let tag = try #require(PostTag(text))
            let path = try MastodonTag.path(under: tag, host: "one.example")
            #expect(path == "/api/v1/timelines/tag/" + tag.name)
            let url = try #require(Host.httpsURL(host: "one.example", path: path))
            #expect(url.pathComponents.count == 6)
            #expect(url.lastPathComponent == tag.name)
        }
    }
}
