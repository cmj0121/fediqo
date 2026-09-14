import SwiftUI

/// The account icon for a timeline source. Unsigned: the host. Signed in: avatar and account meta.
struct SourceMark: View {
    let source: DummySource
    @Environment(\.colorScheme) private var colorScheme

    private let avatarSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(primary)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(secondary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
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
            .font(.body)
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
            HStack(spacing: 8) {
                ForEach(sources) { source in
                    SourceMark(source: source)
                }
            }
        }
        .accessibilityLabel(L10n.t("timeline.sources"))
    }
}
