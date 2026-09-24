import SwiftUI

/// Everything this run has asked of the sources (#218): newest first, each line the source it
/// was for, what for, and when it left — and narrowed to one source where one is chosen.
///
/// Everything drawn is `SourceWork.acts` read through `SourceAct`, which is where what a line may
/// say is decided and tested; this lays the lines out. **Looking sends nothing**: no request is
/// made, stopped or retried from here.
///
/// A sheet on both: on a Mac over the window it was asked from, on a phone a page of its own.
/// Opened from Preferences' in-flight tab.
struct ActivityPanel: View {
    let work: SourceWork
    let onClose: () -> Void

    /// The one source the list is narrowed to; nil for every source.
    @State private var chosen: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(ShellChrome.hairline(colorScheme)).frame(height: ShellSpace.hair)
                .accessibilityHidden(true)
            Form {
                Section { filter }
                lines
            }
            .formStyle(.grouped)
            .shellFont(.body)
            .scrollContentBackground(.hidden)
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 640, alignment: .topLeading)
        #else
        .presentationDetents([.large])
        #endif
        .background(ShellChrome.page(colorScheme))
    }

    private var header: some View {
        HStack(spacing: ShellSpace.step) {
            Text(L10n.t("activity.title"))
                .shellFont(.body, weight: .semibold)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(L10n.t("activity.close"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(ShellSpace.pad)
    }

    /// Every source the record holds a line for, and every source at once.
    private var filter: some View {
        Picker(L10n.t("activity.filter"), selection: $chosen) {
            Text(L10n.t("activity.filter.all")).tag(String?.none)
            ForEach(SourceAct.sources(in: work.acts), id: \.self) { source in
                Text(source).tag(Optional(source))
            }
        }
    }

    @ViewBuilder
    private var lines: some View {
        let listed = SourceAct.listed(work.acts, from: chosen)
        Section {
            if listed.isEmpty {
                Text(L10n.t("activity.none"))
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            } else {
                ForEach(listed) { act in
                    ActivityLine(act: act)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(L10n.t("activity.footer"))
                if work.dropped > 0 {
                    Text(L10n.count("activity.dropped", work.dropped))
                }
            }
            .shellFont(.meta)
        }
    }
}

/// One line of the record: the source, then what for and when under it — one element to
/// VoiceOver, read in that order.
struct ActivityLine: View {
    let act: SourceAct
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(act.source)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: ShellSpace.snug) {
                Text(act.purposeText())
                Spacer(minLength: 0)
                Text(act.time())
                    .monospacedDigit()
            }
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(act.spoken()))
    }
}

/// The way to the record from Preferences' in-flight tab, under what is running now.
struct ActivityEntry: View {
    let session: ShellSession

    var body: some View {
        Section {
            Button(L10n.t("activity.open")) { session.activityShown = true }
        } footer: {
            Text(L10n.t("activity.open.footer"))
                .shellFont(.meta)
        }
    }
}

/// The activity sheet, presented from the root by `ShellSession.activityShown` — a modifier of
/// its own so the root's chain gains one plain call and no closure presenter. See
/// `WithdrawQuestion` for why.
struct ActivitySheet: ViewModifier {
    let session: ShellSession

    func body(content: Content) -> some View {
        content.sheet(isPresented: shown) {
            ActivityPanel(work: session.work) { session.activityShown = false }
        }
    }

    private var shown: Binding<Bool> {
        Binding(
            get: { session.activityShown },
            set: { session.activityShown = $0 }
        )
    }
}
