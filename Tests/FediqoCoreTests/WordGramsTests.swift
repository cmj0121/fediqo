import Testing
@testable import FediqoCore

/// The words index's tokens (#360, K-1, K-2): whatever `Fold.contains` finds, the keyword's
/// tokens are all among the text's — over texts made to trip a fold.
@Suite("A post's word grams")
struct WordGramsTests {
    /// The same numbers every run, so a failure is one that can be had again.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Pieces that fold, compose, join or split in ways a byte search could trip on.
    static let pieces = [
        "Swift", "swift", "ＳＷＩＦＴ", "ｶﾀｶﾅ", "カタカナ", "台灣", "台", "灣", "日本語", "中文字",
        "café", "cafe\u{301}", "e\u{331}", "İSTANBUL", "istanbul", "I", "ı",
        "\u{00A0}", "\u{202F}", "\u{3000}", " ", "\n", "#tag", "@ada",
        "🇺🇸", "🇦🇺", "🇸🇪", "👍", "👍🏽", "👨‍👩‍👧", "a", "b", "の", "ß", "Ω", "😀",
    ]

    static func text(_ random: inout some RandomNumberGenerator, most: Int = 6) -> String {
        (0..<Int.random(in: 0...most, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined()
    }

    private static func tokens(_ doc: String) -> Set<String> {
        Set(doc.split(separator: " ").map(String.init))
    }

    private static func body(_ text: String) -> Set<String> {
        tokens(WordGrams.doc(body: text, handle: "", author: "", boosterHandle: nil, boostedBy: nil, host: "")).filter { $0.hasPrefix("b") }
    }

    @Test("every keyword Fold.contains finds in a text is asked only by tokens the text has")
    func superset() {
        var random = Seeded(state: 360)
        var found = 0
        for _ in 0..<1_500 {
            let text = Self.text(&random)
            let folded = Fold.key(text)
            let held = Self.body(text)
            // Keywords from the pieces, and every one- and two-character stretch of the text.
            var keywords = (0..<4).map { _ in Self.text(&random, most: 3) }
            let characters = Array(text)
            for start in characters.indices {
                keywords.append(String(characters[start]))
                if start + 1 < characters.count { keywords.append(String(characters[start...(start + 1)])) }
            }
            for keyword in keywords {
                let asked = Fold.key(keyword)
                guard Fold.contains(folded, asked) else { continue }
                found += 1
                guard let wanted = WordGrams.asked(asked) else { continue }
                #expect(Set(wanted).isSubset(of: held), "\(keyword.unicodeScalars.map(\.value)) in \(text.unicodeScalars.map(\.value))")
            }
        }
        #expect(found > 5_000)
    }

    @Test("a token is a field's letter and four base-36 characters a codepoint, runs of one to three")
    func shape() {
        let doc = WordGrams.doc(body: "台a", handle: "", author: "", boosterHandle: nil, boostedBy: nil, host: "")
        // 台 is U+53F0 = 21488 = "0gkw" in base 36; a is 97 = "002p".
        #expect(Self.tokens(doc).filter { $0.hasPrefix("b") } == Set(["b0gkw", "b002p", "b0gkw002p"]))
        #expect(WordGrams.asked("台") == ["b0gkw"])
        #expect(WordGrams.asked("台a") == ["b0gkw002p"])
        #expect(WordGrams.asked("") == nil)
        #expect(WordGrams.asked("abcd")?.count == 2)
        // Distinct runs only, and a spread of at most `mostAsked` from first to last.
        #expect(WordGrams.asked(String(repeating: "abcdefghij", count: 10))?.count == 10)
        let long = String(String.UnicodeScalarView((0..<100).compactMap { Unicode.Scalar(0x4E00 + $0) }))
        #expect(WordGrams.asked(long)?.count == WordGrams.mostAsked)
        #expect(WordGrams.asked(long)?.first == WordGrams.asked(String(long.prefix(3)))?.first)
        #expect(WordGrams.asked(long)?.last == WordGrams.asked(String(long.suffix(3)))?.first)
        #expect(WordGrams.match(["b1", "b2"]) == "b1 AND b2")
    }

    @Test("folded as the rules fold, and no run crosses from one field into the next")
    func fieldsApart() {
        let doc = Self.tokens(WordGrams.doc(
            body: "ＡＢ", handle: "@Cy@One.example", author: "Dee", boosterHandle: "e@two.example", boostedBy: "F", host: "h.example"
        ))
        #expect(Set(WordGrams.asked(Fold.key("ab"))!).isSubset(of: doc))
        #expect(Set(WordGrams.asked("@cy@one", in: .other)!).isSubset(of: doc))
        #expect(Set(WordGrams.asked("dee", in: .other)!).isSubset(of: doc))
        #expect(Set(WordGrams.asked("@e@two", in: .other)!).isSubset(of: doc))
        #expect(Set(WordGrams.asked("h.example", in: .other)!).isSubset(of: doc))
        // The handle's last letters and the author's first are no run; nor are the author and the host.
        #expect(!doc.contains(WordGrams.asked("led", in: .other)![0]))
        #expect(!doc.contains(WordGrams.asked("eeh", in: .other)![0]))
    }
}
