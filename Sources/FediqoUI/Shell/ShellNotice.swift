import SwiftUI

/// What a page says when it has nothing to show. Left aligned like every other page
/// here, and it names the next thing to do rather than describing the emptiness.
struct ShellNotice: View {
    let symbol: String
    let title: String
    let detail: String

    @Environment(\.colorScheme) private var colorScheme

    @ScaledMetric(relativeTo: .title3) private var glyph: CGFloat = 28

    private enum Metrics {
        /// An empty page is prose. It wraps where a sentence should.
        static let saying: CGFloat = 560
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .regular))
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .accessibilityHidden(true)
            Text(title)
                .font(ShellType.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            Text(detail)
                .font(ShellType.body)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: Metrics.saying, alignment: .leading)
        .padding(ShellSpace.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}
