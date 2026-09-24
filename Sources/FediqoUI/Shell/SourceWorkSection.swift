import SwiftUI

/// Preferences' third tab (#164, #233): what this device is asking of the sources right now, as a
/// list — a row each, the source, what for, and for how long. Everything drawn is
/// `SourceWork.rows`, which is where it is decided and tested; this lays the rows out.
///
/// **A row's detail is this run's record**, narrowed to the row's source (`onOpen`): what is
/// running is the newest of what was asked, and the record is the rest of it.
///
/// **Looking sends nothing.** This reads the registry and nothing else: no request is made, and
/// none is stopped, retried or reordered from here.
///
/// **The ticking stays in the row.** How long each piece has been running is redrawn once a
/// second by a `TimelineView` around that one row, so a clock ticking here redraws a row and not
/// the Form, and nothing ticks at all when nothing is running or the tab is closed.
struct SourceWorkSection: View {
    let work: SourceWork
    /// A row entered, with the source it is for.
    let onOpen: (String) -> Void

    @State private var lit: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Section {
            let rows = work.rows
            if rows.isEmpty {
                Text(L10n.t("work.none"))
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            } else {
                ForEach(rows) { row in
                    line(row, among: rows)
                }
            }
        } header: {
            Text(L10n.t("work.title"))
        } footer: {
            Text(L10n.t("work.brief"))
                .shellFont(.meta)
                .shellHelp("work.footer", about: L10n.t("work.title"))
        }
    }

    /// The source, then what for — and which board, where it reads one — and how long beside it.
    private func line(_ row: SourceWorkRow, among rows: [SourceWorkRow]) -> some View {
        TimelineView(.periodic(from: row.since, by: 1)) { context in
            SourceLineRow(
                id: row.id, source: row.host, purpose: row.purpose, what: row.purposeText(),
                when: SourceWorkRow.elapsed(since: row.since, now: context.date),
                selection: $lit, onOpen: { onOpen(row.host) },
                onStep: { lit = ShellListStep.stepped(rows.map(\.id), from: lit, by: $0) }
            )
        }
    }
}
