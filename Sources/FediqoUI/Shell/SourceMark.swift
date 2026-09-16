import SwiftUI

/// The account icon for a timeline source. Unsigned: the host. Signed in: avatar and account meta.
struct SourceMark: View {
    let source: DummySource
    @Environment(\.colorScheme) private var colorScheme

    private let avatarSize: CGFloat = 28

    var body: some View {
        HStack(spacing: ShellSpace.snug) {
            avatar
            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                Text(primary)
                    .font(ShellType.meta.weight(.medium))
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .lineLimit(1)
                Text(secondary)
                    .font(ShellType.mark)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, ShellSpace.tight)
        .padding(.horizontal, ShellSpace.snug)
        .background(
            Capsule(style: .continuous)
                .fill(ShellChrome.well(colorScheme))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var avatar: some View {
        Image(systemName: markSymbol)
            .font(ShellType.body)
            .symbolVariant(source.isSignedIn ? .fill : .none)
            .symbolRenderingMode(.hierarchical)
            .frame(width: avatarSize, height: avatarSize)
    }

    private var markSymbol: String {
        // A signed-in microblog is drawn as a person rather than as a place, which is the one
        // thing a shape alone cannot say. Everything else is the shape's own glyph, and the table
        // is shared rather than restated so that the source page's rows and this mark cannot come
        // to disagree about what a forum looks like.
        if source.kind == .microblog, source.isSignedIn { return "person.crop.circle" }
        return Self.symbol(source.kind)
    }

    /// The glyph for a shape, with nobody signed in. **The one table**, read by this mark and by
    /// the source page's rows.
    ///
    /// **No `default:`**, the rule this branch states everywhere it switches over a closed set: a
    /// shape swept into somebody else's glyph is a film drawn with a globe over it, and nothing
    /// would break.
    static func symbol(_ kind: DummySourceKind) -> String {
        switch kind {
        case .microblog: "globe"
        case .forum: "text.bubble"
        case .board: "list.bullet"
        // Provisional: the nearest thing already in the set, chosen so the mark is not a globe
        // while nothing can produce a `.video` source anyway. M2's PeerTube unit picks the real
        // one alongside the row that draws a film.
        case .video: "film"
        }
    }

    private var primary: String {
        source.account?.displayName ?? source.host
    }

    private var secondary: String {
        if let account = source.account { account.handle }
        else { L10n.t("source.unsigned") }
    }

    private var label: String {
        if let account = source.account {
            "\(account.displayName), \(account.handle), \(source.host)"
        } else {
            "\(source.host), \(L10n.t("source.unsigned"))"
        }
    }
}

/// The sources this timeline reads, as a row of account icons.
struct SourceMarkRow: View {
    let sources: [DummySource]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ShellSpace.snug) {
                ForEach(sources) { source in
                    SourceMark(source: source)
                }
            }
        }
        .accessibilityLabel(L10n.t("timeline.sources"))
    }
}
