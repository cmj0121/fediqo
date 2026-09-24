import SwiftUI

/// Preferences' Allowed tab (#226, #233): what the app starts with letting through beyond a
/// source, as a list. Everything said is `Allowance`'s and everything changed is `AllowanceBook`'s,
/// which is where both are decided and tested; this lays them out.
///
/// **A row is the brief** — what it is, when it applies, and whether it is on. **Entering it opens
/// its detail**, in place of the list, where it is explained and switched: off, what it let
/// through is refused like anything else, at once. The hosts the person added are a tab of their
/// own (`OwnHostsSection`).
struct AllowanceSection: View {
    let book: AllowanceBook
    /// The detail open — Preferences' own, kept on the session so Escape closes it.
    @Binding var opened: PreferencesPane.Detail?
    /// The detail last closed, whose row the list lights again.
    let returning: PreferencesPane.Detail?

    @State private var lit: Allowance.ID?

    var body: some View {
        if case .entry(let id) = opened, let entry = Allowance.standing.first(where: { $0.id == id }) {
            AllowanceDetail(entry: entry, on: on(entry.id)) { opened = nil }
        } else {
            list
        }
    }

    private var list: some View {
        Section {
            ForEach(Allowance.standing) { entry in
                ShellListRow(
                    id: entry.id, title: entry.title(), brief: entry.whenText(),
                    figure: Self.figure(on: book.isOn(entry.id)),
                    selection: $lit, onOpen: { opened = .entry(entry.id) }, onStep: step
                ) {
                    Image(systemName: entry.symbol)
                }
            }
            .onAppear { if case .entry(let id) = returning { lit = id } }
        } header: {
            Text(L10n.t("allow.builtIn"))
        } footer: {
            Text(L10n.t("allow.builtIn.brief"))
                .shellFont(.meta)
                .shellHelp("allow.builtIn.footer", about: L10n.t("allow.builtIn"))
        }
    }

    /// What a row says of its switch.
    static func figure(on: Bool, language: DummyLanguage? = nil) -> String {
        L10n.t(on ? "allow.row.on" : "allow.row.off", language: language)
    }

    private func step(_ by: Int) {
        lit = ShellListStep.stepped(Allowance.ID.builtIn, from: lit, by: by)
    }

    private func on(_ id: Allowance.ID) -> Binding<Bool> {
        Binding(get: { book.isOn(id) }, set: { book.set(id, on: $0) })
    }
}

/// One of the app's own entries, opened: its switch, then what it lets through, when, why, and
/// the hosts. **The switch holds the keyboard as the detail opens, and Return flips it** — only
/// there, and once a press — so a detail opened from the keyboard is worked from it.
struct AllowanceDetail: View {
    let entry: Allowance
    @Binding var on: Bool
    let onBack: () -> Void

    var body: some View {
        Section {
            Toggle(L10n.t("allow.detail.on"), isOn: $on)
                .modifier(ReturnSwitches(on: $on))
                .accessibilityLabel(String(format: L10n.t("allow.detail.on.spoken"), entry.title()))
                .accessibilityHint(L10n.t("allow.detail.on.hint"))
            AllowanceFacts(entry: entry)
        } header: {
            ShellDetailHead(entry.title(), onBack: onBack) { Image(systemName: entry.symbol) }
        } footer: {
            Text(L10n.t("allow.builtIn.brief"))
                .shellFont(.meta)
                .shellHelp("allow.builtIn.footer", about: entry.title())
        }
    }
}

/// Return on the switch that holds the keyboard flips it. **Only the key going down**, so a
/// held Return is one flip and not a flicker; and only while this switch is focused, so a
/// Return anywhere else on the window is not heard here.
///
/// **Focus bound to the switch itself, never a focus stop wrapped round it.** A `.focusable()`
/// here made a second stop around the toggle, and Space, the switch's own key, went to the
/// wrapper and flipped nothing.
struct ReturnSwitches: ViewModifier {
    @Binding var on: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(.return, phases: .down) { _ in
                on.toggle()
                return .handled
            }
    }
}

/// What an entry says of itself, one fact a row: what it lets through, when, why, and the hosts.
struct AllowanceFacts: View {
    let entry: Allowance

    var body: some View {
        ShellDetailFact(label: L10n.t("allow.detail.what"), value: entry.what())
        ShellDetailFact(label: L10n.t("allow.detail.when"), value: entry.whenText())
        ShellDetailFact(label: L10n.t("allow.detail.why"), value: entry.why())
        ShellDetailFact(label: L10n.t("allow.detail.hosts"), value: entry.hostsText())
    }
}

extension Allowance {
    /// The glyph an entry leads its row with.
    var symbol: String {
        if source != nil { return "globe" }
        switch id {
        case .directory: return "list.bullet.rectangle"
        case .forumChallenge: return "shield.lefthalf.filled"
        case .personCheck: return "person.badge.shield.checkmark"
        case .signInPage: return "arrow.up.forward.square"
        default: return "checkmark.shield"
        }
    }
}
