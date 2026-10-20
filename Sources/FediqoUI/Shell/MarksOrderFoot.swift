import SwiftUI

/// The foot of a timeline that reads the reader's marks (#317): that its rows stand by when each
/// was published, as every timeline's do, and not by when it was marked. Said where the list ends,
/// for as long as the timeline reads them, beside what Trends says there (`TrendsEndFoot`).
///
/// Drawn only where the timeline names a mark (`ShellSession.readsMarks`): its list asks that, once
/// for what it depends on, and this draws nothing but the line.
struct MarksOrderFoot: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(L10n.t("timeline.marks.order"))
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
    }
}
