import Foundation

/// One hashtag written in a post's words, and the letters it was written with.
///
/// **The letters and the tag are one string.** `text` is what the author typed, `#` and all, and
/// `name` is that same string with its `#` taken off. Nothing is read out of a `tags` array on a
/// stranger's status: a server's list says which tags it indexed the post under, which is not the
/// same question as which letters in these words are a tag, and drawing from the list would put a
/// pill round a word the author did not mark — or round nothing at all, where the list and the
/// words disagree. The reader is looking at what was typed.
///
/// **It is not an address and it is not a control.** A `PostLink` in hand is somewhere this device
/// will go; a `PostTag` in hand is a word the author marked, and there is nothing to open. That is
/// why this type carries no `URL` and offers no way to make one: the press is a later unit's, and
/// until it exists a type that could hand somebody a destination is a type that invites one.
///
/// **What counts as a tag is stated once, here.** `SearchIndex.Entry` reads the same rule through
/// `found(in:)`, so a post cannot be found by a tag its row would draw as ordinary words, nor its
/// row draw a pill round something no search would match.
public struct PostTag: Sendable, Hashable {
    /// Exactly what the author typed, drawn exactly as they typed it, `#` included.
    public let text: String

    /// The word without its `#` — what a reader is told the tag is, rather than the punctuation
    /// that marked it.
    public var name: String { String(text.dropFirst()) }

    /// A tag, or nothing where these letters are not one. The only initialiser, and it goes
    /// through the same rule the scanner does, for the reason `PostLink`'s own comment gives: a
    /// rule enforced at each consumer's door is a rule consumer N+1 misses.
    public init?(_ text: String) {
        guard text.first == "#" else { return nil }
        let name = text.dropFirst()
        guard !name.isEmpty, name.allSatisfy(Self.isTagCharacter) else { return nil }
        self.text = text
    }
}

public extension PostTag {
    /// The tags in a post's words, in the order they were written, and never more than `maxTags`
    /// of them.
    static func found(in text: String) -> [PostTag] {
        spans(in: text).map(\.tag)
    }

    /// How many tags one post's words may draw.
    ///
    /// **A bound on what a hostile instance can make a row do**, and the same bound for the same
    /// reason as `PostLink.maxLinks`: a post is five hundred characters of somebody else's
    /// choosing, and `#a #b #c …` repeated is two hundred and fifty attributed runs in a line that
    /// is re-laid-out on every pass of the row. Far more than any post a person writes, and small
    /// enough that the worst case is a shape rather than a stall. Past it the tags stay as the
    /// letters they were typed as, which is what a reader would have seen anyway.
    ///
    /// The two bounds are independent counts and not one shared budget, because they bound two
    /// independent scans; a post may reach both, which is sixty-four runs and still a shape.
    static var maxTags: Int { 32 }

    /// `#` then a run of letters, digits, marks or `_`, where the `#` does not follow one of those
    /// itself — so `a#b` is no tag, `#swift` in `(#swift)` is, and a bare `#` is not.
    ///
    /// **The word before is judged in the same alphabet the tag is, and that is the one decision
    /// here worth arguing with.** `PostLink.opensAWord` asks whether the character before is an
    /// *ASCII* alphanumeric, because an address is ASCII by construction and so `請看https://…`
    /// with no space has to link. A tag's own letters are not ASCII — `#台灣` is a tag — so the
    /// same narrowing here would make `看#台灣` a tag inside a word, which is neither what the
    /// author wrote nor what the servers this app reads index. `看 #台灣` is a tag; `看#台灣` is
    /// four characters of a sentence.
    ///
    /// Scanned by hand and over `Character`, not over UTF-8: what may be in a tag is a Unicode
    /// property rather than a byte, and `#` is the only ASCII in the rule.
    internal static func spans(in text: String) -> [(range: Range<String.Index>, tag: PostTag)] {
        // `#` is ASCII, so it cannot hide inside a multi-byte scalar, and a post with no `#` in it
        // is the common case and costs a byte scan rather than a walk of its graphemes.
        guard text.utf8.contains(UInt8(ascii: "#")) else { return [] }
        var found: [(range: Range<String.Index>, tag: PostTag)] = []
        var index = text.startIndex
        var previous: Character?
        while index < text.endIndex, found.count < maxTags {
            guard text[index] == "#", previous.map(isTagCharacter) != true else {
                previous = text[index]
                index = text.index(after: index)
                continue
            }
            var end = text.index(after: index)
            while end < text.endIndex, isTagCharacter(text[end]) {
                end = text.index(after: end)
            }
            if let tag = PostTag(String(text[index ..< end])) {
                found.append((index ..< end, tag))
            }
            // A `#` that opened nothing — `##y`, or one at the end of a line — leaves the cursor on
            // the character after it, so the second `#` of `##y` is still read as an opener.
            previous = text[text.index(before: end)]
            index = end
        }
        return found
    }

    /// What a tag may be spelled with: a letter or a digit in any script, a mark, or `_`.
    ///
    /// `Unicode.Scalar.Properties` rather than `Character.isLetter`, because the question is about
    /// the scalar a grapheme opens with — a letter carrying a combining mark is one character and
    /// is one the tag keeps.
    private static func isTagCharacter(_ character: Character) -> Bool {
        character == "_" || character.unicodeScalars.first.map {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        } == true
    }
}
