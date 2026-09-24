import Foundation

/// Mastodon hands over post bodies as HTML. This is the words, without the markup.
public enum HTMLText {
    private static let entities: [String: String] = [
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&quot;": "\"",
        "&#39;": "'",
        "&nbsp;": "\u{00A0}",
    ]

    public static func plain(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        text = decodeNumericEntities(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `html` without the `RE:` line a quoting server writes for readers that draw no quote
    /// (#214): Mastodon puts `<p class="quote-inline">RE: <a …>…</a></p>` ahead of a quoting
    /// post's words, and a reader that draws the quote itself would draw the quoted post twice —
    /// once as the quote, once as its address. Only ever asked of a post that carries a quote.
    public static func withoutQuoteLine(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"<p[^>]*\bclass="[^"]*\bquote-inline\b[^"]*"[^>]*>.*?</p>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func decodeNumericEntities(_ input: String) -> String {
        guard input.contains("&#") else { return input }
        guard let pattern = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else {
            return input
        }
        var output = input
        let matches = pattern.matches(in: output, range: NSRange(output.startIndex..., in: output))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: output),
                  let flagRange = Range(match.range(at: 1), in: output),
                  let digitsRange = Range(match.range(at: 2), in: output)
            else { continue }
            let radix: Int = output[flagRange].isEmpty ? 10 : 16
            guard let value = UInt32(output[digitsRange], radix: radix),
                  let scalar = Unicode.Scalar(value)
            else { continue }
            output.replaceSubrange(full, with: String(Character(scalar)))
        }
        return output
    }
}
