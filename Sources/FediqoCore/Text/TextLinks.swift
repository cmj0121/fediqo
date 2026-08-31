import Foundation

/// A line of a post, cut into what is an address and what is not.
///
/// The cut is made here rather than on the screen for the reason the emoji's is: it is the part
/// worth testing, and it is testable without a screen. A run is what it says — the words, or
/// the words and where they point.
public enum TextRun: Sendable, Hashable {
    case text(String)
    case link(String, URL)
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
        guard let detector, !text.isEmpty else { return text.isEmpty ? [] : [.text(text)] }
        let whole = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: whole)
        guard !matches.isEmpty else { return [.text(text)] }

        var runs: [TextRun] = []
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), let url = match.url else { continue }
            if cursor < range.lowerBound { runs.append(.text(String(text[cursor..<range.lowerBound]))) }
            runs.append(.link(String(text[range]), url))
            cursor = range.upperBound
        }
        if cursor < text.endIndex { runs.append(.text(String(text[cursor...]))) }
        return runs
    }
}
