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
        switch source.kind {
        case .microblog: source.isSignedIn ? "person.crop.circle" : "globe"
        case .forum: "text.bubble"
        case .board: "list.bullet"
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
