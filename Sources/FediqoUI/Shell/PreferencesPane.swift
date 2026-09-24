import FediqoCore
import SwiftUI

/// Language, theme, type, and the latest date every timeline stops at (#22) — what a person
/// chooses. What this device holds is on `UsagePane` (#21).
///
/// **Five tabs, in Usage's shape** (#143, #164, #226, #233): what a person chooses, which Fediqo
/// this is, what it is asking of the sources right now, what the app starts with letting through
/// beyond them, and the hosts the person added. The same pills at the head of the same grouped
/// `Form`, and the same key — Tab and ⇧Tab rotate them (`ShellSession.rotatePreferencesTab`) — so
/// the page is reached and walked on a Mac and on a phone the way Usage already is. The second
/// tab is `BuildStampSection`, whole, the third `SourceWorkSection`, the fourth
/// `AllowanceSection` and the fifth `OwnHostsSection`: each one style, a list or a form, never
/// both (#231).
///
/// **Every setting says one short line**, and its long explanation is behind the (?) beside it.
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
    enum Purpose: String, CaseIterable, Identifiable, ShellTab {
        case choices
        case build
        case work
        case reach
        case hosts

        var id: Self { self }

        var titleKey: String {
            switch self {
            case .choices: "prefs.tab.choices"
            case .build: "prefs.tab.build"
            case .work: "prefs.tab.work"
            case .reach: "prefs.tab.reach"
            case .hosts: "prefs.tab.hosts"
            }
        }

        var symbol: String {
            switch self {
            case .choices: "slider.horizontal.3"
            case .build: "info.circle"
            case .work: "arrow.up.arrow.down"
            case .reach: "checkmark.shield"
            case .hosts: "globe"
            }
        }
    }

    /// A detail a tab shows in place of its list (#233): one of the allowed entries — the app's
    /// own on Allowed, the person's on Your hosts — or adding a host.
    enum Detail: Equatable {
        case entry(Allowance.ID)
        case adding

        /// Whether it is on screen with `purpose` the tab in front, and `own` the hosts the
        /// person added: a detail of another tab, or of a host since removed, is not.
        func shown(on purpose: Purpose, own: [Allowance.ID]) -> Bool {
            switch self {
            case .entry(let id) where Allowance.ID.builtIn.contains(id): purpose == .reach
            case .entry(let id): purpose == .hosts && own.contains(id)
            case .adding: purpose == .hosts
            }
        }
    }

    /// Where the detail is kept with no shell round the pane — a preview, a test.
    @State private var unhosted: Detail?

    private var purpose: Purpose { session?.preferencesPurpose ?? .choices }

    /// The detail open, on the session where there is one, so Escape reaches it.
    private var opened: Binding<Detail?> {
        Binding(
            get: { session?.preferencesOpened ?? unhosted },
            set: { detail in
                if let session { session.preferencesOpened = detail } else { unhosted = detail }
            }
        )
    }

    var body: some View {
        Form {
            Section { tabs }
            page
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

    /// The tab the page is on, whole.
    @ViewBuilder
    private var page: some View {
        switch purpose {
        case .choices: choices
        case .build: BuildStampSection(stamp: stamp)
        case .work: SourceWorkSection(work: session?.work ?? .shared, onOpen: openRecord)
            if let session { ActivityEntry(session: session) }
        case .reach: AllowanceSection(book: .shared, opened: opened, returning: session?.preferencesReturning)
        case .hosts: OwnHostsSection(
                book: .shared, sources: session?.sources.map(\.host) ?? [], opened: opened,
                returning: session?.preferencesReturning, onTyping: typing
            )
        }
    }

    /// A line of work in flight, entered: this run's record, narrowed to its source.
    private func openRecord(_ source: String) {
        if let session { ActivityEntry.open(session, from: source) }
    }

    /// The host field holds the keyboard, and the shell's single keys leave it alone.
    private func typing(_ now: Bool) {
        session?.searchFocused = now
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
            Text(L10n.t("prefs.latest.brief"))
                .shellFont(.meta)
                .shellHelp("prefs.latest.footer", about: L10n.t("prefs.latest"))
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
            Text(L10n.t("prefs.askEvery.brief"))
                .shellFont(.meta)
                .shellHelp("prefs.askEvery.footer", about: L10n.t("prefs.askEvery"))
        }
    }

    /// One wait as the picker names it.
    static func wait(_ minutes: Int) -> String {
        minutes == 1 ? L10n.t("prefs.askEvery.one") : String(format: L10n.t("prefs.askEvery.many"), minutes)
    }

    /// The page's tabs (`ShellTabs`), in the Form so the grouped chrome is the page's own. Tab
    /// rotates them (`ShellSession.rotatePreferencesTab`).
    private var tabs: some View {
        ShellTabs(Purpose.allCases, selected: purpose) { session?.preferencesPurpose = $0 }
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
