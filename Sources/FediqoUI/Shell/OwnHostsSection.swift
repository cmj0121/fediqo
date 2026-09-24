import SwiftUI

/// Preferences' tab of the hosts the person added (#226, #233), each for one of their sources.
/// Everything said is `Allowance`'s and everything changed is `AllowanceBook`'s; this lays it out.
///
/// **Three places, one at a time**: the list, a host's detail — what it lets through, and its
/// Remove — and adding one, which is a place of its own entered from the list's last row rather
/// than a form under the list.
struct OwnHostsSection: View {
    let book: AllowanceBook
    /// The sources the person has, as a host is added for one of them.
    let sources: [String]
    /// Told when the host field takes and lets go of the keyboard, so the shell's single keys
    /// leave what is typed there alone.
    /// The detail open — Preferences' own, kept on the session so Escape closes it.
    @Binding var opened: PreferencesPane.Detail?
    /// The detail last closed, whose row the list lights again.
    var returning: PreferencesPane.Detail?
    var onTyping: (Bool) -> Void = { _ in }

    /// The last row of the list, which is the way to adding one.
    static let addRow = Allowance.ID(rawValue: "add")

    @State private var lit: Allowance.ID?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch opened {
        case .entry(let id):
            if let entry = book.own.first(where: { $0.id == id }) {
                OwnHostDetail(entry: entry, gone: !served(entry), onRemove: { remove(id) }, onBack: back)
            } else {
                // Removed from under it — its source let go: the list, and the detail forgotten.
                list.onAppear { opened = nil }
            }
        case .adding:
            OwnHostAdding(book: book, sources: sources, onTyping: onTyping, onBack: back) { added in
                opened = nil
                lit = added
            }
        case nil: list
        }
    }

    private var list: some View {
        Section {
            if book.own.isEmpty {
                Text(L10n.t("allow.own.none"))
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            ForEach(book.own) { entry in
                row(entry)
            }
            ShellListRow(
                id: Self.addRow, title: L10n.t("allow.own.adding"), brief: L10n.t("allow.own.adding.brief"),
                selection: $lit, onOpen: { opened = .adding }, onStep: step
            ) {
                Image(systemName: "plus")
            }
            .onAppear(perform: relight)
        } header: {
            ShellSectionHead(title: "allow.own", line: "allow.own.brief", help: "allow.own.footer")
        }
    }

    private func row(_ entry: Allowance) -> some View {
        let gone = !served(entry)
        return ShellListRow(
            id: entry.id, title: entry.title(),
            brief: Self.brief(entry, gone: gone),
            selection: $lit, onOpen: { opened = .entry(entry.id) }, onStep: step
        ) {
            Image(systemName: gone ? "exclamationmark.triangle" : entry.symbol)
        }
    }

    /// What a host's row says under it: the source it serves, or that the source is gone.
    static func brief(_ entry: Allowance, gone: Bool, language: DummyLanguage? = nil) -> String {
        gone
            ? L10n.t("allow.own.gone.brief", language: language)
            : String(format: L10n.t("allow.own.for", language: language), entry.source ?? "")
    }

    private func step(_ by: Int) {
        lit = ShellListStep.stepped(book.own.map(\.id) + [Self.addRow], from: lit, by: by)
    }

    /// The row a closed detail was opened from, lit again.
    private func relight() {
        switch returning {
        case .entry(let id) where book.own.contains(where: { $0.id == id }): lit = id
        case .adding: lit = lit ?? Self.addRow
        default: break
        }
    }

    private func back() {
        opened = nil
    }

    private func remove(_ id: Allowance.ID) {
        book.remove(id)
        opened = nil
        lit = nil
    }

    /// Whether the source an entry serves is among the person's now.
    private func served(_ entry: Allowance) -> Bool {
        sources.contains { SourceWork.fold($0) == entry.source }
    }
}

