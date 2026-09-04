import Foundation

/// A line of a post, cut into what is an address and what is not.
///
/// The cut is made here rather than on the screen for the reason the emoji's is: it is the part
/// worth testing, and it is testable without a screen. A run is what it says — the words, or
/// the words and where they point.
public enum TextRun: Sendable, Hashable {
    case text(String)
    case link(String, URL)
    /// A hashtag in the words: what the author typed, and the name the store keeps it under.
    ///
    /// Both, because they differ and both are needed: `#Swift` is what a reader must go on
    /// seeing, and `swift` is what a timeline of it is asked for. Keeping only the second would
    /// rewrite somebody's sentence to open it (#107).
    case tag(String, String)
}

/// One `NSDataDetector`, shared, and the claim that sharing it is safe.
///
/// The claim is Apple's: `NSRegularExpression` is documented as immutable and thread-safe, and
/// `NSDataDetector` is one. What is ours is where the claim is written down.
///
/// It was `nonisolated(unsafe)` on the property itself, which says the same thing in one word —
/// and this toolchain then warns that the word is unnecessary, because its SDK has since marked
/// `NSDataDetector` `Sendable`. The runner's SDK has not: **Xcode 16.4 there against 26.6 here**,
/// and taking the word out because this machine says it is redundant is how the last three
/// build failures happened. A wrapper of our own is the one spelling both toolchains read the
/// same way — no warning on the new one, no error on the old one — and it says out loud what
/// the annotation was asserting silently.
private struct SharedDetector: @unchecked Sendable {
    let detector: NSDataDetector?
}

public enum TextLinks {
    /// `NSDataDetector` and not a pattern of our own. What counts as the end of an address is
    /// a question with a great many wrong answers — a full stop that ends the sentence rather
    /// than the host, a bracket that closes what was opened before the link, a trailing comma —
    /// and the system's detector is the one thing here that has met all of them. It also knows
    /// that `example.org/x` is an address, which a reader who typed no scheme still meant.
    private static let shared = SharedDetector(
        detector: try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue))

    private static var detector: NSDataDetector? { shared.detector }

    /// Cuts `text` into runs, marking every address in it. A line with none is one run of text,
    /// which is the fast path and the common one.
    public static func runs(in text: String) -> [TextRun] {
        guard !text.isEmpty else { return [] }
        // The two ways there are no addresses: no detector to ask, and nothing for it to find.
        // Both still go through the hashtags — a line with a tag and no link is the ordinary
        // case, and returning early past them was the whole feature missing (#107).
        guard let detector else { return tagged(.text(text)) }
        let whole = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: whole)
        guard !matches.isEmpty else { return tagged(.text(text)) }

        var runs: [TextRun] = []
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), let url = match.url else { continue }
            if cursor < range.lowerBound { runs.append(.text(String(text[cursor..<range.lowerBound]))) }
            runs.append(.link(String(text[range]), url))
            cursor = range.upperBound
        }
        if cursor < text.endIndex { runs.append(.text(String(text[cursor...]))) }
        return runs.flatMap(tagged)
    }

    /// The hashtags inside a run of plain words, cut out of it (#107).
    ///
    /// **After the addresses and never inside one.** `example.org/page#section` ends in
    /// something shaped exactly like a hashtag, and it is part of the address — so this only
    /// ever sees what the detector left behind, which is text that is not an address.
    ///
    /// A hash is a hash whichever keyboard typed it: `＃` is U+FF03, and it is what a Japanese
    /// or Chinese keyboard produces without leaving the input mode the rest of the sentence is
    /// in. A tag has to be preceded by a break, or `C#` and `a#b` would be tags.
    static func tagged(_ run: TextRun) -> [TextRun] {
        guard case .text(let words) = run, words.contains(where: isHash) else { return [run] }
        var runs: [TextRun] = []
        var plain = ""
        var index = words.startIndex
        var afterABreak = true
        while index < words.endIndex {
            let character = words[index]
            if isHash(character), afterABreak,
               let end = words[words.index(after: index)...].firstIndex(where: { !isTagBody($0) })
                   ?? (words.index(after: index) < words.endIndex ? words.endIndex : nil) {
                let label = String(words[index..<end])
                // Normalised the one way the store normalises, so `#Swift` in the words and
                // `swift` in `post_tags` are the same press. A hash on its own is not a tag.
                if let name = Post.normalisedTags([label]).first {
                    if !plain.isEmpty { runs.append(.text(plain)); plain = "" }
                    runs.append(.tag(label, name))
                    index = end
                    afterABreak = false
                    continue
                }
            }
            plain.append(character)
            afterABreak = character.isWhitespace || character.isPunctuation || character.isNewline
            index = words.index(after: index)
        }
        if !plain.isEmpty { runs.append(.text(plain)) }
        return runs
    }

    private static func isHash(_ character: Character) -> Bool { character == "#" || character == "＃" }

    /// What may be in a tag after its hash. Letters, numbers and the underscore, which is what
    /// Mastodon allows — a full stop or a comma is the sentence resuming.
    private static func isTagBody(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
