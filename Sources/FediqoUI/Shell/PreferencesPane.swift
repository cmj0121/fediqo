import FediqoCore
import SwiftUI

/// Language, theme, type, and the latest date every timeline stops at (#22) — what a person
/// chooses. What this device holds is on `UsagePane` (#21).
///
/// **Four tabs, in Usage's shape** (#143, #164, #226): what a person chooses, which Fediqo this
/// is, what it is asking of the sources right now, and what it may reach beyond them. The same pills at the head of the same grouped
/// `Form`, and the same key — Tab and ⇧Tab rotate them (`ShellSession.rotatePreferencesTab`) — so
/// the page is reached and walked on a Mac and on a phone the way Usage already is. The second
/// tab is `BuildStampSection`, whole, the third `SourceWorkSection`, and the fourth
/// `AllowanceSection`.
struct PreferencesPane: View {
    @Environment(DummyPrefs.self) private var prefs
    @Environment(\.colorScheme) private var colorScheme

    /// Optional for the reason it is on `UsagePane`: a preview or a test can draw this pane with
    /// no shell around it, and then the page stays on what a person chooses.
    @Environment(ShellSession.self) private var session: ShellSession?

    /// What this build was stamped with. The app's own by default; a test or a preview hands in
    /// another.
    var stamp: BuildStamp = .main

    /// What this page is for, one tab each (#143).
    enum Purpose: String, CaseIterable, Identifiable {
        case choices
        case build
        case work
        case reach

        var id: Self { self }

        var titleKey: String {
            switch self {
            case .choices: "prefs.tab.choices"
            case .build: "prefs.tab.build"
            case .work: "prefs.tab.work"
            case .reach: "prefs.tab.reach"
            }
        }
    }

    private var purpose: Purpose { session?.preferencesPurpose ?? .choices }

    var body: some View {
        Form {
            Section { tabs }
            switch purpose {
            case .choices: choices
            case .build: BuildStampSection(stamp: stamp)
            case .work: SourceWorkSection(work: session?.work ?? .shared)
                if let session { ActivityEntry(session: session) }
            case .reach: AllowanceSection(book: .shared, sources: session?.sources.map(\.host) ?? [])
            }
        }
        .formStyle(.grouped)
        // **The pane the type size is chosen on has to move with it** (#96). A `Form`'s rows
        // take the platform's own font unless they are told otherwise, and on a Mac that font
        // does not follow the preference — so the one screen where a reader can see what they
        // just chose was the one screen that would not have shown it. Set on the `Form` rather
        // than on each row: a label, a picker's rows and a toggle all inherit it, and a control
        // added later inherits it too rather than being forgotten.
        .shellFont(.body)
        // The page's own colour, as on the timeline and Account, and no scroll bar.
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .clearsFloatingCorner()
        .padding(ShellSpace.snug)
    }

    /// What a person chooses: the page as it was before it had tabs.
    @ViewBuilder
    private var choices: some View {
        @Bindable var prefs = prefs
        Picker(L10n.t("prefs.language"), selection: $prefs.language) {
            ForEach(DummyLanguage.allCases) { language in
                Text(L10n.t("prefs.language.\(language.labelKey)")).tag(language)
            }
        }
        Picker(L10n.t("prefs.theme"), selection: $prefs.theme) {
            ForEach(DummyTheme.allCases) { theme in
                Text(L10n.t("prefs.theme.\(theme.rawValue)")).tag(theme)
            }
        }
        Picker(L10n.t("prefs.fontSize"), selection: $prefs.fontSize) {
            ForEach(DummyFontSize.allCases) { size in
                Text(L10n.t("prefs.fontSize.\(size.rawValue)")).tag(size)
            }
        }
        askAgain
        Section {
            Toggle(L10n.t("prefs.latest"), isOn: latestIsOn)
            if prefs.latestDate != nil {
                DatePicker(L10n.t("prefs.latest.date"), selection: latestDay, displayedComponents: .date)
            }
        } footer: {
            Text(L10n.t("prefs.latest.footer"))
                .shellFont(.meta)
        }
    }

    /// How long this device waits before asking the sources it holds again (#95).
    private var askAgain: some View {
        @Bindable var prefs = prefs
        return Section {
            Picker(L10n.t("prefs.askEvery"), selection: $prefs.askMinutes) {
                ForEach(DummyPrefs.waits, id: \.self) { minutes in
                    Text(Self.wait(minutes)).tag(minutes)
                }
            }
        } footer: {
            Text(L10n.t("prefs.askEvery.footer"))
                .shellFont(.meta)
        }
    }

    /// One wait as the picker names it.
    static func wait(_ minutes: Int) -> String {
        minutes == 1 ? L10n.t("prefs.askEvery.one") : String(format: L10n.t("prefs.askEvery.many"), minutes)
    }

    /// The same pills Usage and the timeline use: one selected, the rest a well. Tab rotates
    /// them; they sit in the Form so the grouped chrome is the page's own.
    ///
    /// Scrolled sideways where four do not fit — a phone at the largest type — rather than cut.
    private var tabs: some View {
        ScrollView(.horizontal) { tabRow }
            .scrollIndicators(.never)
    }

    private var tabRow: some View {
        HStack(spacing: ShellSpace.tight) {
            ForEach(Purpose.allCases) { tab in
                let selected = tab == purpose
                Button {
                    session?.preferencesPurpose = tab
                } label: {
                    Text(L10n.t(tab.titleKey))
                        .lineLimit(1)
                        .fixedSize()
                        .shellFont(.meta, weight: selected ? .semibold : .regular)
                        .foregroundStyle(
                            selected
                                ? ShellChrome.selectInk(colorScheme)
                                : ShellChrome.inkDim(colorScheme)
                        )
                        .padding(.horizontal, ShellSpace.snug)
                        .padding(.vertical, ShellSpace.tight)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    selected
                                        ? ShellChrome.selectFill(colorScheme)
                                        : ShellChrome.well(colorScheme)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    /// Off is no latest date. Turning it on starts at today, the date that hides nothing yet.
    private var latestIsOn: Binding<Bool> {
        Binding(
            get: { prefs.latestDate != nil },
            set: { on in prefs.latestDate = on ? LatestDate(Date()) : nil }
        )
    }

    /// The picker's date is the chosen day's start here; what it answers is read back as a day.
    private var latestDay: Binding<Date> {
        Binding(
            get: { prefs.latestDate?.start() ?? Date() },
            set: { prefs.latestDate = LatestDate($0) }
        )
    }
}