/// A host the person added, opened: what it lets through, when, why, the host, whether its
/// source is gone — and Remove, which takes it off the list at once, as the list's own minus did.
struct OwnHostDetail: View {
    let entry: Allowance
    let gone: Bool
    let onRemove: () -> Void
    let onBack: () -> Void

    var body: some View {
        Section {
            if gone {
                ShellDetailFact(label: L10n.t("allow.detail.state"), value: L10n.t("allow.own.gone"), alarm: true)
            }
            AllowanceFacts(entry: entry)
            Button(role: .destructive, action: onRemove) {
                Label(L10n.t("allow.own.removeIt"), systemImage: "minus.circle")
            }
            .keyboardShortcut(.delete)
            .accessibilityLabel(String(format: L10n.t("allow.own.remove"), entry.title()))
        } header: {
            ShellDetailHead(entry.title(), onBack: onBack) { Image(systemName: entry.symbol) }
        }
    }
}

/// Adding a host: the source it is for, the host, and Add — or, with no source yet, why not.
/// A refusal says which rule the host broke, under the field. A host added goes back to the list
/// with its row lit.
struct OwnHostAdding: View {
    let book: AllowanceBook
    let sources: [String]
    let onTyping: (Bool) -> Void
    let onBack: () -> Void
    let onAdded: (Allowance.ID) -> Void

    @State private var typed = ""
    @State private var chosen = ""
    @State private var refusal: AllowanceBook.Refusal?
    @FocusState private var typing: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Section {
            if sources.isEmpty {
                Text(L10n.t("allow.own.noSource"))
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            } else {
                form
            }
        } header: {
            ShellDetailHead(L10n.t("allow.own.adding"), onBack: onBack) { Image(systemName: "plus") }
        }
    }

    @ViewBuilder
    private var form: some View {
        Picker(L10n.t("allow.own.source"), selection: source) {
            ForEach(sources, id: \.self) { Text($0).tag($0) }
        }
        HStack(spacing: ShellSpace.snug) {
            TextField(L10n.t("allow.own.host"), text: $typed)
                .textFieldStyle(.plain)
                .focused($typing)
                .onSubmit(add)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .accessibilityLabel(L10n.t("allow.own.host"))
            Button(L10n.t("allow.own.add"), action: add)
                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .modifier(TypingTold(typing: typing, onTyping: onTyping))
        if let refusal {
            Text(OwnHostAdding.sentence(refusal))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.alarm(colorScheme))
        }
    }

    /// The source a host is added for: the one chosen while it is still a source, the first
    /// otherwise.
    private var source: Binding<String> {
        Binding(
            get: { sources.contains(chosen) ? chosen : sources.first ?? "" },
            set: { chosen = $0 }
        )
    }

    private func add() {
        let source = source.wrappedValue
        refusal = book.add(typed, for: source)
        guard refusal == nil, case .success(let host) = AllowanceBook.host(typed) else { return }
        typed = ""
        onAdded(.own(host: host, source: SourceWork.fold(source)))
    }

    static func sentence(_ refusal: AllowanceBook.Refusal, language: DummyLanguage? = nil) -> String {
        switch refusal {
        case .notAHost: L10n.t("allow.own.refused.notAHost", language: language)
        case .itsOwnHost: L10n.t("allow.own.refused.itsOwnHost", language: language)
        case .alreadyThere: L10n.t("allow.own.refused.alreadyThere", language: language)
        case .wildcard: L10n.t("allow.own.refused.wildcard", language: language)
        case .address: L10n.t("allow.own.refused.address", language: language)
        case .port: L10n.t("allow.own.refused.port", language: language)
        case .path: L10n.t("allow.own.refused.path", language: language)
        }
    }
}

/// Whether the host field holds the keyboard, told as it changes and let go as the place goes. A
/// modifier rather than two closures spelled on the field, for the compiler reason
/// `FediqoRootView` gives.
private struct TypingTold: ViewModifier {
    let typing: Bool
    let onTyping: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: typing) { _, now in onTyping(now) }
            .onDisappear { onTyping(false) }
    }
}
