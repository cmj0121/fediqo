import SwiftUI

/// The head of a timeline one of whose sources is not being read (#371): which, since when and
/// why, over the posts — and over the notice that there are none, which may be why.
struct UnreadSourcesHead: View {
    let timeline: TimelineQuery
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let line = ShellReload.unreadHead(session.reload.unreadLines(of: timeline, in: session)) {
            Label {
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ShellChrome.alarm(colorScheme))
                    .accessibilityHidden(true)
            }
            .shellFont(.meta)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(line))
        }
    }
}
