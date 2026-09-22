import Foundation

/// One picture a post is partly written in, and the shortcode it is spelled by.
///
/// The shortcode arrives without its colons and is kept that way: `:blobcat:` in the words is
/// `blobcat` here, because the colons are punctuation a server put round a name rather than a
/// part of the name.
public struct CustomEmoji: Sendable, Hashable {
    public let shortcode: String
    public let url: URL
    /// The still of an animated one, where the server offered it. Nothing is not "it does not
    /// move" — it is a server that did not say.
    public let staticURL: URL?

    public init(shortcode: String, url: URL, staticURL: URL? = nil) {
        self.shortcode = shortcode
        self.url = url
        self.staticURL = staticURL
    }

    /// One shortcode, one picture, first spelling wins. Two lists arrive for every post — the
    /// status's and its author's — and a server saying `blobcat` twice is saying it once. A
    /// picture with no shortcode goes: nothing in the words can ever spell it.
    static func folded(_ raw: [CustomEmoji]) -> [CustomEmoji] {
        var seen: Set<String> = []
        return raw.filter { !$0.shortcode.isEmpty && seen.insert($0.shortcode).inserted }
    }
}

/// A line of text, cut into what is written in letters, what is written in pictures, and — where
/// the line is a post's own words — what is written as an address or as a hashtag.
///
/// The cut is made here rather than on the screen so that it can be tested without one, and so
/// that the places drawing somebody's words cannot come to disagree about what a shortcode is.
///
/// **A `.link` and a `.tag` are only ever produced by `EmojiRun.prose`**, which is the cut a call
/// site has to ask for by name. `CustomEmoji.runs` cannot make either, so a label — a name, a
/// handle, a spoiler line — cannot grow a control by accident, nor a person who calls themselves
/// `#1 fan` a pill round their name.
public enum EmojiRun: Sendable, Hashable {
    case text(String)
    case emoji(CustomEmoji)
    case link(PostLink)
    /// A word the author marked as a tag. A label and not a control: there is nothing for a
    /// press to open, and the drawing says so.
    case tag(PostTag)
}

public extension CustomEmoji {
    /// Cuts `text` into runs, replacing only the shortcodes this post was actually given a
    /// picture for.
    ///
    /// A shortcode is `:name:`, and **the name is whatever the server registered**. Mastodon
    /// spells one in letters, digits and underscores, but Pleroma and Akkoma register hyphens
    /// as a matter of course — `:blob-cat:`, `:ablobcat-rainbow:` — and those arrive on a
    /// Mastodon timeline the moment a post federates in, which is the ordinary case. A
    /// character class narrow enough to describe Mastodon would index such an emoji and then
    /// never find it again, leaving the shortcode drawn as the letters somebody typed.
    ///
    /// So **the dictionary is the filter, not the character class**: the scan runs from one
    /// colon to the next and the lookup decides whether it was ever a shortcode. A colon
    /// standing on its own, a smiley typed by hand, and a `:name:` nobody sent a picture for
    /// are all left exactly as they were typed — a screen drawing a blank where a reader wrote
    /// a colon would be inventing something.
    ///
    /// The scan is bounded so that "to the next colon" cannot walk a whole post: a name stops
    /// at whitespace, at a newline, and at `maxShortcodeLength`. Without that bound a post with
    /// one stray colon near the top costs a re-scan of everything after it for every colon.
    ///
    /// Scanned by hand rather than by a regular expression, because a `Regex` cannot be a
    /// shared constant in a concurrent program and building one per post is a cost paid on
    /// every row of every page. A post with no pictures, or words with no colon in them, is one
    /// run and no scan at all — which is the common case.
    static func runs(in text: String, from emojis: [CustomEmoji]) -> [EmojiRun] {
        guard !emojis.isEmpty else { return plainRuns(text) }
        // Lazily, so the index is built straight from the list rather than from a throwaway
        // array of pairs. First spelling wins here too, for a list nobody folded.
        let byShortcode = Dictionary(emojis.lazy.map { ($0.shortcode, $0) }) { first, _ in first }
        return scan(text) { byShortcode[$0] }
    }

    /// A line with no picture in it: one run, or none at all where there are no words.
    internal static func plainRuns(_ text: String) -> [EmojiRun] {
        text.isEmpty ? [] : [.text(text)]
    }

    /// The scan itself, over whatever decides which names are shortcodes.
    ///
    /// Separated from the dictionary so that the post's own list and `EmojiAlphabet`'s order —
    /// the post first, the server's catalogue second — cut a line exactly the same way. The two
    /// differ in what they will answer to, never in what counts as a name.
    internal static func scan(_ text: String, lookup: (String) -> CustomEmoji?) -> [EmojiRun] {
        // Over the UTF-8 view: `:` is ASCII, so it cannot hide inside a multi-byte scalar, and
        // a byte scan neither allocates nor assembles the grapheme clusters a Character walk
        // would. That is what makes this fast path actually free.
        guard text.utf8.contains(UInt8(ascii: ":")) else { return plainRuns(text) }
        var runs: [EmojiRun] = []
        var plain = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == ":",
                  let closing = shortcodeEnd(in: text, openingAt: index),
                  let emoji = lookup(String(text[text.index(after: index)..<closing]))
            else {
                // Not a colon, not a shortcode, or not one of ours: this is a character of the
                // words. The scan carries on from the next one, which may open a real one.
                plain.append(text[index])
                index = text.index(after: index)
                continue
            }
            if !plain.isEmpty {
                runs.append(.text(plain))
                plain = ""
            }
            runs.append(.emoji(emoji))
            index = text.index(after: closing)
        }
        if !plain.isEmpty { runs.append(.text(plain)) }
        return runs
    }

    /// Far longer than any shortcode a server registers, and short enough that a stray colon
    /// costs a glance rather than a walk of everything after it.
    private static var maxShortcodeLength: Int { 64 }

    /// The closing colon of a `:name:` opening at `opening`, or nothing where what follows it
    /// is not a name closed by a colon.
    ///
    /// The name is at least one character, so `::` is two colons somebody typed rather than a
    /// picture with no name. It runs to the next colon and no further than a line, a space or
    /// `maxShortcodeLength` — what it may contain is the dictionary's business, not this
    /// function's.
    private static func shortcodeEnd(in text: String, openingAt opening: String.Index) -> String.Index? {
        let nameStart = text.index(after: opening)
        var cursor = nameStart
        var length = 0
        while cursor < text.endIndex, length <= maxShortcodeLength {
            let character = text[cursor]
            if character == ":" {
                return cursor > nameStart ? cursor : nil
            }
            // A name spans neither words nor lines — `isWhitespace` is true of a newline too. A
            // colon with a space after it is punctuation somebody wrote, and the next colon
            // further down the post is not its partner.
            guard !character.isWhitespace else { return nil }
            cursor = text.index(after: cursor)
            length += 1
        }
        return nil
    }
}
