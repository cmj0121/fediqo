import SwiftUI

/// Preferences' third tab (#164): what this device is asking of the sources right now — the
/// source, what for, and for how long. Everything drawn is `SourceWork.rows`, which is where it
/// is decided and tested; this lays the lines out.
///
/// **Looking sends nothing.** This reads the registry and nothing else: no request is made, and
/// none is stopped, retried or reordered from here.
///
/// **The ticking stays in the line.** How long each piece has been running is redrawn once a
/// second by a `TimelineView` around that one line's time, so a clock ticking here redraws a
/// label and not the Form, and nothing ticks at all when nothing is running or the tab is closed.
struct SourceWorkSection: View {
    let work: SourceWork

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Section {
            let rows = work.rows
            if rows.isEmpty {
                Text(L10n.t("work.none"))
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            } else {
                ForEach(rows) { row in
                    line(row)
                }
            }
        } header: {
            Text(L10n.t("work.title"))
        } footer: {
            Text(L10n.t("work.footer"))
                .shellFont(.meta)
        }
    }

    /// The source, then what for and how long under it — one element to VoiceOver, read in that
    /// order.
    private func line(_ row: SourceWorkRow) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(row.host)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: ShellSpace.snug) {
                Text(row.purposeText())
                Spacer(minLength: 0)
                TimelineView(.periodic(from: row.since, by: 1)) { context in
                    Text(SourceWorkRow.elapsed(since: row.since, now: context.date))
                        .monospacedDigit()
                }
            }
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
        }
        .accessibilityElement(children: .combine)
    }
}
