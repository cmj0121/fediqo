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

public enum TextLinks {
    /// `NSDataDetector` and not a pattern of our own. What counts as the end of an address is
    /// a question with a great many wrong answers — a full stop that ends the sentence rather
    /// than the host, a bracket that closes what was opened before the link, a trailing comma —
    /// and the system's detector is the one thing here that has met all of them. It also knows
    /// that `example.org/x` is an address, which a reader who typed no scheme still meant.
    private nonisolated(unsafe) static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

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
