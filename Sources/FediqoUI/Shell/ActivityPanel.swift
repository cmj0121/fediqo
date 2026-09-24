import SwiftUI

/// Everything this run has asked of the sources (#218, #236): newest first, a row each — the
/// source it was for, what for, and when it left — and narrowed to one source where one is
/// chosen. **Entering a row opens its detail** in place of the list: what it was for, when, where
/// it went if a source pointed elsewhere, and the entry that let it through, where one did.
///
/// Everything drawn is `SourceRecord` read through `SourceAct`, which is where what a line may
/// say is decided and tested; this lays the lines out. **Looking sends nothing**: no request is
/// made, stopped or retried from here.
///
/// **A `List`, so only the lines on screen are built**: the record holds up to ten thousand, and
/// what is listed is read off the record's own newest-first view and index, never recomputed from
/// the whole of it on a redraw.
///
/// A sheet on both: on a Mac over the window it was asked from, on a phone a page of its own.
/// Opened from Preferences' in-flight tab. Its close is an icon button, and Escape — the detail's
/// back while a detail is open, so Escape leaves one step at a time.
struct ActivityPanel: View {
    let log: SourceRecord
    let onClose: () -> Void

    /// The one source the list is narrowed to; nil for every source.
    @State private var chosen: String?
    @State private var lit: Int?
    @State private var opened: SourceAct?
    @Environment(\.colorScheme) private var colorScheme

    /// Narrowed to `source` from the start, where the record holds a line for it.
    init(log: SourceRecord, from source: String? = nil, onClose: @escaping () -> Void) {
        self.log = log
        self.onClose = onClose
        _chosen = State(initialValue: Self.stillChosen(source, among: log.sources))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ShellRule()
            page
                .shellFont(.body)
                .scrollContentBackground(.hidden)
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 640, alignment: .topLeading)
        #else
        .presentationDetents([.large])
        #endif
        .background(ShellChrome.page(colorScheme))
        // A source whose every line was let go is no longer offered, and is no longer chosen.
        .onChange(of: log.sources) { _, sources in
            chosen = Self.stillChosen(chosen, among: sources)
        }
    }

    /// The choice, where the record still holds a line for it; every source otherwise.
    static func stillChosen(_ chosen: String?, among sources: [String]) -> String? {
        chosen.flatMap { sources.contains($0) ? $0 : nil }
    }

    @ViewBuilder
    private var page: some View {
        if let opened {
            ActivityDetail(act: opened) { self.opened = nil }
        } else {
            lines
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            HStack(spacing: ShellSpace.step) {
                Text(L10n.t("activity.title"))
                    .shellFont(.body, weight: .semibold)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                ShellIconButton("xmark", name: "activity.close", action: onClose)
                    .keyboardShortcut(opened == nil ? .cancelAction : nil)
            }
            if opened == nil {
                filter
                    .shellFont(.body)
            }
        }
        .padding(ShellSpace.pad)
    }

    /// Every source the record holds a line for, and every source at once.
    private var filter: some View {
        Picker(L10n.t("activity.filter"), selection: $chosen) {
            Text(L10n.t("activity.filter.all")).tag(String?.none)
            ForEach(log.sources, id: \.self) { source in
                Text(source).tag(Optional(source))
            }
        }
    }

    private var lines: some View {
        let listed = log.listed(from: chosen)
        return List {
            Section {
                if listed.isEmpty {
                    Text(L10n.t("activity.none"))
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                } else {
                    ForEach(listed) { act in
                        SourceLineRow(
                            id: act.id, source: act.source, purpose: act.purpose, what: act.purposeText(),
                            when: act.time(), selection: $lit, onOpen: { opened = act },
                            onStep: { lit = ShellListStep.stepped(listed.map(\.id), from: lit, by: $0) }
                        )
                    }
                }
            } footer: {
                footer
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(L10n.t("activity.brief"))
                .shellHelp("activity.footer", about: L10n.t("activity.title"))
            if log.dropped > 0 {
                Text(L10n.count("activity.dropped", log.dropped))
            }
        }
        .shellFont(.meta)
    }
}

/// One line of the record, opened: its source at the head, then what it was for, when it left,
/// where it went where a source pointed elsewhere, and the entry that let it through, where one
/// did (#226).
struct ActivityDetail: View {
    let act: SourceAct
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShellSpace.step) {
                ShellDetailHead(act.source, onBack: onBack) { Image(systemName: act.purpose.symbol) }
                ForEach(Self.facts(act), id: \.label) { fact in
                    ShellDetailFact(label: fact.label, value: fact.value)
                }
            }
            .padding(ShellSpace.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the detail says, label and value, in order.
    static func facts(_ act: SourceAct, language: DummyLanguage? = nil) -> [(label: String, value: String)] {
        var facts = [
            (L10n.t("activity.detail.purpose", language: language), act.purposeText(language: language)),
            (L10n.t("activity.detail.time", language: language), act.time(language: language)),
        ]
        if act.reached != act.source {
            facts.append((L10n.t("activity.detail.reached", language: language), act.reached))
        }
        if let entry = act.allowedBy {
            facts.append((L10n.t("activity.detail.allowed", language: language), entry.name(language: language)))
        }
        return facts
    }
}

/// The way to the record from Preferences' in-flight tab, under what is running now: a row of
/// its own, entered as any row is.
struct ActivityEntry: View {
    let session: ShellSession

    @State private var lit: Bool?

    var body: some View {
        Section {
            ShellListRow(
                id: true, title: L10n.t("activity.title"), brief: L10n.t("activity.open.brief"),
                selection: $lit, onOpen: { Self.open(session) }
            ) {
                Image(systemName: "clock.arrow.circlepath")
            }
        }
    }

    /// The record, narrowed to `source` where one is given and the record holds a line for it.
    static func open(_ session: ShellSession, from source: String? = nil) {
        session.activityFrom = source
        session.activityShown = true
    }
}

/// The activity sheet, presented from the root by `ShellSession.activityShown` — a modifier of
/// its own so the root's chain gains one plain call and no closure presenter. See
/// `WithdrawQuestion` for why.
struct ActivitySheet: ViewModifier {
    let session: ShellSession

    func body(content: Content) -> some View {
        content.sheet(isPresented: shown) {
            ActivityPanel(log: session.work.log, from: session.activityFrom) { session.activityShown = false }
        }
    }

    private var shown: Binding<Bool> {
        Binding(
            get: { session.activityShown },
            set: { session.activityShown = $0 }
        )
    }
}
