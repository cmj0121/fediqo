import FediqoCore
import SwiftUI

/// The first merge with a paired device, before anything changes (D8): what would be added,
/// replaced and removed **on each side**, under one band per device, and a yes or a no. A no (or
/// no answer in two minutes) changes nothing and keeps the pair unmerged, asked again at the
/// next join.
///
/// Each change is its name on one line and what happens to it — "Source added" — on the next, so
/// a long host or timeline name wraps on its own line at any type size, and a listener hears the
/// row as one sentence.
struct SyncPreviewCard: View {
    let ask: SyncAsk
    let answer: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.pad) {
            Text(String(format: L10n.t("sync.ask.title"), ask.peer.name))
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.t("sync.ask.line"))
                .shellFont(.body)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .shellHelp("sync.ask.help", about: L10n.t("sync.title"))
            side(L10n.t("sync.ask.here"), ask.preview.here)
            side(String(format: L10n.t("sync.ask.there"), ask.peer.name), ask.preview.there)
            ShellReadingLine(L10n.t("sync.ask.note"))
                .fixedSize(horizontal: false, vertical: true)
            ShellPressRow {
                Button(L10n.t("sync.ask.no"), role: .cancel) { answer(false) }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("sync.ask.yes")) { answer(true) }
                    .keyboardShortcut(.defaultAction)
                    .tint(ShellChrome.selectInk(colorScheme))
            }
            .onePressLine()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    /// One device's band and its changes, or that nothing changes there.
    @ViewBuilder
    private func side(_ title: String, _ summary: SyncSummary) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ShellBandHead(title)
            let rows = Self.rows(summary)
            if rows.isEmpty {
                ShellReadingLine(L10n.t("sync.ask.nothing"))
                    .padding(.horizontal, ShellSpace.snug)
            }
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                    Image(systemName: row.change.symbol)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    VStack(alignment: .leading, spacing: ShellSpace.hair) {
                        Text(row.name)
                            .shellFont(.body)
                            .foregroundStyle(ShellChrome.ink(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(row.what)
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    }
                }
                .padding(.horizontal, ShellSpace.snug)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.spoken)
            }
        }
    }

    enum Change: Equatable {
        case added, replaced, removed

        var symbol: String {
            switch self {
            case .added: "plus.circle"
            case .replaced: "arrow.triangle.2.circlepath"
            case .removed: "minus.circle"
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let name: String
        let change: Change
        let timeline: Bool
        let what: String
        let spoken: String
        var id: String { "\(timeline)-\(change)-\(name)" }
    }

    /// Every change of one side: the sources, then the timelines, each added, replaced, removed.
    static func rows(_ summary: SyncSummary, language: DummyLanguage? = nil) -> [Row] {
        func rows(_ names: [String], _ change: Change, timeline: Bool) -> [Row] {
            let key = "sync.ask.\(timeline ? "timeline" : "source").\(change)"
            let what = L10n.t(key, language: language)
            let spoken = L10n.t("sync.ask.spoken", language: language)
            return names.map {
                Row(name: $0, change: change, timeline: timeline, what: what, spoken: String(format: spoken, what, $0))
            }
        }
        return rows(summary.addedSources, .added, timeline: false) + rows(summary.replacedSources, .replaced, timeline: false)
            + rows(summary.removedSources, .removed, timeline: false) + rows(summary.addedTimelines, .added, timeline: true)
            + rows(summary.replacedTimelines, .replaced, timeline: true) + rows(summary.removedTimelines, .removed, timeline: true)
    }
}

/// The first-merge question as its own sheet, on the window in front.
struct SyncAskSheet: View {
    let ask: SyncAsk
    let answer: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .body) private var measure: CGFloat = 420

    var body: some View {
        ScrollView {
            SyncPreviewCard(ask: ask, answer: answer)
                .padding(ShellSpace.room)
                .frame(maxWidth: measure, alignment: .leading)
        }
        .background(ShellChrome.page(colorScheme))
        .presentationSizing(.fitted)
        .presentationDetents([.medium, .large])
    }
}

/// The run's merging, on each window (D6): the window says when it comes to the front, goes to
/// the background and closes; hands the one `ShellSync` down to the panes; and, on the lead
/// window while the pairing sheet is not the one showing it, puts the first-merge question. **A modifier**,
/// so the root's chain grows by one line and no presenter is spelled in it.
struct SyncAcrossWindows: ViewModifier {
    let sync: ShellSync?
    let session: ShellSession

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .sheet(item: asking) { ask in
                SyncAskSheet(ask: ask) { yes in sync?.answer(yes) }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                Self.phase(phase, sync: sync, session: session)
            }
            .onDisappear { sync?.windowGone(session) }
            .environment(sync)
    }

    /// In front leads; the background lets go. A Mac window merely not key stays in front.
    static func phase(_ phase: ScenePhase, sync: ShellSync?, session: ShellSession) {
        switch phase {
        case .active: sync?.cameToFront(session)
        case .background: sync?.wentAway(session)
        case .inactive: break
        @unknown default: break
        }
    }

    /// The question, on the lead window, where the pairing sheet is not already showing it. Put
    /// away by any route but its presses is a no.
    private var asking: Binding<SyncAsk?> {
        Binding(
            get: { sync.flatMap { $0.leads(session) && !($0.pairingAsks && $0.showsPairing(on: session)) ? $0.asking : nil } },
            set: { if $0 == nil, sync?.asking != nil { sync?.answer(false) } }
        )
    }
}
