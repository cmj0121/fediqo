/// What the store's words index holds of a post, and what a keyword is asked of it by (#360,
/// K-1, K-2, C24, C28).
///
/// **Swift folds, SQLite only keeps tokens.** Each field is folded as everything that looks text
/// up folds it (`Fold.key`, `Fold.handle`), and its every run of one, two and three codepoints
/// becomes a token: the letter of its field, then each codepoint as four base-36 characters
/// (`0x10FFFF` is below `36^4`). So SQLite reads nothing but ASCII words, folds nothing, and never
/// has to agree with Foundation about a letter.
///
/// **A superset of `Fold.contains` by construction.** A folded keyword found in a folded text is
/// the same bytes, so the same codepoints in a row: every run of `min(3, n)` of its `n`
/// codepoints is one of the text's runs, and so one of its tokens. The index only narrows — a
/// candidate it gives is judged by the rules as every row is, and a hit is never certain
/// (`🇺🇸` is a run of `🇦🇺🇸🇪` and no character of it), so nothing is ever excluded by it.
///
/// **Fields never run into each other**: each is cut into runs on its own.
public enum WordGrams {
    /// Which side of a row a token was cut from: the body alone, which a keyword rule reads
    /// (Decision 13), or the names beside it, which search reads too (`SearchIndex.Entry`).
    public enum Field: UInt8, Sendable {
        case body = 0x62 // b
        case other = 0x6F // o
    }

    /// The longest run cut, in codepoints.
    public static let longest = 3

    /// The most tokens a keyword is asked by: any of its runs is a superset alone, so a long
    /// keyword asks a spread of them rather than every one.
    public static let mostAsked = 16

    /// A row's tokens, space-separated: its body as `b` runs, and its handle, author, booster's
    /// handle and name, and host as `o` runs — the fields `SearchIndex` reads besides the body,
    /// folded as it folds them.
    public static func doc(
        body: String, handle: String, author: String, boosterHandle: String?, boostedBy: String?, host: String
    ) -> String {
        var tokens = Tokens()
        tokens.cut(Fold.key(body), .body)
        tokens.cut("@" + Fold.handle(handle), .other)
        tokens.cut(Fold.key(author), .other)
        if let boosterHandle { tokens.cut("@" + Fold.handle(boosterHandle), .other) }
        if let boostedBy { tokens.cut(Fold.key(boostedBy), .other) }
        tokens.cut(host, .other)
        return tokens.text
    }

    /// The tokens a keyword, already folded (`Fold.key`), is asked by — each of its distinct runs
    /// of `min(3, n)` codepoints, at most `mostAsked` of them spread along it — or nothing for an
    /// empty keyword, which every row holds.
    public static func asked(_ folded: String, in field: Field = .body) -> [String]? {
        let scalars = Array(folded.unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        let length = min(longest, scalars.count)
        var seen = Set<[Unicode.Scalar]>()
        var runs: [[Unicode.Scalar]] = []
        for start in 0...(scalars.count - length) {
            let run = Array(scalars[start..<(start + length)])
            if seen.insert(run).inserted { runs.append(run) }
        }
        if runs.count > mostAsked {
            let step = Double(runs.count - 1) / Double(mostAsked - 1)
            runs = (0..<mostAsked).map { runs[Int((Double($0) * step).rounded())] }
        }
        return runs.map { run in
            var bytes: [UInt8] = [field.rawValue]
            for scalar in run { appendCode(scalar, to: &bytes) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// `tokens` as one FTS5 query that every token must answer.
    public static func match(_ tokens: [String]) -> String {
        tokens.joined(separator: " AND ")
    }

    private static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)

    fileprivate static func appendCode(_ scalar: Unicode.Scalar, to bytes: inout [UInt8]) {
        var value = Int(scalar.value)
        var four: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        four.3 = digits[value % 36]; value /= 36
        four.2 = digits[value % 36]; value /= 36
        four.1 = digits[value % 36]; value /= 36
        four.0 = digits[value % 36]
        bytes.append(four.0)
        bytes.append(four.1)
        bytes.append(four.2)
        bytes.append(four.3)
    }

    /// The distinct runs of a row's fields, written as they are first met.
    private struct Tokens {
        private var bytes: [UInt8] = []
        /// Runs already written, by field and length: up to three codepoints of 21 bits each.
        private var seen = Array(repeating: Set<UInt64>(), count: 6)

        mutating func cut(_ text: String, _ field: Field) {
            let scalars = Array(text.unicodeScalars)
            let side = field == .body ? 0 : 3
            for start in scalars.indices {
                var key: UInt64 = 0
                for length in 1...longest where start + length <= scalars.count {
                    key = key << 21 | UInt64(scalars[start + length - 1].value)
                    guard seen[side + length - 1].insert(key).inserted else { continue }
                    if !bytes.isEmpty { bytes.append(0x20) }
                    bytes.append(field.rawValue)
                    for scalar in scalars[start..<(start + length)] { WordGrams.appendCode(scalar, to: &bytes) }
                }
            }
        }

        var text: String { String(decoding: bytes, as: UTF8.self) }
    }
}
