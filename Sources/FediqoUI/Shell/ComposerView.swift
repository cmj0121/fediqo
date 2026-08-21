import SwiftUI

/// What the New Post button opens. It is deliberately not a screen: composing is something
/// you do from wherever you already are, so it arrives over the timeline and leaves the
/// moment you look at anything else.
///
/// The composer itself lands with #8. This is the room it will land in.
struct ComposerView: View {
    var body: some View {
        ScrollView {
            content
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .fediqoCard(radius: 12, shadow: true)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(Palette.accent)
                Text(t("compose.title")).fediqoFont(15, weight: .semibold)
                Spacer()
                Text(t("compose.wip")).fediqoFont(10, weight: .medium).fediqoPill()
            }

            Text(t("compose.placeholder"))
                .fediqoFont(12)
                .foregroundStyle(.tertiary)
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .fediqoCard(radius: 8, raised: false)

            Text(t("compose.soon"))
                .fediqoFont(11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: Self.size.width, alignment: .topLeading)
    }

    /// Fixed, and scrolled if the chosen text size overflows it, so the panel is the same
    /// shape at every text size and the shell can place it without asking how tall it is.
    static let size = CGSize(width: 320, height: 250)
}
