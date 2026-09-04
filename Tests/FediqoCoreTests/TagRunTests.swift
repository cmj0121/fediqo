import Foundation
import Testing
@testable import FediqoCore

/// A hashtag in somebody's words, cut out so it can be pressed (#107).
///
/// The cut is here rather than on the screen for the reason the addresses' is: it is the part
/// worth testing, and it is testable without a screen.
@Suite("A tag in the words")
struct TagRunTests {
    private func tags(_ text: String) -> [String] {
        TextLinks.runs(in: text).compactMap { if case .tag(_, let name) = $0 { name } else { nil } }
    }

    private func labels(_ text: String) -> [String] {
        TextLinks.runs(in: text).compactMap { if case .tag(let label, _) = $0 { label } else { nil } }
    }

    @Test("A hashtag is cut out of the words around it, and keeps them")
    func onetag() {
        #expect(TextLinks.runs(in: "about #libraries today")
                == [.text("about "), .tag("#libraries", "libraries"), .text(" today")])
    }

    /// The label stays what the author typed and the name is normalised, so opening a tag never
    /// rewrites somebody's sentence — and `#Swift` in the words is the same press as `swift` in
    /// `post_tags`.
    @Test("What was typed is kept, and what is asked for is normalised")
    func labelAndName() {
        #expect(labels("read #Swift now") == ["#Swift"])
        #expect(tags("read #Swift now") == ["swift"])
    }

    /// `＃` is U+FF03 and is what a Japanese or Chinese keyboard types without leaving the input
    /// mode the rest of the sentence is in.
    @Test("Both hashes are hashes")
    func bothHashes() {
        #expect(tags("＃swift and #swift") == ["swift", "swift"])
    }

    /// **The one that would have been a bug in every link.** An address can end in something
    /// shaped exactly like a hashtag, and it is part of the address.
    @Test("A fragment in an address is not a tag")
    func afragmentIsNotATag() {
        #expect(tags("see https://example.org/page#section") == [])
        #expect(TextLinks.runs(in: "see https://example.org/page#section").count == 2)
    }

    /// A hash has to follow a break, or a language and a note in the margin become tags.
    @Test("A hash in the middle of a word is part of the word")
    func ahashMidWord() {
        #expect(tags("written in C# mostly") == [])
        #expect(tags("a#b") == [])
    }

    @Test("A hash with nothing after it is a hash")
    func abareHash() {
        #expect(tags("# ") == [])
        #expect(tags("#") == [])
        #expect(tags("#!") == [])
    }

    @Test("Punctuation ends a tag, and stays in the sentence")
    func punctuationEndsIt() {
        #expect(TextLinks.runs(in: "about #libraries, mostly")
                == [.text("about "), .tag("#libraries", "libraries"), .text(", mostly")])
    }

    @Test("An underscore and a number are part of a tag")
    func whatMayBeInOne() {
        #expect(tags("#slow_web2") == ["slow_web2"])
    }

    @Test("A line with no hash is one run, untouched")
    func nohash() {
        #expect(TextLinks.runs(in: "nothing to see") == [.text("nothing to see")])
    }

    @Test("Several in one line, each its own")
    func several() {
        #expect(tags("#libraries and #slowweb") == ["libraries", "slowweb"])
    }

    // MARK: - how it reaches the app

    /// A pressable run inside prose has to be spelled as an address, because that is the one
    /// thing SwiftUI will put inside a line and still let the line behave like one.
    @Test("A tag goes to the app as an address, and comes back as a tag")
    func theaddressRoundTrips() throws {
        let url = try #require(TagLink.url(for: "libraries"))
        #expect(url.scheme == TagLink.scheme)
        #expect(TagLink.tag(in: url) == "libraries")
    }

    /// And the shell hands everything else straight on: a scheme this app does not own is not
    /// this app's to keep.
    @Test("Somebody else's address is not a tag")
    func somebodyElsesAddress() throws {
        #expect(TagLink.tag(in: try #require(URL(string: "https://example.org/x"))) == nil)
        #expect(TagLink.tag(in: try #require(URL(string: "mailto:a@example.org"))) == nil)
    }

    /// A tag with characters an address cannot carry still makes the round trip: it is escaped
    /// going out and read back as the name the store keeps.
    @Test("A tag that is not Latin survives the trip")
    func notLatin() throws {
        let url = try #require(TagLink.url(for: "圖書館"))
        #expect(TagLink.tag(in: url) == "圖書館")
    }
}
