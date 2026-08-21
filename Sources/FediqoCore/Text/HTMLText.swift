import Foundation

/// Mastodon hands over post bodies as HTML. Rendering it is a later problem; reading it is
/// not, so this reduces the markup to the text a person wrote.
///
/// Hand-rolled on purpose: `NSAttributedString`'s HTML importer needs the main thread and a
/// web engine, which is a lot to drag in — and to test — for stripping tags.
public enum HTMLText {
    private static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&apos;": "'", "&#39;": "'", "&nbsp;": "\u{00a0}", "&hellip;": "…",
        "&mdash;": "—", "&ndash;": "–",
    ]

    public static func plain(_ html: String) -> String {
        var text = html

        // Block boundaries become line breaks before the tags go.
        for (pattern, replacement) in [("<br\\s*/?>", "\n"), ("</p>\\s*<p>", "\n\n"), ("</p>", "\n"), ("<p>", "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }

        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        text = decodeNumericEntities(text)

        // Collapse the runs of blank lines the tag removal leaves behind.
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericEntities(_ input: String) -> String {
        guard input.contains("&#") else { return input }
        var output = input
        let pattern = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        guard let pattern else { return output }
        let matches = pattern.matches(in: output, range: NSRange(output.startIndex..., in: output))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: output),
                  let flagRange = Range(match.range(at: 1), in: output),
                  let digitsRange = Range(match.range(at: 2), in: output) else { continue }
            let radix = output[flagRange].isEmpty ? 10 : 16
            guard let value = UInt32(output[digitsRange], radix: radix), let scalar = Unicode.Scalar(value) else { continue }
            output.replaceSubrange(full, with: String(Character(scalar)))
        }
        return output
    }
}
