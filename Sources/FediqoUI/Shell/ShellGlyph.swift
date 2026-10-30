/// A glyph as it is drawn where it is chosen — the place on the rail the reader stands on, the
/// tab in front — and where it is not: **two glyphs, and the chosen one named outright.**
///
/// It was `.symbolVariant(.fill)`, which asks the system for a filled twin and, where there is
/// none, quietly draws the same glyph again: Trends, Usage and four of Preferences' tabs looked
/// the same chosen as not, and nothing said so. A name written here is a name a test can look
/// up (`ShellGlyphTests`), so a glyph without a twin stops the suite instead of the eye.
enum ShellGlyph {
    /// The twins that are not the glyph's own name and `.fill` after it.
    static let twins: [String: String] = [
        "point.3.connected.trianglepath.dotted": "point.3.filled.connected.trianglepath.dotted"
    ]

    /// The glyph drawn: its twin where it is chosen, itself where it is not. A glyph already
    /// filled, or none at all, is drawn as it is.
    static func drawn(_ symbol: String, chosen: Bool) -> String {
        guard chosen, !symbol.isEmpty, !symbol.split(separator: ".").contains("fill") else { return symbol }
        return twins[symbol] ?? "\(symbol).fill"
    }
}
